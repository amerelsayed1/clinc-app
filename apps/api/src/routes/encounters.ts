import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { VITAL_KEYS, VITAL_KINDS } from '@clinic/shared';
import { writeAudit } from '../audit.js';
import { authenticate, workspaceGuard } from '../auth.js';
import { tx } from '../db.js';
import { createDraftEncounter } from '../encounter-store.js';
import { AppError, badRequest, conflict, forbidden, notFound } from '../errors.js';

const text = z.string().max(10_000);
const rxItem = z.object({
  medication: z.string().trim().min(1).max(200),
  dose: z.string().trim().max(100).default(''),
  frequency: z.string().trim().max(100).default(''),
  duration: z.string().trim().max(100).default(''),
  notes: z.string().trim().max(300).default(''),
});
const content = {
  chiefComplaint: text.optional(),
  history: text.optional(),
  diagnosis: text.optional(),
  plan: text.optional(),
  privateNotes: text.optional(),
  prescriptions: z.array(rxItem).max(30).optional(),
};
type ContentKey = keyof typeof content;
const CONTENT_KEYS = Object.keys(content) as ContentKey[];
const COLUMN: Record<ContentKey, string> = {
  chiefComplaint: 'chief_complaint',
  history: 'history',
  diagnosis: 'diagnosis',
  plan: 'plan',
  privateNotes: 'private_notes',
  prescriptions: 'prescriptions',
};

const idParam = z.object({ id: z.string().uuid() });

interface Loaded {
  id: string;
  workspace_id: string;
  care_relationship_id: string;
  appointment_id: string | null;
  author_id: string;
  encounter_date: Date;
  status: 'draft' | 'signed' | 'discarded';
  revision: number;
  current_version: number;
  signed_at: Date | null;
  published_version: number | null;
  published_at: Date | null;
}

async function load(db: Pick<pg.Pool, 'query'>, id: string, workspaceId: string, lock = false): Promise<Loaded> {
  const e = (await db.query(`select * from encounters where id = $1 and workspace_id = $2 and status <> 'discarded' ${lock ? 'for update' : ''}`, [id, workspaceId])).rows[0];
  if (!e) throw notFound('Encounter not found');
  return e;
}

const versionContent = (v: Record<string, unknown>, role: string) => ({
  chiefComplaint: v.chief_complaint,
  history: v.history,
  diagnosis: v.diagnosis,
  plan: v.plan,
  // Private notes never leave the doctor's own view (F05-2, spec 02).
  ...(role === 'doctor' && { privateNotes: v.private_notes }),
  prescriptions: v.prescriptions,
});

const versionMeta = (v: Record<string, unknown>) => ({
  version: v.version,
  authorId: v.author_id,
  authorName: v.author_name,
  createdAt: v.created_at,
  amendmentReason: v.amendment_reason,
  changedFields: v.changed_fields,
});

const presentObs = (o: Record<string, unknown>) => ({
  id: o.id,
  kind: o.kind,
  value: Number(o.value),
  unit: VITAL_KINDS[o.kind as keyof typeof VITAL_KINDS]?.unit,
  measuredAt: o.measured_at,
  recordedBy: o.recorded_by,
  recordedByName: o.recorded_by_name,
  recordedRole: o.recorded_role,
  voided: !!o.voided_at,
  voidReason: o.void_reason,
});

async function observationsOf(db: Pick<pg.Pool, 'query'>, encounterId: string, includeVoided = true) {
  const rows = (
    await db.query(
      `select o.*, u.full_name as recorded_by_name from observations o join users u on u.id = o.recorded_by
        where o.encounter_id = $1 ${includeVoided ? '' : 'and o.voided_at is null'} order by o.created_at`,
      [encounterId],
    )
  ).rows;
  return rows.map(presentObs);
}

