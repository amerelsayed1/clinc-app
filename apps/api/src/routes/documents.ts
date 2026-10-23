import { randomUUID } from 'node:crypto';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { writeAudit } from '../audit.js';
import { authenticate, workspaceGuard } from '../auth.js';
import { config } from '../config.js';
import { tx } from '../db.js';
import { AppError, badRequest, conflict, forbidden, notFound } from '../errors.js';
import { decryptFile, encryptFile, sha256Hex, signLink, sniffMime, verifyLink, type ObjectStore, type Scanner } from '../storage.js';

const CLINIC_CATEGORIES = ['prescription', 'lab_result', 'imaging', 'report', 'administrative', 'other'] as const;
const PATIENT_CATEGORIES = ['prescription', 'lab_result', 'imaging', 'report', 'other'] as const;
const meta = {
  title: z.string().trim().max(120).default(''),
  notes: z.string().trim().max(1000).default(''),
  documentDate: z
    .string()
    .regex(/^\d{4}-\d{2}-\d{2}$/)
    .refine((d) => !Number.isNaN(Date.parse(d)) && d <= new Date().toISOString().slice(0, 10) && d >= '1900-01-01', 'Invalid date')
    .optional(),
};
const clinicFields = z.object({ category: z.enum(CLINIC_CATEGORIES), encounterId: z.string().uuid().optional(), ...meta });
const patientFields = z.object({ category: z.enum(PATIENT_CATEGORIES), ...meta });
const idParam = z.object({ id: z.string().uuid() });
const pageParam = z.object({ id: z.string().uuid(), page: z.coerce.number().int().min(1) });

interface PageRow {
  page: number;
  key: string;
  mime: string;
  size: number;
  sha: string;
  wrapped: string;
  name: string;
}
interface Prepared {
  name: string;
  mime: string;
  buf: Buffer;
}

async function readUpload(req: FastifyRequest) {
  const fields: Record<string, string> = {};
  const files: { name: string; buf: Buffer }[] = [];
  for await (const part of req.parts()) {
    if (part.type === 'file') {
      const buf = await part.toBuffer(); // throws 413 above the size limit
      if (buf.length) files.push({ name: part.filename.slice(0, 200), buf });
    } else {
      fields[part.fieldname] = String(part.value);
    }
  }
  return { fields, files };
}

/** F06-6: allow-list by content, size and page limits, malware scan. Nothing is stored before this passes. */
async function validateFiles(files: { name: string; buf: Buffer }[], scanner: Scanner): Promise<Prepared[]> {
  if (!files.length) throw badRequest('no_files', 'Attach at least one file');
  if (files.length > config.documents.maxPages) throw badRequest('too_many_pages', `At most ${config.documents.maxPages} pages per document`);
  const out: Prepared[] = [];
  for (const f of files) {
    const mime = sniffMime(f.buf);
    if (!mime) throw new AppError(415, 'unsupported_type', 'Only JPEG, PNG, WebP and PDF files are accepted');
    if (f.buf.length > config.documents.maxFileBytes) throw new AppError(413, 'file_too_large', 'File is too large');
    if ((await scanner.scan(f.buf)) !== 'clean') throw new AppError(422, 'malware_detected', 'The file failed the security scan and was rejected');
    out.push({ name: f.name, mime, buf: f.buf });
  }
  if (out.some((f) => f.mime === 'application/pdf') && out.length > 1) throw badRequest('invalid_pages', 'A PDF must be uploaded on its own');
  return out;
}

const DOC_SELECT = `
  select d.id, d.source, d.uploader_role, d.category, d.title, d.notes, to_char(d.document_date, 'YYYY-MM-DD') as document_date,
         d.encounter_id, d.total_bytes, d.published_at, d.created_at, d.workspace_id, d.patient_id, d.care_relationship_id,
         u.full_name as uploader_name,
         (select json_agg(json_build_object('page', p.page, 'mime', p.mime, 'sizeBytes', p.size_bytes) order by p.page) from document_pages p where p.document_id = d.id) as pages
    from documents d join users u on u.id = d.uploaded_by`;

