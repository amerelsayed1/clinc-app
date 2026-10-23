import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { writeAudit } from '../audit.js';
import { authenticate, workspaceGuard } from '../auth.js';
import { tx } from '../db.js';
import { AppError, conflict, notFound } from '../errors.js';
import { phoneSchema } from './auth.js';

const nameSchema = z.string().trim().min(2).max(120);
const dobSchema = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD')
  .refine((d) => !Number.isNaN(Date.parse(d)) && new Date(d) <= new Date() && d >= '1900-01-01', 'Invalid date of birth');
const sexSchema = z.enum(['male', 'female']);

const SELECT = `
  select r.id, r.patient_number, r.full_name, p.phone, to_char(r.date_of_birth, 'YYYY-MM-DD') as date_of_birth, r.sex,
         r.status, r.created_at, r.ended_at, r.ended_by, (p.user_id is not null) as has_account
    from care_relationships r join patients p on p.id = r.patient_id`;

interface Row {
  id: string;
  patient_number: number;
  full_name: string;
  phone: string;
  date_of_birth: string | null;
  sex: string | null;
  status: string;
  created_at: Date;
  ended_at: Date | null;
  ended_by: string | null;
  has_account: boolean;
}
const present = (r: Row) => ({
  id: r.id,
  patientNumber: r.patient_number,
  fullName: r.full_name,
  phone: r.phone,
  dateOfBirth: r.date_of_birth,
  sex: r.sex,
  status: r.status,
  hasAccount: r.has_account,
  createdAt: r.created_at,
  endedAt: r.ended_at,
  endedBy: r.ended_by,
});

// Case/whitespace-insensitive name comparison used for duplicate suspicion.
const NORM = `lower(regexp_replace(btrim(r.full_name), '\\s+', ' ', 'g'))`;

