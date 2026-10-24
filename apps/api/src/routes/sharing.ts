import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { writeAudit } from '../audit.js';
import { authenticate, workspaceGuard } from '../auth.js';
import { config } from '../config.js';
import { tx } from '../db.js';
import { badRequest, conflict, forbidden, notFound } from '../errors.js';
import { signLink } from '../storage.js';

const CATEGORIES = ['encounters', 'prescription', 'lab_result', 'imaging', 'report', 'other'] as const;
const dateStr = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);
const itemRef = z.object({ type: z.enum(['document', 'encounter']), id: z.string().uuid() });
// Private notes and administrative files are never shareable: they are not in the candidate set at all (F08-2).
export const scopeSchema = z
  .object({ items: z.array(itemRef).min(1).max(100).optional(), categories: z.array(z.enum(CATEGORIES)).min(1).optional(), from: dateStr.optional(), to: dateStr.optional() })
  .strict()
  .refine((s) => !!s.items !== !!s.categories, 'Choose specific items or categories')
  .refine((s) => !s.items || (!s.from && !s.to), 'A date range applies to categories only');
export type Scope = z.infer<typeof scopeSchema>;

export interface Item {
  type: 'document' | 'encounter';
  id: string;
  category: string;
  date: string; // YYYY-MM-DD
  title: string;
  source: string;
  clinicName: string | null;
}

const idParam = z.object({ id: z.string().uuid() });
const days = z.number().int().min(1).max(config.sharing.maxDays);

export const isSensitive = (scope: Scope) =>
  scope.items ? scope.items.some((i) => i.type === 'encounter') : scope.categories!.some((c) => config.sharing.sensitiveCategories.includes(c));

/** Everything of a patient's that could ever be shared: published encounters and patient-visible documents. */
export async function candidates(db: Pick<pg.Pool, 'query'>, patientId: string): Promise<Item[]> {
  const docs = (
    await db.query(
      `select d.id, d.category, coalesce(d.document_date, d.created_at::date)::text as date, d.title, d.source, w.name as clinic
         from documents d left join workspaces w on w.id = d.workspace_id
        where d.patient_id = $1 and d.status = 'available' and d.category <> 'administrative' and (d.source = 'patient' or d.published_at is not null)`,
      [patientId],
    )
  ).rows;
  const encs = (
    await db.query(
      `select e.id, e.encounter_date::date::text as date, v.chief_complaint, w.name as clinic
         from encounters e join care_relationships r on r.id = e.care_relationship_id
         join workspaces w on w.id = e.workspace_id
         join encounter_versions v on v.encounter_id = e.id and v.version = e.published_version
        where r.patient_id = $1 and e.status = 'signed' and e.published_version is not null`,
      [patientId],
    )
  ).rows;
  return [
    ...docs.map((d): Item => ({ type: 'document', id: d.id, category: d.category, date: d.date, title: d.title || d.category, source: d.source === 'patient' ? 'patient' : 'clinician', clinicName: d.clinic })),
    ...encs.map((e): Item => ({ type: 'encounter', id: e.id, category: 'encounters', date: e.date, title: e.chief_complaint || 'Consultation', source: 'clinician', clinicName: e.clinic })),
  ];
}

export function matches(scope: Scope, item: Item): boolean {
  if (scope.items) return scope.items.some((i) => i.type === item.type && i.id === item.id);
  if (!scope.categories!.includes(item.category as (typeof CATEGORIES)[number])) return false;
  if (scope.from && item.date < scope.from) return false;
  if (scope.to && item.date > scope.to) return false;
  return true;
}