const present = (r: Record<string, unknown>, extra: Record<string, unknown> = {}) => ({
  id: r.id,
  source: r.source,
  // Patient uploads stay distinguishable from clinician-authored records (RULE-009).
  provenance: r.source === 'patient' ? 'patient_submitted_unverified' : 'clinician_authored',
  uploaderName: r.uploader_name,
  uploaderRole: r.uploader_role,
  category: r.category,
  title: r.title,
  notes: r.notes,
  documentDate: r.document_date,
  encounterId: r.encounter_id,
  totalBytes: Number(r.total_bytes),
  published: !!r.published_at,
  createdAt: r.created_at,
  pages: r.pages ?? [],
  ...extra,
});

export function documentRoutes(app: FastifyInstance, pool: pg.Pool, store: ObjectStore, scanner: Scanner) {
  const ctxAudit = (req: FastifyRequest) => ({ workspaceId: req.workspace!.workspaceId, actorId: req.auth!.userId, actorRole: req.workspace!.role, ip: req.ip });

  /** Encrypts and stores every file, then inserts the rows. Stored objects are removed again if the transaction fails. */
  async function persist(
    files: Prepared[],
    scope: string,
    insert: (c: pg.PoolClient, pages: PageRow[], total: number) => Promise<string>,
  ): Promise<string> {
    const stored: string[] = [];
    try {
      const pages: PageRow[] = [];
      for (const [i, f] of files.entries()) {
        const { blob, wrappedKey } = encryptFile(f.buf);
        const key = `${scope}/${randomUUID()}`;
        await store.put(key, blob);
        stored.push(key);
        pages.push({ page: i + 1, key, mime: f.mime, size: f.buf.length, sha: sha256Hex(f.buf), wrapped: wrappedKey, name: f.name });
      }
      return await tx(pool, async (c) => {
        const id = await insert(c, pages, files.reduce((n, f) => n + f.buf.length, 0));
        for (const p of pages) {
          await c.query(`insert into document_pages (document_id, page, storage_key, mime, size_bytes, sha256, wrapped_key, original_name) values ($1,$2,$3,$4,$5,$6,$7,$8)`, [id, p.page, p.key, p.mime, p.size, p.sha, p.wrapped, p.name]);
        }
        return id;
      });
    } catch (e) {
      await Promise.all(stored.map((k) => store.delete(k).catch(() => undefined)));
      throw e;
    }
  }

  // Clinic readers with clinical.read see everything visible to the clinic. Front desk sees clinic-uploaded administrative files only.
  const clinicVisible = (permissions: string[]) =>
    permissions.includes('clinical.read') ? 'true' : `(d.category = 'administrative' and d.source <> 'patient')`;

  const visibleToClinic = `d.status = 'available' and (d.workspace_id = $2 or exists (
      select 1 from document_shares s join care_relationships r on r.id = s.care_relationship_id
       where s.document_id = d.id and s.revoked_at is null and r.workspace_id = $2 and r.status <> 'ended'))`;

  async function loadForClinic(id: string, workspaceId: string, permissions: string[]) {
    const r = (await pool.query(`${DOC_SELECT} where d.id = $1 and ${visibleToClinic} and ${clinicVisible(permissions)}`, [id, workspaceId])).rows[0];
    if (!r) throw notFound('Document not found');
    return r as Record<string, unknown>;
  }

  // ---------- clinic: upload ----------
  app.post('/patients/:id/documents', workspaceGuard(pool, 'documents.upload'), async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const ws = req.workspace!;
    const { fields, files } = await readUpload(req);
    const f = clinicFields.parse(fields);
    if (f.category !== 'administrative' && !ws.permissions.includes('documents.upload_clinical')) {
      throw forbidden('You can only upload administrative documents');
    }
    const rel = (await pool.query('select status, patient_id from care_relationships where id = $1 and workspace_id = $2', [id, ws.workspaceId])).rows[0];
    if (!rel) throw notFound('Patient not found');
    if (rel.status === 'ended') throw conflict('relationship_ended', 'This patient relationship has ended');
    if (f.encounterId) {
      const e = await pool.query(`select 1 from encounters where id = $1 and workspace_id = $2 and care_relationship_id = $3 and status <> 'discarded'`, [f.encounterId, ws.workspaceId, id]);
      if (!e.rowCount) throw notFound('Encounter not found for this patient');
    }
    const prepared = await validateFiles(files, scanner);
    const bytes = prepared.reduce((n, p) => n + p.buf.length, 0);
    const q = (await pool.query(`select w.storage_quota_bytes as quota, coalesce((select sum(total_bytes) from documents where workspace_id = w.id), 0) as used from workspaces w where w.id = $1`, [ws.workspaceId])).rows[0];
    if (Number(q.used) + bytes > Number(q.quota)) throw new AppError(413, 'quota_exceeded', 'Your clinic has reached its storage limit');

    const docId = await persist(prepared, ws.workspaceId, async (c, _pages, total) => {
      const d = (
        await c.query(
          `insert into documents (patient_id, workspace_id, care_relationship_id, encounter_id, source, uploaded_by, uploader_role, category, title, notes, document_date, total_bytes)
           values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) returning id`,
          [rel.patient_id, ws.workspaceId, id, f.encounterId ?? null, ws.role === 'doctor' ? 'clinician' : 'staff', req.auth!.userId, ws.role, f.category, f.title, f.notes, f.documentDate ?? null, total],
        )
      ).rows[0];
      await writeAudit(c, { ...ctxAudit(req), action: 'document.uploaded', targetType: 'document', targetId: d.id, metadata: { patientId: id, category: f.category, pages: prepared.length } });
      return d.id;
    });
    reply.code(201);
    return present((await pool.query(`${DOC_SELECT} where d.id = $1`, [docId])).rows[0]);
  });

  // ---------- clinic: read ----------
  app.get('/patients/:id/documents', workspaceGuard(pool, 'patients.read'), async (req) => {
    const { id } = idParam.parse(req.params);
    const { encounterId } = z.object({ encounterId: z.string().uuid().optional() }).parse(req.query);
    const ws = req.workspace!;
    const rows = (
      await pool.query(
        `${DOC_SELECT}
          where d.status = 'available' and ${clinicVisible(ws.permissions)}
            and ($3::uuid is null or d.encounter_id = $3)
            and (d.care_relationship_id = $1 or exists (
                  select 1 from document_shares s join care_relationships r on r.id = s.care_relationship_id
                   where s.document_id = d.id and s.care_relationship_id = $1 and s.revoked_at is null and r.workspace_id = $2 and r.status <> 'ended'))
            and exists (select 1 from care_relationships where id = $1 and workspace_id = $2)
          order by coalesce(d.document_date::timestamptz, d.created_at) desc, d.created_at desc limit 200`,
        [id, ws.workspaceId, encounterId ?? null],
      )
    ).rows;
    const reviewed = new Set((await pool.query('select document_id from document_reviews where workspace_id = $1', [ws.workspaceId])).rows.map((r) => r.document_id));
    return rows.map((r) => present(r, { reviewed: reviewed.has(r.id) }));
  });

  app.get('/documents/:id', workspaceGuard(pool, 'patients.read'), async (req) => {
    const { id } = idParam.parse(req.params);
    const ws = req.workspace!;
    const r = await loadForClinic(id, ws.workspaceId, ws.permissions);
    const rev = (await pool.query('select reviewed_by, note, created_at from document_reviews where document_id = $1 and workspace_id = $2', [id, ws.workspaceId])).rows[0];
    return present(r, { reviewed: !!rev, review: rev ? { note: rev.note, at: rev.created_at } : null });
  });

  // F06-5: authorization happens here; the returned link is short-lived and carries no standing access.
  app.get('/documents/:id/pages/:page/link', workspaceGuard(pool, 'patients.read'), async (req) => {
    const { id, page } = pageParam.parse(req.params);
    const ws = req.workspace!;
    await loadForClinic(id, ws.workspaceId, ws.permissions);
    const p = await pool.query('select 1 from document_pages where document_id = $1 and page = $2', [id, page]);
    if (!p.rowCount) throw notFound('Page not found');
    const { token, expiresAt } = signLink({ d: id, p: page, u: req.auth!.userId, w: ws.workspaceId });
    return { path: `/files/${token}`, expiresAt };
  });

  // F06-4
  app.post('/documents/:id/review', workspaceGuard(pool, 'clinical.write'), async (req) => {
    const { id } = idParam.parse(req.params);
    const { note } = z.object({ note: z.string().trim().max(500).default('') }).parse(req.body ?? {});
    const ws = req.workspace!;
    const d = await loadForClinic(id, ws.workspaceId, ws.permissions);
    if (d.source !== 'patient') throw conflict('invalid_state', 'Only patient-submitted documents are reviewed');
    await tx(pool, async (c) => {
      const r = await c.query(`insert into document_reviews (document_id, workspace_id, reviewed_by, note) values ($1,$2,$3,$4) on conflict do nothing`, [id, ws.workspaceId, req.auth!.userId, note]);
      if (!r.rowCount) throw conflict('already_reviewed', 'Already reviewed');
      await writeAudit(c, { ...ctxAudit(req), action: 'document.reviewed', targetType: 'document', targetId: id });
    });
    return { ok: true };
  });

  // Clinic documents become visible to the patient only when the doctor publishes them.
  for (const publish of [true, false]) {
    app.post(`/documents/:id/${publish ? 'publish' : 'unpublish'}`, workspaceGuard(pool, 'clinical.write'), async (req) => {
      const { id } = idParam.parse(req.params);
      const ws = req.workspace!;
      await tx(pool, async (c) => {
        const d = (await c.query(`select source, category from documents where id = $1 and workspace_id = $2 and status = 'available' for update`, [id, ws.workspaceId])).rows[0];
        if (!d) throw notFound('Document not found');
        if (d.category === 'administrative') throw conflict('invalid_state', 'Administrative documents are not published to patients');
        if (publish) await c.query('update documents set published_at = now(), published_by = $2 where id = $1', [id, req.auth!.userId]);
        else await c.query('update documents set published_at = null, published_by = null where id = $1', [id]);
        await writeAudit(c, { ...ctxAudit(req), action: publish ? 'document.published' : 'document.unpublished', targetType: 'document', targetId: id });
      });
      return { ok: true };
    });
  }

  // F06-8: clinic documents are tombstoned, never erased: the bytes stay for retention but nothing serves them.
  app.delete('/documents/:id', workspaceGuard(pool, 'documents.upload'), async (req) => {
    const { id } = idParam.parse(req.params);
    const { reason } = z.object({ reason: z.string().trim().min(3).max(300) }).parse(req.body);
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      const d = (await c.query(`select uploaded_by from documents where id = $1 and workspace_id = $2 and status = 'available' for update`, [id, ws.workspaceId])).rows[0];
      if (!d) throw notFound('Document not found');
      if (d.uploaded_by !== req.auth!.userId && ws.role !== 'doctor') throw forbidden('Only the uploader or the doctor can delete this document');
      await c.query(`update documents set status = 'deleted', deleted_at = now(), deleted_by = $2, delete_reason = $3, published_at = null where id = $1`, [id, req.auth!.userId, reason]);
      await writeAudit(c, { ...ctxAudit(req), action: 'document.deleted', targetType: 'document', targetId: id });
    });
    return { ok: true };
  });

  app.get('/workspace/storage', workspaceGuard(pool, 'documents.upload'), async (req) => {
    const q = (await pool.query(`select w.storage_quota_bytes as quota, coalesce((select sum(total_bytes) from documents where workspace_id = w.id), 0) as used from workspaces w where w.id = $1`, [req.workspace!.workspaceId])).rows[0];
    return { usedBytes: Number(q.used), quotaBytes: Number(q.quota) };
  });

  // ---------- patient side ----------
  const authed = { preHandler: authenticate(pool) };
  const myPatient = async (userId: string): Promise<string> => {
    const p = (await pool.query('select id from patients where user_id = $1', [userId])).rows[0];
    if (!p) throw forbidden('Claim your patient profile first');
    return p.id;
  };
  const loadMine = async (id: string, patientId: string) => {
    // Own uploads, or clinic documents the doctor published to this patient.
    const r = (await pool.query(`${DOC_SELECT} where d.id = $1 and d.patient_id = $2 and d.status = 'available' and (d.source = 'patient' or d.published_at is not null)`, [id, patientId])).rows[0];
    if (!r) throw notFound('Document not found');
    return r as Record<string, unknown>;
  };

  app.post('/patient/documents', authed, async (req, reply) => {
    const patientId = await myPatient(req.auth!.userId);
    const { fields, files } = await readUpload(req);
    const f = patientFields.parse(fields);
    const prepared = await validateFiles(files, scanner);
    const bytes = prepared.reduce((n, p) => n + p.buf.length, 0);
    const used = Number((await pool.query(`select coalesce(sum(total_bytes), 0) as n from documents where patient_id = $1 and source = 'patient' and status = 'available'`, [patientId])).rows[0].n);
    if (used + bytes > config.documents.patientQuotaBytes) throw new AppError(413, 'quota_exceeded', 'You have reached your storage limit');
    const docId = await persist(prepared, `patient/${patientId}`, async (c, _p, total) => {
      const d = (
        await c.query(
          `insert into documents (patient_id, source, uploaded_by, uploader_role, category, title, notes, document_date, total_bytes) values ($1,'patient',$2,'patient',$3,$4,$5,$6,$7) returning id`,
          [patientId, req.auth!.userId, f.category, f.title, f.notes, f.documentDate ?? null, total],
        )
      ).rows[0];
      await writeAudit(c, { actorId: req.auth!.userId, actorRole: 'patient', action: 'document.patient_uploaded', targetType: 'document', targetId: d.id, metadata: { category: f.category, pages: prepared.length }, ip: req.ip });
      return d.id;
    });
    reply.code(201);
    return present((await pool.query(`${DOC_SELECT} where d.id = $1`, [docId])).rows[0], { sharedWith: [] });
  });

  app.get('/patient/documents', authed, async (req) => {
    const patientId = await myPatient(req.auth!.userId);
    const rows = (
      await pool.query(`${DOC_SELECT} where d.patient_id = $1 and d.status = 'available' and (d.source = 'patient' or d.published_at is not null) order by d.created_at desc limit 200`, [patientId])
    ).rows;
    const shares = (
      await pool.query(
        `select s.document_id, s.care_relationship_id, s.revoked_at, w.name as clinic_name, u.full_name as doctor_name
           from document_shares s join care_relationships r on r.id = s.care_relationship_id
           join workspaces w on w.id = r.workspace_id join users u on u.id = w.owner_id
          where s.document_id = any($1)`,
        [rows.map((r) => r.id)],
      )
    ).rows;
    return rows.map((r) =>
      present(r, {
        sharedWith: shares.filter((s) => s.document_id === r.id && !s.revoked_at).map((s) => ({ relationshipId: s.care_relationship_id, clinicName: s.clinic_name, doctorName: s.doctor_name })),
      }),
    );
  });

  app.get('/patient/documents/:id/pages/:page/link', authed, async (req) => {
    const { id, page } = pageParam.parse(req.params);
    const patientId = await myPatient(req.auth!.userId);
    await loadMine(id, patientId);
    const p = await pool.query('select 1 from document_pages where document_id = $1 and page = $2', [id, page]);
    if (!p.rowCount) throw notFound('Page not found');
    const { token, expiresAt } = signLink({ d: id, p: page, u: req.auth!.userId, w: null });
    return { path: `/files/${token}`, expiresAt };
  });

  app.post('/patient/documents/:id/send', authed, async (req) => {
    const { id } = idParam.parse(req.params);
    const { relationshipId } = z.object({ relationshipId: z.string().uuid() }).parse(req.body);
    const patientId = await myPatient(req.auth!.userId);
    await tx(pool, async (c) => {
      const d = (await c.query(`select 1 from documents where id = $1 and patient_id = $2 and source = 'patient' and status = 'available'`, [id, patientId])).rows[0];
      if (!d) throw notFound('Document not found');
      const r = (await c.query(`select workspace_id, status from care_relationships where id = $1 and patient_id = $2`, [relationshipId, patientId])).rows[0];
      if (!r) throw notFound('Relationship not found');
      if (r.status !== 'active') throw conflict('invalid_state', 'You can only send documents to clinics you are connected to');
      await c.query(
        `insert into document_shares (document_id, care_relationship_id, shared_by) values ($1,$2,$3)
         on conflict (document_id, care_relationship_id) do update set revoked_at = null, shared_by = excluded.shared_by`,
        [id, relationshipId, req.auth!.userId],
      );
      await writeAudit(c, { workspaceId: r.workspace_id, actorId: req.auth!.userId, actorRole: 'patient', action: 'document.shared_with_clinic', targetType: 'document', targetId: id, ip: req.ip });
    });
    return { ok: true };
  });

  app.delete('/patient/documents/:id/send/:relationshipId', authed, async (req) => {
    const { id, relationshipId } = z.object({ id: z.string().uuid(), relationshipId: z.string().uuid() }).parse(req.params);
    const patientId = await myPatient(req.auth!.userId);
    await tx(pool, async (c) => {
      const r = await c.query(
        `update document_shares s set revoked_at = now() from documents d, care_relationships r
          where s.document_id = $1 and s.care_relationship_id = $2 and s.revoked_at is null and d.id = s.document_id and d.patient_id = $3 and r.id = s.care_relationship_id
          returning r.workspace_id`,
        [id, relationshipId, patientId],
      );
      if (!r.rowCount) throw notFound('Share not found');
      await writeAudit(c, { workspaceId: r.rows[0].workspace_id, actorId: req.auth!.userId, actorRole: 'patient', action: 'document.share_revoked', targetType: 'document', targetId: id, ip: req.ip });
    });
    return { ok: true };
  });

  // A patient can erase their own upload unless a clinic has been given it: then the clinic may hold a lawful copy (F06-8).
  app.delete('/patient/documents/:id', authed, async (req) => {
    const { id } = idParam.parse(req.params);
    const patientId = await myPatient(req.auth!.userId);
    const keys: string[] = [];
    await tx(pool, async (c) => {
      const d = (await c.query(`select 1 from documents where id = $1 and patient_id = $2 and source = 'patient' and status = 'available' for update`, [id, patientId])).rows[0];
      if (!d) throw notFound('Document not found');
      const shared = await c.query('select 1 from document_shares where document_id = $1', [id]);
      if (shared.rowCount) throw conflict('already_shared', 'This document was sent to a clinic. Revoke access instead; the clinic may keep its copy.');
      keys.push(...(await c.query('delete from document_pages where document_id = $1 returning storage_key', [id])).rows.map((r) => r.storage_key));
      await c.query(`update documents set status = 'deleted', deleted_at = now(), deleted_by = $2, delete_reason = 'Deleted by patient' where id = $1`, [id, req.auth!.userId]);
      await writeAudit(c, { actorId: req.auth!.userId, actorRole: 'patient', action: 'document.patient_deleted', targetType: 'document', targetId: id, ip: req.ip });
    });
    await Promise.all(keys.map((k) => store.delete(k)));
    return { ok: true };
  });

  // ---------- serving: signed link only, access re-checked at the moment of use ----------
  app.get('/files/:token', async (req, reply) => {
    const { token } = z.object({ token: z.string().max(600) }).parse(req.params);
    const claims = verifyLink(token);
    if (!claims) throw new AppError(403, 'invalid_link', 'This link is invalid or has expired');
    const row = (
      await pool.query(
        `select p.storage_key, p.mime, p.wrapped_key, d.patient_id, d.source, d.published_at, d.workspace_id, d.category
           from document_pages p join documents d on d.id = p.document_id
          where p.document_id = $1 and p.page = $2 and d.status = 'available'`,
        [claims.d, claims.p],
      )
    ).rows[0];
    if (!row) throw notFound('File not found');

    let allowed = false;
    if (claims.w) {
      // Acting for a clinic: its own upload, or a patient document currently sent to it; membership must still be active.
      const m = (await pool.query(`select 1 from memberships where user_id = $1 and workspace_id = $2 and status = 'active'`, [claims.u, claims.w])).rows[0];
      const visible =
        row.workspace_id === claims.w ||
        (await pool.query(
          `select 1 from document_shares s join care_relationships r on r.id = s.care_relationship_id
            where s.document_id = $1 and s.revoked_at is null and r.workspace_id = $2 and r.status <> 'ended'`,
          [claims.d, claims.w],
        )).rowCount! > 0;
      allowed = !!m && visible;
    } else {
      const p = (await pool.query('select 1 from patients where id = $1 and user_id = $2', [row.patient_id, claims.u])).rows[0];
      allowed = !!p && (row.source === 'patient' || row.published_at !== null);
    }
    if (!allowed) throw new AppError(403, 'invalid_link', 'This link is invalid or has expired');

    const data = decryptFile(await store.get(row.storage_key), row.wrapped_key);
    await tx(pool, async (c) => {
      await c.query('insert into document_access (document_id, accessor_user_id, workspace_id, page) values ($1,$2,$3,$4)', [claims.d, claims.u, claims.w, claims.p]);
      if (claims.w) await writeAudit(c, { workspaceId: claims.w, actorId: claims.u, action: 'document.viewed', targetType: 'document', targetId: claims.d, metadata: { page: claims.p }, ip: req.ip });
    });
    reply
      .header('content-type', row.mime)
      .header('content-disposition', 'inline')
      .header('cache-control', 'private, no-store')
      .header('x-content-type-options', 'nosniff')
      .header('content-security-policy', "default-src 'none'; sandbox");
    return reply.send(data);
  });
}