export function patientRoutes(app: FastifyInstance, pool: pg.Pool) {
  // ---------- Workspace side (doctor / nurse / receptionist) ----------

  // F03-2: search is always scoped to the caller's own workspace. Phone is exact, patient number is exact, otherwise name substring.
  app.get('/patients', workspaceGuard(pool, 'patients.read'), async (req) => {
    const q = z
      .object({
        q: z.string().trim().max(120).optional(),
        status: z.enum(['open', 'active', 'invited', 'ended']).default('open'),
        limit: z.coerce.number().int().min(1).max(100).default(25),
        offset: z.coerce.number().int().min(0).default(0),
      })
      .parse(req.query);
    const params: unknown[] = [req.workspace!.workspaceId, q.status === 'open' ? ['active', 'invited'] : [q.status]];
    let cond = '';
    if (q.q) {
      if (phoneSchema.safeParse(q.q).success) {
        params.push(q.q);
        cond = `and p.phone = $${params.length}`;
      } else if (/^#?\d{1,8}$/.test(q.q)) {
        params.push(Number(q.q.replace('#', '')));
        cond = `and r.patient_number = $${params.length}`;
      } else {
        params.push(`%${q.q.replace(/[\\%_]/g, '\\$&')}%`);
        cond = `and r.full_name ilike $${params.length}`;
      }
    }
    params.push(q.limit, q.offset);
    const rows = (
      await pool.query(
        `${SELECT} where r.workspace_id = $1 and r.status = any($2) ${cond} order by r.created_at desc limit $${params.length - 1} offset $${params.length}`,
        params,
      )
    ).rows as Row[];
    return rows.map(present);
  });

  app.get('/patients/:id', workspaceGuard(pool, 'patients.read'), async (req) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const r = (await pool.query(`${SELECT} where r.id = $1 and r.workspace_id = $2`, [id, req.workspace!.workspaceId])).rows[0] as Row | undefined;
    if (!r) throw notFound('Patient not found');
    return present(r);
  });

  // F03-1/3/4/5: find-or-create the global identity by phone, then create this workspace's relationship.
  app.post('/patients', workspaceGuard(pool, 'patients.write'), async (req, reply) => {
    const body = z
      .object({ phone: phoneSchema, fullName: nameSchema, dateOfBirth: dobSchema.optional(), sex: sexSchema.optional(), confirmNotDuplicate: z.boolean().optional() })
      .parse(req.body);
    const ws = req.workspace!;

    if (!body.confirmNotDuplicate && body.dateOfBirth) {
      const dups = (
        await pool.query(
          `${SELECT} where r.workspace_id = $1 and r.status <> 'ended' and p.phone <> $2 and r.date_of_birth = $3 and ${NORM} = lower(regexp_replace(btrim($4), '\\s+', ' ', 'g'))`,
          [ws.workspaceId, body.phone, body.dateOfBirth, body.fullName],
        )
      ).rows as Row[];
      if (dups.length) {
        throw new AppError(409, 'possible_duplicate', 'A patient with the same name and date of birth already exists. Confirm this is a different person to continue.');
      }
    }

    const out = await tx(pool, async (c) => {
      const identity = (await c.query('insert into patients (phone) values ($1) on conflict (phone) do update set phone = excluded.phone returning id, user_id', [body.phone])).rows[0];
      // A patient who already has an app account must confirm the connection; otherwise the doctor's registration is active immediately.
      const status = identity.user_id ? 'invited' : 'active';
      const existing = (await c.query('select id, status from care_relationships where patient_id = $1 and workspace_id = $2 for update', [identity.id, ws.workspaceId])).rows[0];
      if (existing && existing.status !== 'ended') throw conflict('already_registered', 'This phone number is already registered in your clinic');

      let id: string;
      if (existing) {
        await c.query(
          `update care_relationships set full_name = $2, date_of_birth = $3, sex = $4, status = $5, ended_by = null, ended_at = null, updated_at = now() where id = $1`,
          [existing.id, body.fullName, body.dateOfBirth ?? null, body.sex ?? null, status],
        );
        id = existing.id;
      } else {
        const n = (await c.query('update workspaces set next_patient_number = next_patient_number + 1 where id = $1 returning next_patient_number - 1 as n', [ws.workspaceId])).rows[0].n;
        id = (
          await c.query(
            `insert into care_relationships (patient_id, workspace_id, patient_number, full_name, date_of_birth, sex, status, created_by)
             values ($1,$2,$3,$4,$5,$6,$7,$8) returning id`,
            [identity.id, ws.workspaceId, n, body.fullName, body.dateOfBirth ?? null, body.sex ?? null, status, req.auth!.userId],
          )
        ).rows[0].id;
      }
      await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: existing ? 'patient.re_registered' : 'patient.registered', targetType: 'patient', targetId: id, metadata: { status }, ip: req.ip });
      return id;
    });
    reply.code(201);
    return present((await pool.query(`${SELECT} where r.id = $1`, [out])).rows[0]);
  });

  app.patch('/patients/:id', workspaceGuard(pool, 'patients.write'), async (req) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const body = z
      .object({ fullName: nameSchema.optional(), dateOfBirth: dobSchema.nullable().optional(), sex: sexSchema.nullable().optional() })
      .refine((b) => Object.keys(b).length > 0, 'Nothing to update')
      .parse(req.body);
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      const cur = (await c.query('select * from care_relationships where id = $1 and workspace_id = $2 for update', [id, ws.workspaceId])).rows[0];
      if (!cur) throw notFound('Patient not found');
      if (cur.status === 'ended') throw conflict('relationship_ended', 'This patient relationship has ended');
      await c.query(
        `update care_relationships set full_name = $2, date_of_birth = $3, sex = $4, updated_at = now() where id = $1`,
        [
          id,
          body.fullName ?? cur.full_name,
          body.dateOfBirth === undefined ? cur.date_of_birth : body.dateOfBirth,
          body.sex === undefined ? cur.sex : body.sex,
        ],
      );
      // Field names only: the audit log should not become a second copy of patient data.
      await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: 'patient.updated', targetType: 'patient', targetId: id, metadata: { fields: Object.keys(body) }, ip: req.ip });
    });
    return present((await pool.query(`${SELECT} where r.id = $1`, [id])).rows[0]);
  });

  // F03-6: ending stops future access for the workspace; the registration record stays (retention).
  app.post('/patients/:id/end', workspaceGuard(pool, 'relationships.manage'), async (req) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      const r = await c.query(
        `update care_relationships set status = 'ended', ended_by = 'workspace', ended_at = now(), updated_at = now() where id = $1 and workspace_id = $2 and status <> 'ended'`,
        [id, ws.workspaceId],
      );
      if (r.rowCount === 0) throw notFound('Patient not found or already ended');
      await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: 'patient.relationship_ended', targetType: 'patient', targetId: id, metadata: { by: 'workspace' }, ip: req.ip });
    });
    return { ok: true };
  });

  // ---------- Patient side ----------
  const authed = { preHandler: authenticate(pool) };

  // F01-7: a verified phone (OTP) links to the identity doctors already created; no name-based merging.
  app.post('/patient/claim', authed, async (req) => {
    const userId = req.auth!.userId;
    await tx(pool, async (c) => {
      const phone = (await c.query('select phone from users where id = $1', [userId])).rows[0].phone;
      const res = await c.query(
        `insert into patients (phone, user_id, claimed_at) values ($1,$2, now())
         on conflict (phone) do update set user_id = coalesce(patients.user_id, excluded.user_id), claimed_at = coalesce(patients.claimed_at, excluded.claimed_at)
         returning id, user_id`,
        [phone, userId],
      );
      if (res.rows[0].user_id !== userId) throw conflict('identity_conflict', 'This phone number is linked to another account');
      await writeAudit(c, { actorId: userId, actorRole: 'patient', action: 'patient.identity_claimed', targetType: 'patient', targetId: res.rows[0].id, ip: req.ip });
    });
    return listOwn(userId);
  });

  const listOwn = async (userId: string) => {
    const rows = (
      await pool.query(
        `select r.id, r.status, r.created_at, r.ended_at, w.name as workspace_name, d.full_name as doctor_name
           from care_relationships r
           join patients p on p.id = r.patient_id
           join workspaces w on w.id = r.workspace_id
           join users d on d.id = w.owner_id
          where p.user_id = $1 order by r.created_at desc`,
        [userId],
      )
    ).rows;
    return rows.map((r) => ({ id: r.id, status: r.status, workspaceName: r.workspace_name, doctorName: r.doctor_name, createdAt: r.created_at, endedAt: r.ended_at }));
  };

  app.get('/patient/relationships', authed, async (req) => listOwn(req.auth!.userId));

  const PAST = { accept: 'accepted', decline: 'declined', end: 'ended' } as const;
  const transition = (action: 'accept' | 'decline' | 'end', from: 'invited' | 'active', to: 'active' | 'ended') =>
    app.post(`/patient/relationships/:id/${action}`, authed, async (req) => {
      const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
      const userId = req.auth!.userId;
      await tx(pool, async (c) => {
        const r = (
          await c.query(
            `select r.id, r.workspace_id, r.status from care_relationships r join patients p on p.id = r.patient_id where r.id = $1 and p.user_id = $2 for update of r`,
            [id, userId],
          )
        ).rows[0];
        if (!r) throw notFound('Relationship not found');
        if (r.status !== from) throw conflict('invalid_state', `Relationship is ${r.status}`);
        await c.query(
          `update care_relationships set status = $2, ended_by = case when $2 = 'ended' then 'patient' end, ended_at = case when $2 = 'ended' then now() end, updated_at = now() where id = $1`,
          [id, to],
        );
        await writeAudit(c, { workspaceId: r.workspace_id, actorId: userId, actorRole: 'patient', action: `patient.relationship_${PAST[action]}`, targetType: 'patient', targetId: id, ip: req.ip });
      });
      return { ok: true };
    });
  transition('accept', 'invited', 'active');
  transition('decline', 'invited', 'ended');
  transition('end', 'active', 'ended');
}