async function detail(db: Pick<pg.Pool, 'query'>, e: Loaded, role: string) {
  const v = (
    await db.query(
      `select v.*, u.full_name as author_name from encounter_versions v join users u on u.id = v.author_id where v.encounter_id = $1 and v.version = $2`,
      [e.id, e.current_version],
    )
  ).rows[0];
  const p = (await db.query('select full_name, patient_number from care_relationships where id = $1', [e.care_relationship_id])).rows[0];
  const a = (await db.query('select full_name from users where id = $1', [e.author_id])).rows[0];
  return {
    id: e.id,
    patient: { id: e.care_relationship_id, fullName: p.full_name, patientNumber: p.patient_number },
    appointmentId: e.appointment_id,
    author: { id: e.author_id, fullName: a.full_name },
    encounterDate: e.encounter_date,
    status: e.status,
    revision: e.revision,
    currentVersion: e.current_version,
    signedAt: e.signed_at,
    publishedVersion: e.published_version,
    publishedAt: e.published_at,
    content: versionContent(v, role),
    version: versionMeta(v),
    observations: await observationsOf(db, e.id),
  };
}

const diffKeys = (before: Record<string, unknown>, after: Record<string, unknown>): ContentKey[] =>
  CONTENT_KEYS.filter((k) => JSON.stringify(before[COLUMN[k]]) !== JSON.stringify(after[COLUMN[k]]));

