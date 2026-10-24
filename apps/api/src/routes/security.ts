import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { writeAudit } from '../audit.js';
import { authenticate, workspaceGuard } from '../auth.js';
import { config } from '../config.js';
import { tx } from '../db.js';
import { AppError, conflict, forbidden, notFound } from '../errors.js';

const idParam = z.object({ id: z.string().uuid() });

/** F11-7 data-subject operations (patient export, correction requests) and the legal-retention override. */
export function securityRoutes(app: FastifyInstance, pool: pg.Pool) {
  const authed = { preHandler: authenticate(pool) };
  const myPatient = async (userId: string) => {
    const p = (await pool.query('select id, phone, claimed_at from patients where user_id = $1', [userId])).rows[0];
    if (!p) throw forbidden('Claim your patient profile first');
    return p as { id: string; phone: string; claimed_at: Date };
  };

  // ---------- export my data ----------

  // Everything the patient is entitled to see about themselves. Clinic-private content (private notes, history,
  // administrative files) is never part of the bundle; document bytes are fetched through the normal signed links.
  app.post('/patient/export', authed, async (req) => {
    const userId = req.auth!.userId;
    const patient = await myPatient(userId);
    const recent = (await pool.query(`select count(*)::int as n from data_exports where user_id = $1 and created_at > now() - interval '1 hour'`, [userId])).rows[0].n;
    if (recent >= config.rateLimit.exportsPerUserPerHour) throw new AppError(429, 'rate_limited', 'You can export your data a few times per hour. Try again later.');

    const user = (await pool.query('select id, phone, full_name, created_at from users where id = $1', [userId])).rows[0];
    const relationships = (
      await pool.query(
        `select r.id, r.status, r.created_at, r.ended_at, r.full_name, to_char(r.date_of_birth, 'YYYY-MM-DD') as date_of_birth, r.sex, w.name as clinic, d.full_name as doctor
           from care_relationships r join workspaces w on w.id = r.workspace_id join users d on d.id = w.owner_id where r.patient_id = $1 order by r.created_at`,
        [patient.id],
      )
    ).rows;
    const documents = (
      await pool.query(
        `select d.id, d.source, d.category, d.title, d.notes, to_char(d.document_date, 'YYYY-MM-DD') as document_date, d.total_bytes, d.created_at, d.published_at, w.name as clinic
           from documents d left join workspaces w on w.id = d.workspace_id
          where d.patient_id = $1 and d.status = 'available' and (d.source = 'patient' or d.published_at is not null) order by d.created_at`,
        [patient.id],
      )
    ).rows;
    const encounters = (
      await pool.query(
        `select e.id, e.encounter_date, e.published_at, e.published_version, w.name as clinic, d.full_name as doctor, v.chief_complaint, v.diagnosis, v.plan, v.prescriptions
           from encounters e join care_relationships r on r.id = e.care_relationship_id join workspaces w on w.id = e.workspace_id
           join users d on d.id = e.author_id join encounter_versions v on v.encounter_id = e.id and v.version = e.published_version
          where r.patient_id = $1 and e.status = 'signed' and e.published_version is not null order by e.encounter_date`,
        [patient.id],
      )
    ).rows;
    const vitals = (
      await pool.query(`select encounter_id, kind, value, measured_at from observations where encounter_id = any($1) and voided_at is null order by measured_at`, [encounters.map((e) => e.id)])
    ).rows;
    const grants = (
      await pool.query(
        `select g.id, g.scope, g.purpose, g.created_at, g.expires_at, g.revoked_at, w.name as clinic from sharing_grants g join workspaces w on w.id = g.recipient_workspace_id where g.patient_id = $1 order by g.created_at`,
        [patient.id],
      )
    ).rows;
    const accessLog = (
      await pool.query(
        `select l.item_type, l.item_id, l.created_at, w.name as clinic, u.full_name as viewer from shared_access_log l join workspaces w on w.id = l.workspace_id join users u on u.id = l.accessor_user_id where l.patient_id = $1 order by l.created_at`,
        [patient.id],
      )
    ).rows;
    const corrections = (await pool.query('select id, target_type, target_id, description, status, resolution_note, created_at, resolved_at from correction_requests where patient_id = $1 order by created_at', [patient.id])).rows;

    await tx(pool, async (c) => {
      await c.query('insert into data_exports (user_id) values ($1)', [userId]);
      await writeAudit(c, {
        actorId: userId,
        actorRole: 'patient',
        action: 'patient.exported',
        targetType: 'patient',
        targetId: patient.id,
        metadata: { encounters: encounters.length, documents: documents.length, grants: grants.length },
        ip: req.ip,
      });
    });

    return {
      format: 'carelink-patient-export/1',
      exportedAt: new Date().toISOString(),
      profile: { userId: user.id, phone: user.phone, fullName: user.full_name, accountCreatedAt: user.created_at, claimedAt: patient.claimed_at },
      relationships: relationships.map((r) => ({ id: r.id, status: r.status, clinic: r.clinic, doctor: r.doctor, nameOnRecord: r.full_name, dateOfBirth: r.date_of_birth, sex: r.sex, since: r.created_at, endedAt: r.ended_at })),
      documents: documents.map((d) => ({ id: d.id, source: d.source, category: d.category, title: d.title, notes: d.notes, documentDate: d.document_date, sizeBytes: Number(d.total_bytes), uploadedAt: d.created_at, clinic: d.clinic })),
      encounters: encounters.map((e) => ({
        id: e.id,
        date: e.encounter_date,
        publishedAt: e.published_at,
        clinic: e.clinic,
        doctor: e.doctor,
        chiefComplaint: e.chief_complaint,
        diagnosis: e.diagnosis,
        plan: e.plan,
        prescriptions: e.prescriptions,
        vitals: vitals.filter((v) => v.encounter_id === e.id).map((v) => ({ kind: v.kind, value: Number(v.value), measuredAt: v.measured_at })),
      })),
      grants: grants.map((g) => ({ id: g.id, clinic: g.clinic, scope: g.scope, purpose: g.purpose, createdAt: g.created_at, expiresAt: g.expires_at, revokedAt: g.revoked_at })),
      accessLog: accessLog.map((l) => ({ itemType: l.item_type, itemId: l.item_id, clinic: l.clinic, viewer: l.viewer, at: l.created_at })),
      correctionRequests: corrections.map((r) => ({ id: r.id, targetType: r.target_type, targetId: r.target_id, description: r.description, status: r.status, resolutionNote: r.resolution_note, createdAt: r.created_at, resolvedAt: r.resolved_at })),
    };
  });

  // ---------- correction requests: asked by the patient, decided by the clinic, never applied silently ----------

  const presentMine = (r: Record<string, any>) => ({
    id: r.id,
    targetType: r.target_type,
    targetId: r.target_id,
    description: r.description,
    status: r.status,
    resolutionNote: r.resolution_note,
    clinicName: r.clinic_name,
    createdAt: r.created_at,
    resolvedAt: r.resolved_at,
  });

  app.post('/patient/correction-requests', authed, async (req, reply) => {
    const body = z
      .object({ targetType: z.enum(['encounter', 'document', 'relationship']), targetId: z.string().uuid(), description: z.string().trim().min(5).max(2000) })
      .parse(req.body);
    const userId = req.auth!.userId;
    const patient = await myPatient(userId);

    // The target must be a record the patient can see, and it determines which clinic receives the request.
    let workspaceId: string | undefined;
    if (body.targetType === 'encounter') {
      workspaceId = (
        await pool.query(
          `select e.workspace_id from encounters e join care_relationships r on r.id = e.care_relationship_id
            where e.id = $1 and r.patient_id = $2 and e.status = 'signed' and e.published_version is not null`,
          [body.targetId, patient.id],
        )
      ).rows[0]?.workspace_id;
    } else if (body.targetType === 'document') {
      workspaceId = (
        await pool.query(`select workspace_id from documents where id = $1 and patient_id = $2 and status = 'available' and source <> 'patient' and published_at is not null`, [body.targetId, patient.id])
      ).rows[0]?.workspace_id;
    } else {
      workspaceId = (await pool.query('select workspace_id from care_relationships where id = $1 and patient_id = $2', [body.targetId, patient.id])).rows[0]?.workspace_id;
    }
    if (!workspaceId) throw notFound('Record not found');

    const id = await tx(pool, async (c) => {
      await c.query('select pg_advisory_xact_lock(hashtext($1))', [`corr:${patient.id}`]);
      const open = (await c.query(`select target_id from correction_requests where patient_id = $1 and status = 'open'`, [patient.id])).rows;
      if (open.some((o) => o.target_id === body.targetId)) throw conflict('request_open', 'You already have an open request for this record');
      if (open.length >= 10) throw new AppError(429, 'rate_limited', 'You have too many open requests. Wait for the clinics to respond.');
      const r = (
        await c.query(
          `insert into correction_requests (patient_id, requested_by, workspace_id, target_type, target_id, description) values ($1,$2,$3,$4,$5,$6) returning id`,
          [patient.id, userId, workspaceId, body.targetType, body.targetId, body.description],
        )
      ).rows[0];
      // The description is the patient's free text; the audit log keeps only the structural facts.
      await writeAudit(c, { workspaceId, actorId: userId, actorRole: 'patient', action: 'correction.requested', targetType: body.targetType, targetId: body.targetId, metadata: { requestId: r.id }, ip: req.ip });
      return r.id as string;
    });
    reply.code(201);
    return { id, status: 'open' };
  });

  app.get('/patient/correction-requests', authed, async (req) => {
    const patient = await myPatient(req.auth!.userId);
    const rows = (
      await pool.query(`select q.*, w.name as clinic_name from correction_requests q join workspaces w on w.id = q.workspace_id where q.patient_id = $1 order by q.created_at desc limit 100`, [patient.id])
    ).rows;
    return rows.map(presentMine);
  });

  // Clinic side. Requires clinical.read, so front-desk roles never see the free text patients write about their records.
  app.get('/correction-requests', workspaceGuard(pool, 'clinical.read'), async (req) => {
    const { status } = z.object({ status: z.enum(['open', 'resolved', 'rejected']).optional() }).parse(req.query);
    const rows = (
      await pool.query(
        `select q.*, r.id as relationship_id, r.full_name as patient_name, r.patient_number,
                case q.target_type
                  when 'encounter' then (select to_char(e.encounter_date, 'YYYY-MM-DD') from encounters e where e.id = q.target_id)
                  when 'document' then (select coalesce(nullif(d.title, ''), d.category) from documents d where d.id = q.target_id)
                  else 'Registration details' end as target_label
           from correction_requests q
           join care_relationships r on r.patient_id = q.patient_id and r.workspace_id = q.workspace_id
          where q.workspace_id = $1 and ($2::text is null or q.status = $2)
          order by (q.status = 'open') desc, q.created_at desc limit 200`,
        [req.workspace!.workspaceId, status ?? null],
      )
    ).rows;
    return rows.map((r) => ({
      id: r.id,
      status: r.status,
      targetType: r.target_type,
      targetId: r.target_id,
      targetLabel: r.target_label,
      description: r.description,
      patient: { id: r.relationship_id, fullName: r.patient_name, patientNumber: r.patient_number },
      resolutionNote: r.resolution_note,
      createdAt: r.created_at,
      resolvedAt: r.resolved_at,
    }));
  });

  for (const decision of ['resolve', 'reject'] as const) {
    app.post(`/correction-requests/:id/${decision}`, workspaceGuard(pool, 'clinical.write'), async (req) => {
      const { id } = idParam.parse(req.params);
      const { note } = z.object({ note: z.string().trim().min(3).max(1000) }).parse(req.body);
      const ws = req.workspace!;
      const status = decision === 'resolve' ? 'resolved' : 'rejected';
      await tx(pool, async (c) => {
        // Only the status and the clinic's note change here. Any change to the clinical record itself goes through amendment.
        const r = await c.query(
          `update correction_requests set status = $3, resolution_note = $4, resolved_by = $5, resolved_at = now() where id = $1 and workspace_id = $2 and status = 'open' returning target_type, target_id`,
          [id, ws.workspaceId, status, note, req.auth!.userId],
        );
        if (!r.rowCount) {
          const exists = await c.query('select status from correction_requests where id = $1 and workspace_id = $2', [id, ws.workspaceId]);
          if (!exists.rowCount) throw notFound('Request not found');
          throw conflict('invalid_state', `Request is already ${exists.rows[0].status}`);
        }
        await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: `correction.${status}`, targetType: r.rows[0].target_type, targetId: r.rows[0].target_id, metadata: { requestId: id }, ip: req.ip });
      });
      return { ok: true, status };
    });
  }

  // ---------- retention policy and legal hold (F11-7) ----------

  app.get('/workspace/retention', workspaceGuard(pool, 'audit.read'), async (req) => {
    const holds = (
      await pool.query(`select id, full_name, patient_number, legal_hold_reason, legal_hold_set_at from care_relationships where workspace_id = $1 and legal_hold order by legal_hold_set_at desc`, [req.workspace!.workspaceId])
    ).rows;
    return {
      policy: config.retention,
      legalHolds: holds.map((h) => ({ patientId: h.id, fullName: h.full_name, patientNumber: h.patient_number, reason: h.legal_hold_reason, setAt: h.legal_hold_set_at })),
    };
  });

  // The override: while a hold is set, documents of that patient cannot be deleted by the clinic or the patient.
  app.patch('/patients/:id/legal-hold', workspaceGuard(pool, 'relationships.manage'), async (req) => {
    const { id } = idParam.parse(req.params);
    const body = z.discriminatedUnion('hold', [z.object({ hold: z.literal(true), reason: z.string().trim().min(5).max(500) }), z.object({ hold: z.literal(false) })]).parse(req.body);
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      const r = await c.query(
        body.hold
          ? `update care_relationships set legal_hold = true, legal_hold_reason = $3, legal_hold_set_by = $4, legal_hold_set_at = now() where id = $1 and workspace_id = $2`
          : `update care_relationships set legal_hold = false, legal_hold_reason = null where id = $1 and workspace_id = $2`,
        body.hold ? [id, ws.workspaceId, body.reason, req.auth!.userId] : [id, ws.workspaceId],
      );
      if (!r.rowCount) throw notFound('Patient not found');
      await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: body.hold ? 'retention.legal_hold_set' : 'retention.legal_hold_lifted', targetType: 'patient', targetId: id, metadata: body.hold ? { reason: body.reason } : {}, ip: req.ip });
    });
    return { ok: true, legalHold: body.hold };
  });
}