/** True when `inner` grants nothing that `outer` does not (used when a patient narrows a request). */
function isSubset(inner: Scope, outer: Scope, all: Item[]): boolean {
  if (outer.items) {
    // Only specific items can be narrowed to specific items.
    const set = new Set(outer.items.map((i) => `${i.type}:${i.id}`));
    return !!inner.items && inner.items.every((i) => set.has(`${i.type}:${i.id}`));
  }
  if (inner.items) return inner.items.every((i) => all.some((a) => a.type === i.type && a.id === i.id && matches(outer, a)));
  // Category scopes are compared structurally so a category with no items yet cannot widen a request.
  const catsOk = inner.categories!.every((c) => outer.categories!.includes(c));
  const fromOk = !outer.from || (!!inner.from && inner.from >= outer.from);
  const toOk = !outer.to || (!!inner.to && inner.to <= outer.to);
  return catsOk && fromOk && toOk;
}

const ACTIVE = `g.revoked_at is null and g.expires_at > now()`;

export function sharingRoutes(app: FastifyInstance, pool: pg.Pool) {
  const authed = { preHandler: authenticate(pool) };
  const myPatient = async (userId: string): Promise<{ id: string; phone: string }> => {
    const p = (await pool.query('select id, phone from patients where user_id = $1', [userId])).rows[0];
    if (!p) throw forbidden('Claim your patient profile first');
    return p;
  };

  /** Spec 10: tell the receiving clinic's owner that records were shared with it. Generic text outside the app. */
  const notifyGrantReceived = async (grantId: string) => {
    const g = (await pool.query('select w.owner_id from sharing_grants g join workspaces w on w.id = g.recipient_workspace_id where g.id = $1', [grantId])).rows[0];
    if (g) await app.notifier.notify({ userId: g.owner_id, type: 'grant_received', key: `grant-received:${grantId}`, params: { grantId } });
  };

  /** F08-5 / audit: record expiry once, lazily on read and periodically from the server. */
  async function sweep() {
    const grants = (await pool.query(`select id, patient_id, recipient_workspace_id from sharing_grants where revoked_at is null and expires_at <= now() and expiry_recorded_at is null limit 200`)).rows;
    for (const g of grants) {
      await tx(pool, async (c) => {
        const r = await c.query('update sharing_grants set expiry_recorded_at = now() where id = $1 and expiry_recorded_at is null', [g.id]);
        if (r.rowCount) await writeAudit(c, { workspaceId: g.recipient_workspace_id, actorRole: 'system', action: 'grant.expired', targetType: 'grant', targetId: g.id });
      });
    }
    await pool.query(`update access_requests set status = 'expired' where status = 'pending' and expires_at <= now()`);
  }
  app.decorate('sweepSharing', sweep);

  const presentScope = (s: Scope) => s;
  const presentGrant = (g: Record<string, any>) => ({
    id: g.id,
    scope: presentScope(g.scope),
    purpose: g.purpose,
    createdAt: g.created_at,
    expiresAt: g.expires_at,
    revokedAt: g.revoked_at,
    status: g.revoked_at ? 'revoked' : new Date(g.expires_at) <= new Date() ? 'expired' : 'active',
    expiresSoon: !g.revoked_at && new Date(g.expires_at) > new Date() && new Date(g.expires_at).getTime() - Date.now() < config.sharing.expiringSoonDays * 86_400_000,
    recipient: { workspaceId: g.recipient_workspace_id, clinicName: g.clinic_name, doctorName: g.doctor_name },
  });

  /** Validates days/scope against the sensitivity rules (F08-4/5) and returns the resolved expiry. */
  function checkTerms(scope: Scope, d: number, acknowledgeRetention: boolean | undefined, acknowledgeSensitive: boolean | undefined) {
    if (!acknowledgeRetention) throw badRequest('retention_ack_required', 'Acknowledge that records a clinic has already incorporated into its chart are kept after you revoke access');
    if (isSensitive(scope)) {
      if (d > config.sharing.sensitiveMaxDays) throw badRequest('duration_too_long', `Sharing consultation records is limited to ${config.sharing.sensitiveMaxDays} days at a time`);
      if (!acknowledgeSensitive) throw badRequest('sensitive_ack_required', 'Consultation records are sensitive; confirm you want to share them');
    }
    return new Date(Date.now() + d * 86_400_000);
  }

  async function assertScopeShareable(patientId: string, scope: Scope) {
    const all = await candidates(pool, patientId);
    if (scope.items) {
      const known = new Set(all.map((i) => `${i.type}:${i.id}`));
      if (!scope.items.every((i) => known.has(`${i.type}:${i.id}`))) throw badRequest('invalid_scope', 'One or more items cannot be shared');
    }
    return all;
  }

  // =============== Patient side ===============

  app.get('/patient/shareable', authed, async (req) => {
    const p = await myPatient(req.auth!.userId);
    return (await candidates(pool, p.id)).sort((a, b) => b.date.localeCompare(a.date));
  });

  app.post('/patient/grants', authed, async (req, reply) => {
    const body = z
      .object({
        recipient: z.union([z.object({ doctorPhone: z.string().regex(/^\+[1-9]\d{7,14}$/) }), z.object({ relationshipId: z.string().uuid() })]),
        scope: scopeSchema,
        days: days.default(config.sharing.defaultDays),
        purpose: z.string().trim().max(300).default(''),
        acknowledgeRetention: z.boolean().optional(),
        acknowledgeSensitive: z.boolean().optional(),
      })
      .parse(req.body);
    const patient = await myPatient(req.auth!.userId);
    const expiresAt = checkTerms(body.scope, body.days, body.acknowledgeRetention, body.acknowledgeSensitive);
    await assertScopeShareable(patient.id, body.scope);

    // F08-8: recipients are registered, licence-verified clinicians.
    const rcpt =
      'doctorPhone' in body.recipient
        ? (
            await pool.query(
              `select w.id from users u join doctor_profiles d on d.user_id = u.id and d.verification_status = 'verified' join workspaces w on w.owner_id = u.id where u.phone = $1`,
              [body.recipient.doctorPhone],
            )
          ).rows[0]
        : (
            await pool.query(
              `select w.id from care_relationships r join workspaces w on w.id = r.workspace_id join doctor_profiles d on d.user_id = w.owner_id and d.verification_status = 'verified' where r.id = $1 and r.patient_id = $2`,
              [body.recipient.relationshipId, patient.id],
            )
          ).rows[0];
    if (!rcpt) throw notFound('No verified clinician found for that recipient');

    const grant = await tx(pool, async (c) => {
      const g = (
        await c.query(
          `insert into sharing_grants (patient_id, recipient_workspace_id, granted_by, scope, purpose, expires_at) values ($1,$2,$3,$4,$5,$6) returning id`,
          [patient.id, rcpt.id, req.auth!.userId, JSON.stringify(body.scope), body.purpose, expiresAt],
        )
      ).rows[0];
      await writeAudit(c, { workspaceId: rcpt.id, actorId: req.auth!.userId, actorRole: 'patient', action: 'grant.created', targetType: 'grant', targetId: g.id, metadata: { scope: body.scope, days: body.days }, ip: req.ip });
      return g.id as string;
    });
    reply.code(201);
    await notifyGrantReceived(grant);
    return getPatientGrant(patient.id, grant);
  });

  const grantSelect = `select g.*, w.name as clinic_name, u.full_name as doctor_name from sharing_grants g join workspaces w on w.id = g.recipient_workspace_id join users u on u.id = w.owner_id`;
  async function getPatientGrant(patientId: string, id: string) {
    const g = (await pool.query(`${grantSelect} where g.id = $1 and g.patient_id = $2`, [id, patientId])).rows[0];
    if (!g) throw notFound('Grant not found');
    return presentGrant(g);
  }

  app.get('/patient/grants', authed, async (req) => {
    const p = await myPatient(req.auth!.userId);
    await sweep();
    const rows = (await pool.query(`${grantSelect} where g.patient_id = $1 order by g.created_at desc limit 200`, [p.id])).rows;
    return rows.map(presentGrant);
  });

  app.delete('/patient/grants/:id', authed, async (req) => {
    const { id } = idParam.parse(req.params);
    const p = await myPatient(req.auth!.userId);
    await tx(pool, async (c) => {
      const r = await c.query(`update sharing_grants set revoked_at = now(), revoked_by = $3 where id = $1 and patient_id = $2 and revoked_at is null returning recipient_workspace_id`, [id, p.id, req.auth!.userId]);
      if (!r.rowCount) throw notFound('Active grant not found');
      await writeAudit(c, { workspaceId: r.rows[0].recipient_workspace_id, actorId: req.auth!.userId, actorRole: 'patient', action: 'grant.revoked', targetType: 'grant', targetId: id, ip: req.ip });
    });
    return { ok: true };
  });

  // F08-7: who viewed what and when.
  app.get('/patient/access-log', authed, async (req) => {
    const { grantId } = z.object({ grantId: z.string().uuid().optional() }).parse(req.query);
    const p = await myPatient(req.auth!.userId);
    const rows = (
      await pool.query(
        `select l.id, l.grant_id, l.item_type, l.item_id, l.created_at, w.name as clinic_name, u.full_name as viewer_name,
                coalesce(d.title, e.chief_complaint) as item_title
           from shared_access_log l join workspaces w on w.id = l.workspace_id join users u on u.id = l.accessor_user_id
           left join documents d on l.item_type = 'document' and d.id = l.item_id
           left join encounter_versions e on l.item_type = 'encounter' and e.encounter_id = l.item_id and e.version = 1
          where l.patient_id = $1 and ($2::uuid is null or l.grant_id = $2) order by l.created_at desc limit 200`,
        [p.id, grantId ?? null],
      )
    ).rows;
    return rows.map((r) => ({ id: r.id, grantId: r.grant_id, itemType: r.item_type, itemId: r.item_id, itemTitle: r.item_title || null, clinicName: r.clinic_name, viewerName: r.viewer_name, at: r.created_at }));
  });

  const requestSelect = `select q.*, w.name as clinic_name, u.full_name as doctor_name from access_requests q join workspaces w on w.id = q.workspace_id join users u on u.id = q.requested_by`;
  const presentRequest = (q: Record<string, any>) => ({
    id: q.id,
    status: q.status,
    scope: q.scope,
    purpose: q.purpose,
    requestedDays: q.requested_days,
    sensitive: isSensitive(q.scope),
    createdAt: q.created_at,
    expiresAt: q.expires_at,
    decidedAt: q.decided_at,
    grantId: q.grant_id,
    clinicName: q.clinic_name,
    doctorName: q.doctor_name,
  });

  app.get('/patient/access-requests', authed, async (req) => {
    const p = await myPatient(req.auth!.userId);
    await sweep();
    return (await pool.query(`${requestSelect} where q.patient_id = $1 order by q.created_at desc limit 100`, [p.id])).rows.map(presentRequest);
  });

  app.post('/patient/access-requests/:id/approve', authed, async (req) => {
    const { id } = idParam.parse(req.params);
    const body = z
      .object({ days: days.optional(), scope: scopeSchema.optional(), acknowledgeRetention: z.boolean().optional(), acknowledgeSensitive: z.boolean().optional() })
      .parse(req.body ?? {});
    const p = await myPatient(req.auth!.userId);
    await sweep();
    const q = (await pool.query(`select * from access_requests where id = $1 and patient_id = $2`, [id, p.id])).rows[0];
    if (!q) throw notFound('Request not found');
    if (q.status !== 'pending') throw conflict('invalid_state', `Request is ${q.status}`);
    const all = await assertScopeShareable(p.id, body.scope ?? q.scope);
    // The patient may narrow what was asked for, never widen it (F08-2).
    const scope: Scope = body.scope ?? q.scope;
    if (body.scope && !isSubset(body.scope, q.scope, all)) throw badRequest('scope_widened', 'You can only narrow the requested scope');
    const d = Math.min(body.days ?? q.requested_days, q.requested_days);
    const expiresAt = checkTerms(scope, d, body.acknowledgeRetention, body.acknowledgeSensitive);
    const gid = await tx(pool, async (c) => {
      const cur = await c.query(`select status from access_requests where id = $1 for update`, [id]);
      if (cur.rows[0].status !== 'pending') throw conflict('invalid_state', 'Request already decided');
      const g = (
        await c.query(`insert into sharing_grants (patient_id, recipient_workspace_id, granted_by, scope, purpose, request_id, expires_at) values ($1,$2,$3,$4,$5,$6,$7) returning id`, [p.id, q.workspace_id, req.auth!.userId, JSON.stringify(scope), q.purpose, id, expiresAt])
      ).rows[0];
      await c.query(`update access_requests set status = 'approved', decided_at = now(), grant_id = $2 where id = $1`, [id, g.id]);
      await writeAudit(c, { workspaceId: q.workspace_id, actorId: req.auth!.userId, actorRole: 'patient', action: 'access_request.approved', targetType: 'access_request', targetId: id, metadata: { grantId: g.id }, ip: req.ip });
      await writeAudit(c, { workspaceId: q.workspace_id, actorId: req.auth!.userId, actorRole: 'patient', action: 'grant.created', targetType: 'grant', targetId: g.id, metadata: { scope, days: d, requestId: id }, ip: req.ip });
      return g.id as string;
    });
    await app.notifier.notify({ userId: q.requested_by, type: 'access_request_approved', key: `access-request-approved:${id}`, params: { requestId: id, grantId: gid } });
    const owner = (await pool.query('select owner_id from workspaces where id = $1', [q.workspace_id])).rows[0];
    if (owner && owner.owner_id !== q.requested_by) await notifyGrantReceived(gid);
    return getPatientGrant(p.id, gid);
  });

  app.post('/patient/access-requests/:id/deny', authed, async (req) => {
    const { id } = idParam.parse(req.params);
    const p = await myPatient(req.auth!.userId);
    let requester: string | null = null;
    await tx(pool, async (c) => {
      const r = await c.query(`update access_requests set status = 'denied', decided_at = now() where id = $1 and patient_id = $2 and status = 'pending' and expires_at > now() returning workspace_id, requested_by`, [id, p.id]);
      if (!r.rowCount) throw notFound('Pending request not found');
      await writeAudit(c, { workspaceId: r.rows[0].workspace_id, actorId: req.auth!.userId, actorRole: 'patient', action: 'access_request.denied', targetType: 'access_request', targetId: id, ip: req.ip });
      requester = r.rows[0].requested_by;
    });
    if (requester) await app.notifier.notify({ userId: requester, type: 'access_request_denied', key: `access-request-denied:${id}`, params: { requestId: id } });
    return { ok: true };
  });

  // =============== Clinic side: requesting and reading ===============

  app.post('/patients/:id/access-requests', workspaceGuard(pool, 'clinical.write'), async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = z.object({ scope: scopeSchema, purpose: z.string().trim().min(3).max(300), days: days.default(config.sharing.defaultDays) }).parse(req.body);
    const ws = req.workspace!;
    const rel = (await pool.query(`select r.status, r.patient_id, p.user_id from care_relationships r join patients p on p.id = r.patient_id where r.id = $1 and r.workspace_id = $2`, [id, ws.workspaceId])).rows[0];
    if (!rel) throw notFound('Patient not found');
    if (rel.status !== 'active') throw conflict('invalid_state', 'The patient must have an active relationship with your clinic');
    if (!rel.user_id) throw conflict('patient_not_registered', 'The patient has not created an account yet, so they cannot receive requests');
    if (isSensitive(body.scope) && body.days > config.sharing.sensitiveMaxDays) throw badRequest('duration_too_long', `Consultation records can be requested for at most ${config.sharing.sensitiveMaxDays} days`);
    const row = await tx(pool, async (c) => {
      try {
        const q = (
          await c.query(
            `insert into access_requests (patient_id, workspace_id, requested_by, scope, purpose, requested_days, expires_at) values ($1,$2,$3,$4,$5,$6, now() + make_interval(days => $7)) returning id`,
            [rel.patient_id, ws.workspaceId, req.auth!.userId, JSON.stringify(body.scope), body.purpose, body.days, config.sharing.requestTtlDays],
          )
        ).rows[0];
        await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: 'access_request.sent', targetType: 'access_request', targetId: q.id, metadata: { scope: body.scope }, ip: req.ip });
        return q.id as string;
      } catch (e) {
        if ((e as { code?: string }).code === '23505') throw conflict('request_pending', 'A request to this patient is already pending');
        throw e;
      }
    });
    reply.code(201);
    const shown = (await pool.query(`${requestSelect} where q.id = $1`, [row])).rows[0];
    await app.notifier.notify({ userId: rel.user_id, type: 'access_request_received', key: `access-request:${row}`, params: { clinicName: shown.clinic_name ?? '', requestId: row } });
    return presentRequest(shown);
  });

  app.get('/access-requests', workspaceGuard(pool, 'clinical.read'), async (req) => {
    await sweep();
    const rows = (await pool.query(`${requestSelect} where q.workspace_id = $1 order by q.created_at desc limit 100`, [req.workspace!.workspaceId])).rows;
    return rows.map(presentRequest);
  });

  app.delete('/access-requests/:id', workspaceGuard(pool, 'clinical.write'), async (req) => {
    const { id } = idParam.parse(req.params);
    const r = await pool.query(`update access_requests set status = 'cancelled', decided_at = now() where id = $1 and workspace_id = $2 and status = 'pending'`, [id, req.workspace!.workspaceId]);
    if (!r.rowCount) throw notFound('Pending request not found');
    return { ok: true };
  });

  const read = workspaceGuard(pool, 'clinical.read');
  const activeGrant = async (grantId: string, workspaceId: string) => {
    const g = (await pool.query(`select g.* from sharing_grants g where g.id = $1 and g.recipient_workspace_id = $2 and ${ACTIVE}`, [grantId, workspaceId])).rows[0];
    if (!g) throw notFound('Shared record not found'); // expired, revoked and never-existed look identical
    return g as { id: string; patient_id: string; scope: Scope; expires_at: Date; purpose: string };
  };

  app.get('/shared-with-me', read, async (req) => {
    const ws = req.workspace!;
    await sweep();
    const rows = (
      await pool.query(
        `select g.id, g.scope, g.purpose, g.created_at, g.expires_at, coalesce(pu.full_name, p.phone) as patient_name,
                (select r.id from care_relationships r where r.patient_id = g.patient_id and r.workspace_id = g.recipient_workspace_id) as relationship_id
           from sharing_grants g join patients p on p.id = g.patient_id left join users pu on pu.id = p.user_id
          where g.recipient_workspace_id = $1 and ${ACTIVE} order by g.created_at desc`,
        [ws.workspaceId],
      )
    ).rows;
    return rows.map((r) => ({ id: r.id, scope: r.scope, purpose: r.purpose, createdAt: r.created_at, expiresAt: r.expires_at, patientName: r.patient_name, relationshipId: r.relationship_id }));
  });

  app.get('/shared-with-me/:id/items', read, async (req) => {
    const { id } = idParam.parse(req.params);
    const g = await activeGrant(id, req.workspace!.workspaceId);
    const all = await candidates(pool, g.patient_id);
    return all.filter((i) => matches(g.scope, i)).sort((a, b) => b.date.localeCompare(a.date)).map((i) => ({ ...i, sharedBy: 'patient', provenance: i.source === 'patient' ? 'patient_submitted_unverified' : 'clinician_authored' }));
  });

  async function loadShared(grantId: string, workspaceId: string, type: Item['type'], itemId: string) {
    const g = await activeGrant(grantId, workspaceId);
    const item = (await candidates(pool, g.patient_id)).find((i) => i.type === type && i.id === itemId && matches(g.scope, i));
    if (!item) throw notFound('Shared record not found');
    return { g, item };
  }
  const logView = (c: pg.PoolClient, req: { auth?: { userId: string }; workspace?: { workspaceId: string; role: string }; ip: string }, g: { id: string; patient_id: string }, type: string, itemId: string) =>
    Promise.all([
      c.query(`insert into shared_access_log (grant_id, patient_id, workspace_id, accessor_user_id, item_type, item_id) values ($1,$2,$3,$4,$5,$6)`, [g.id, g.patient_id, req.workspace!.workspaceId, req.auth!.userId, type, itemId]),
      writeAudit(c, { workspaceId: req.workspace!.workspaceId, actorId: req.auth!.userId, actorRole: req.workspace!.role, action: 'shared_item.viewed', targetType: type, targetId: itemId, metadata: { grantId: g.id }, ip: req.ip }),
    ]);

  app.get('/shared-with-me/:id/encounters/:encId', read, async (req) => {
    const { id, encId } = z.object({ id: z.string().uuid(), encId: z.string().uuid() }).parse(req.params);
    const { g } = await loadShared(id, req.workspace!.workspaceId, 'encounter', encId);
    const r = (
      await pool.query(
        `select e.id, e.encounter_date, e.published_at, e.published_version, w.name as clinic, d.full_name as doctor, v.chief_complaint, v.diagnosis, v.plan, v.prescriptions
           from encounters e join workspaces w on w.id = e.workspace_id join users d on d.id = e.author_id
           join encounter_versions v on v.encounter_id = e.id and v.version = e.published_version where e.id = $1`,
        [encId],
      )
    ).rows[0];
    const vitals = (await pool.query(`select kind, value, measured_at from observations where encounter_id = $1 and voided_at is null order by measured_at`, [encId])).rows;
    await tx(pool, (c) => logView(c, req, g, 'encounter', encId));
    // `history` and `private_notes` are never part of a shared view.
    return {
      id: r.id,
      provenance: 'clinician_authored',
      encounterDate: r.encounter_date,
      clinicName: r.clinic,
      doctorName: r.doctor,
      version: r.published_version,
      chiefComplaint: r.chief_complaint,
      diagnosis: r.diagnosis,
      plan: r.plan,
      prescriptions: r.prescriptions,
      vitals: vitals.map((v) => ({ kind: v.kind, value: Number(v.value), measuredAt: v.measured_at })),
    };
  });

  app.get('/shared-with-me/:id/documents/:docId', read, async (req) => {
    const { id, docId } = z.object({ id: z.string().uuid(), docId: z.string().uuid() }).parse(req.params);
    await loadShared(id, req.workspace!.workspaceId, 'document', docId);
    const d = (
      await pool.query(
        `select d.id, d.source, d.category, d.title, d.notes, d.document_date, d.created_at,
                (select json_agg(json_build_object('page', p.page, 'mime', p.mime) order by p.page) from document_pages p where p.document_id = d.id) as pages
           from documents d where d.id = $1`,
        [docId],
      )
    ).rows[0];
    return { id: d.id, provenance: d.source === 'patient' ? 'patient_submitted_unverified' : 'clinician_authored', category: d.category, title: d.title, notes: d.notes, documentDate: d.document_date, createdAt: d.created_at, pages: d.pages ?? [] };
  });

  app.get('/shared-with-me/:id/documents/:docId/pages/:page/link', read, async (req) => {
    const { id, docId, page } = z.object({ id: z.string().uuid(), docId: z.string().uuid(), page: z.coerce.number().int().min(1) }).parse(req.params);
    const ws = req.workspace!;
    await loadShared(id, ws.workspaceId, 'document', docId);
    if (!(await pool.query('select 1 from document_pages where document_id = $1 and page = $2', [docId, page])).rowCount) throw notFound('Page not found');
    const { token, expiresAt } = signLink({ d: docId, p: page, u: req.auth!.userId, w: ws.workspaceId, g: id });
    return { path: `/files/${token}`, expiresAt };
  });
}

declare module 'fastify' {
  interface FastifyInstance {
    sweepSharing: () => Promise<void>;
  }
}