export function encounterRoutes(app: FastifyInstance, pool: pg.Pool) {
  const read = workspaceGuard(pool, 'clinical.read');
  const write = workspaceGuard(pool, 'clinical.write');
  const vitals = workspaceGuard(pool, 'vitals.write');

  const ctxAudit = (req: { auth?: { userId: string }; workspace?: { workspaceId: string; role: string }; ip: string }) => ({
    workspaceId: req.workspace!.workspaceId,
    actorId: req.auth!.userId,
    actorRole: req.workspace!.role,
    ip: req.ip,
  });

  const requireAuthor = (e: Loaded, userId: string) => {
    if (e.author_id !== userId) throw forbidden('Only the author can change this encounter');
  };

  // ---------- list / create ----------
  app.get('/patients/:id/encounters', read, async (req) => {
    const { id } = idParam.parse(req.params);
    const rows = (
      await pool.query(
        `select e.id, e.encounter_date, e.status, e.current_version, e.published_version, e.appointment_id, u.full_name as author_name,
                left(v.chief_complaint, 140) as chief_complaint, left(v.diagnosis, 140) as diagnosis
           from encounters e
           join encounter_versions v on v.encounter_id = e.id and v.version = e.current_version
           join users u on u.id = e.author_id
          where e.care_relationship_id = $1 and e.workspace_id = $2 and e.status <> 'discarded'
          order by e.encounter_date desc limit 100`,
        [id, req.workspace!.workspaceId],
      )
    ).rows;
    return rows.map((r) => ({
      id: r.id,
      encounterDate: r.encounter_date,
      status: r.status,
      currentVersion: r.current_version,
      published: r.published_version !== null,
      appointmentId: r.appointment_id,
      authorName: r.author_name,
      chiefComplaint: r.chief_complaint,
      diagnosis: r.diagnosis,
    }));
  });

  app.post('/patients/:id/encounters', write, async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const { appointmentId } = z.object({ appointmentId: z.string().uuid().optional() }).parse(req.body ?? {});
    const ws = req.workspace!;
    const encounterId = await tx(pool, async (c) => {
      const rel = (await c.query('select status from care_relationships where id = $1 and workspace_id = $2', [id, ws.workspaceId])).rows[0];
      if (!rel) throw notFound('Patient not found');
      if (rel.status === 'ended') throw conflict('relationship_ended', 'This patient relationship has ended');
      if (appointmentId) {
        const a = (await c.query('select status, care_relationship_id from appointments where id = $1 and workspace_id = $2', [appointmentId, ws.workspaceId])).rows[0];
        if (!a || a.care_relationship_id !== id) throw notFound('Appointment not found for this patient');
        if (a.status !== 'in_consultation') throw conflict('invalid_state', 'The appointment must be in consultation');
        const dup = await c.query(`select 1 from encounters where appointment_id = $1 and status <> 'discarded'`, [appointmentId]);
        if (dup.rowCount) throw conflict('encounter_exists', 'This appointment already has an encounter');
      }
      const eid = await createDraftEncounter(c, { workspaceId: ws.workspaceId, relationshipId: id, appointmentId, authorId: req.auth!.userId });
      await writeAudit(c, { ...ctxAudit(req), action: 'encounter.created', targetType: 'encounter', targetId: eid, metadata: { patientId: id, appointmentId: appointmentId ?? null } });
      return eid;
    });
    reply.code(201);
    return detail(pool, await load(pool, encounterId, ws.workspaceId), ws.role);
  });

  // ---------- read ----------
  app.get('/encounters/:id', read, async (req) => {
    const { id } = idParam.parse(req.params);
    const ws = req.workspace!;
    const e = await load(pool, id, ws.workspaceId);
    await tx(pool, (c) => writeAudit(c, { ...ctxAudit(req), action: 'encounter.viewed', targetType: 'encounter', targetId: id }));
    return detail(pool, e, ws.role);
  });

  app.get('/encounters/:id/versions', read, async (req) => {
    const { id } = idParam.parse(req.params);
    const ws = req.workspace!;
    await load(pool, id, ws.workspaceId);
    const rows = (
      await pool.query(`select v.*, u.full_name as author_name from encounter_versions v join users u on u.id = v.author_id where v.encounter_id = $1 order by v.version`, [id])
    ).rows;
    await tx(pool, (c) => writeAudit(c, { ...ctxAudit(req), action: 'encounter.history_viewed', targetType: 'encounter', targetId: id }));
    return rows.map((v) => ({ ...versionMeta(v), content: versionContent(v, ws.role) }));
  });

  // ---------- draft editing with optimistic concurrency (F05-9) ----------
  app.patch('/encounters/:id', write, async (req) => {
    const { id } = idParam.parse(req.params);
    const body = z.object({ revision: z.number().int().min(1), ...content }).parse(req.body);
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      const e = await load(c, id, ws.workspaceId, true);
      requireAuthor(e, req.auth!.userId);
      if (e.status !== 'draft') throw conflict('encounter_signed', 'Signed encounters can only be changed by amendment');
      if (e.revision !== body.revision) {
        const cur = (await c.query('select * from encounter_versions where encounter_id = $1 and version = 1', [id])).rows[0];
        throw new AppError(409, 'revision_conflict', 'This draft was changed elsewhere. Reload before saving.', { revision: e.revision, content: versionContent(cur, ws.role) });
      }
      const sets: string[] = [];
      const params: unknown[] = [id];
      for (const k of CONTENT_KEYS) {
        if (body[k] === undefined) continue;
        params.push(k === 'prescriptions' ? JSON.stringify(body[k]) : body[k]);
        sets.push(`${COLUMN[k]} = $${params.length}`);
      }
      if (sets.length) await c.query(`update encounter_versions set ${sets.join(', ')} where encounter_id = $1 and version = 1`, params);
      await c.query('update encounters set revision = revision + 1, updated_at = now() where id = $1', [id]);
    });
    return detail(pool, await load(pool, id, ws.workspaceId), ws.role);
  });

  // Drafts have never been part of the record, so discarding keeps the row but hides it. Autosaves are not audited.
  app.delete('/encounters/:id', write, async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      const e = await load(c, id, ws.workspaceId, true);
      requireAuthor(e, req.auth!.userId);
      if (e.status !== 'draft') throw conflict('encounter_signed', 'Signed encounters cannot be discarded');
      await c.query(`update encounters set status = 'discarded', updated_at = now() where id = $1`, [id]);
      await writeAudit(c, { ...ctxAudit(req), action: 'encounter.discarded', targetType: 'encounter', targetId: id });
    });
    reply.code(204);
  });

  app.post('/encounters/:id/sign', write, async (req) => {
    const { id } = idParam.parse(req.params);
    const { revision } = z.object({ revision: z.number().int().min(1) }).parse(req.body);
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      const e = await load(c, id, ws.workspaceId, true);
      requireAuthor(e, req.auth!.userId);
      if (e.status !== 'draft') throw conflict('encounter_signed', 'Already signed');
      if (e.revision !== revision) throw new AppError(409, 'revision_conflict', 'The draft changed since you last saw it', { revision: e.revision });
      const v = (await c.query('select chief_complaint from encounter_versions where encounter_id = $1 and version = 1', [id])).rows[0];
      if (!v.chief_complaint.trim()) throw badRequest('incomplete', 'Add a chief complaint before signing');
      await c.query(`update encounters set status = 'signed', signed_at = now(), updated_at = now() where id = $1`, [id]);
      await writeAudit(c, { ...ctxAudit(req), action: 'encounter.signed', targetType: 'encounter', targetId: id });
    });
    return detail(pool, await load(pool, id, ws.workspaceId), ws.role);
  });

  // ---------- amendments (F05-5) ----------
  app.post('/encounters/:id/amend', write, async (req) => {
    const { id } = idParam.parse(req.params);
    const body = z.object({ baseVersion: z.number().int().min(1), reason: z.string().trim().min(3).max(500), changes: z.object(content).strict() }).parse(req.body);
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      const e = await load(c, id, ws.workspaceId, true);
      requireAuthor(e, req.auth!.userId);
      if (e.status !== 'signed') throw conflict('invalid_state', 'Only signed encounters are amended; edit drafts directly');
      if (e.current_version !== body.baseVersion) throw new AppError(409, 'version_conflict', 'A newer version exists. Reload before amending.', { currentVersion: e.current_version });
      const cur = (await c.query('select * from encounter_versions where encounter_id = $1 and version = $2', [id, e.current_version])).rows[0];
      const next: Record<string, unknown> = { ...cur };
      for (const k of CONTENT_KEYS) if (body.changes[k] !== undefined) next[COLUMN[k]] = body.changes[k];
      const changed = diffKeys(cur, next);
      if (!changed.length) throw badRequest('no_changes', 'Nothing was changed');
      if (!String(next.chief_complaint).trim()) throw badRequest('incomplete', 'Chief complaint cannot be empty');
      const version = e.current_version + 1;
      await c.query(
        `insert into encounter_versions (encounter_id, version, chief_complaint, history, diagnosis, plan, private_notes, prescriptions, author_id, amendment_reason, changed_fields)
         values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
        [id, version, next.chief_complaint, next.history, next.diagnosis, next.plan, next.private_notes, JSON.stringify(next.prescriptions), req.auth!.userId, body.reason, changed],
      );
      await c.query('update encounters set current_version = $2, updated_at = now() where id = $1', [id, version]);
      // Field names and version only: the audit log must not become a second copy of clinical text.
      await writeAudit(c, { ...ctxAudit(req), action: 'encounter.amended', targetType: 'encounter', targetId: id, metadata: { version, changedFields: changed } });
    });
    return detail(pool, await load(pool, id, ws.workspaceId), ws.role);
  });

  // ---------- vitals / observations (F05-3) ----------
  app.post('/encounters/:id/observations', vitals, async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = z.object({ kind: z.enum(VITAL_KEYS), value: z.number().finite() }).parse(req.body);
    const spec = VITAL_KINDS[body.kind];
    if (body.value < spec.min || body.value > spec.max) throw badRequest('out_of_range', `${spec.label} must be between ${spec.min} and ${spec.max} ${spec.unit}`);
    const ws = req.workspace!;
    const oid = await tx(pool, async (c) => {
      const e = await load(c, id, ws.workspaceId, true);
      if (e.status !== 'draft') throw conflict('encounter_signed', 'Vitals can only be added while the encounter is a draft');
      const o = (
        await c.query(
          `insert into observations (workspace_id, care_relationship_id, encounter_id, kind, value, recorded_by, recorded_role) values ($1,$2,$3,$4,$5,$6,$7) returning id`,
          [ws.workspaceId, e.care_relationship_id, id, body.kind, body.value, req.auth!.userId, ws.role],
        )
      ).rows[0];
      await writeAudit(c, { ...ctxAudit(req), action: 'observation.recorded', targetType: 'encounter', targetId: id, metadata: { kind: body.kind } });
      return o.id as string;
    });
    reply.code(201);
    return (await observationsOf(pool, id)).find((o) => o.id === oid);
  });

  app.post('/encounters/:id/observations/:oid/void', vitals, async (req) => {
    const { id, oid } = z.object({ id: z.string().uuid(), oid: z.string().uuid() }).parse(req.params);
    const { reason } = z.object({ reason: z.string().trim().min(3).max(300) }).parse(req.body);
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      const e = await load(c, id, ws.workspaceId, true);
      if (e.status !== 'draft') throw conflict('encounter_signed', 'Vitals can only be voided while the encounter is a draft');
      const o = (await c.query('select recorded_by, voided_at from observations where id = $1 and encounter_id = $2 for update', [oid, id])).rows[0];
      if (!o) throw notFound('Observation not found');
      if (o.voided_at) throw conflict('already_voided', 'Already voided');
      if (o.recorded_by !== req.auth!.userId && ws.role !== 'doctor') throw forbidden('You can only void your own entries');
      await c.query('update observations set voided_at = now(), voided_by = $2, void_reason = $3 where id = $1', [oid, req.auth!.userId, reason]);
      await writeAudit(c, { ...ctxAudit(req), action: 'observation.voided', targetType: 'encounter', targetId: id });
    });
    return { ok: true };
  });

  // F05-8: one measurement across all of this clinic's encounters for the patient.
  app.get('/patients/:id/observations', read, async (req) => {
    const { id } = idParam.parse(req.params);
    const { kind } = z.object({ kind: z.enum(VITAL_KEYS) }).parse(req.query);
    const ws = req.workspace!;
    const rows = (
      await pool.query(
        `select o.id, o.value, o.measured_at, o.encounter_id, o.recorded_role
           from observations o join encounters e on e.id = o.encounter_id
          where o.care_relationship_id = $1 and o.workspace_id = $2 and o.kind = $3 and o.voided_at is null and e.status <> 'discarded'
          order by o.measured_at`,
        [id, ws.workspaceId, kind],
      )
    ).rows;
    return { kind, unit: VITAL_KINDS[kind].unit, points: rows.map((r) => ({ id: r.id, value: Number(r.value), measuredAt: r.measured_at, encounterId: r.encounter_id, recordedRole: r.recorded_role })) };
  });

  // ---------- publishing to the patient (F05-10) ----------
  app.post('/encounters/:id/publish', write, async (req) => {
    const { id } = idParam.parse(req.params);
    const { version } = z.object({ version: z.number().int().min(1).optional() }).parse(req.body ?? {});
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      const e = await load(c, id, ws.workspaceId, true);
      if (e.status !== 'signed') throw conflict('invalid_state', 'Only signed encounters can be published');
      const v = version ?? e.current_version;
      if (v > e.current_version) throw badRequest('invalid_version', 'Unknown version');
      await c.query('update encounters set published_version = $2, published_at = now(), published_by = $3 where id = $1', [id, v, req.auth!.userId]);
      await writeAudit(c, { ...ctxAudit(req), action: 'encounter.published', targetType: 'encounter', targetId: id, metadata: { version: v } });
    });
    return detail(pool, await load(pool, id, ws.workspaceId), ws.role);
  });

  app.post('/encounters/:id/unpublish', write, async (req) => {
    const { id } = idParam.parse(req.params);
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      const e = await load(c, id, ws.workspaceId, true);
      if (e.published_version === null) throw conflict('invalid_state', 'Not published');
      await c.query('update encounters set published_version = null, published_at = null where id = $1', [id]);
      await writeAudit(c, { ...ctxAudit(req), action: 'encounter.unpublished', targetType: 'encounter', targetId: id });
    });
    return detail(pool, await load(pool, id, ws.workspaceId), ws.role);
  });

  // ---------- printable prescription (F05-7) ----------
  app.get('/encounters/:id/prescription', read, async (req) => {
    const { id } = idParam.parse(req.params);
    const ws = req.workspace!;
    const e = await load(pool, id, ws.workspaceId);
    if (e.status !== 'signed') throw conflict('invalid_state', 'Sign the encounter before printing the prescription');
    const v = (await pool.query('select prescriptions, version, created_at from encounter_versions where encounter_id = $1 and version = $2', [id, e.current_version])).rows[0];
    if (!v.prescriptions.length) throw notFound('This encounter has no prescription');
    const info = (
      await pool.query(
        `select w.name as clinic, d.full_name as doctor, dp.license_number, r.full_name as patient, to_char(r.date_of_birth, 'YYYY-MM-DD') as dob, r.patient_number
           from encounters e join workspaces w on w.id = e.workspace_id join users d on d.id = e.author_id
           left join doctor_profiles dp on dp.user_id = e.author_id join care_relationships r on r.id = e.care_relationship_id
          where e.id = $1`,
        [id],
      )
    ).rows[0];
    await tx(pool, (c) => writeAudit(c, { ...ctxAudit(req), action: 'prescription.printed', targetType: 'encounter', targetId: id }));
    return {
      clinic: info.clinic,
      doctor: { fullName: info.doctor, licenseNumber: info.license_number },
      patient: { fullName: info.patient, dateOfBirth: info.dob, patientNumber: info.patient_number },
      date: e.signed_at,
      version: v.version,
      items: v.prescriptions,
    };
  });

  // ---------- patient side: only what the doctor published ----------
  const authed = { preHandler: authenticate(pool) };
  const publishedSelect = `
    select e.id, e.encounter_date, e.published_version, e.published_at, w.name as clinic, d.full_name as doctor,
           v.chief_complaint, v.diagnosis, v.plan, v.prescriptions
      from encounters e
      join patients p on p.user_id is not null
      join care_relationships r on r.id = e.care_relationship_id and r.patient_id = p.id
      join workspaces w on w.id = e.workspace_id
      join users d on d.id = e.author_id
      join encounter_versions v on v.encounter_id = e.id and v.version = e.published_version
     where p.user_id = $1 and e.published_version is not null and e.status = 'signed'`;
  // `history` and `private_notes` are deliberately not selected: patients see the published summary only.
  const presentPublished = (r: Record<string, unknown>) => ({
    id: r.id,
    encounterDate: r.encounter_date,
    publishedAt: r.published_at,
    clinicName: r.clinic,
    doctorName: r.doctor,
    chiefComplaint: r.chief_complaint,
    diagnosis: r.diagnosis,
    plan: r.plan,
    prescriptions: r.prescriptions,
  });

  app.get('/patient/encounters', authed, async (req) => {
    const rows = (await pool.query(`${publishedSelect} order by e.encounter_date desc limit 100`, [req.auth!.userId])).rows;
    return rows.map(presentPublished);
  });

  app.get('/patient/encounters/:id', authed, async (req) => {
    const { id } = idParam.parse(req.params);
    const r = (await pool.query(`${publishedSelect} and e.id = $2`, [req.auth!.userId, id])).rows[0];
    if (!r) throw notFound('Record not found');
    return { ...presentPublished(r), vitals: await observationsOf(pool, id, false) };
  });
}
