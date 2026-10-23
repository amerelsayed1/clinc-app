import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import type { Permission } from '@clinic/shared';
import { writeAudit } from '../audit.js';
import { workspaceGuard } from '../auth.js';
import { tx } from '../db.js';
import { AppError, badRequest, conflict, notFound } from '../errors.js';
import { loadSettings, withinWorkingHours } from './settings.js';

const SELECT = `
  select a.id, a.care_relationship_id as patient_id, r.full_name, r.patient_number, p.phone,
         a.scheduled_at, a.duration_minutes, a.type, a.is_walk_in, a.reason, a.status,
         a.checked_in_at, a.started_at, a.completed_at, a.cancelled_at, a.cancel_reason, a.created_at
    from appointments a
    join care_relationships r on r.id = a.care_relationship_id
    join patients p on p.id = r.patient_id`;

interface Row {
  id: string;
  patient_id: string;
  full_name: string;
  patient_number: number;
  phone: string;
  scheduled_at: Date;
  duration_minutes: number;
  type: string;
  is_walk_in: boolean;
  reason: string | null;
  status: string;
  checked_in_at: Date | null;
  started_at: Date | null;
  completed_at: Date | null;
  cancelled_at: Date | null;
  cancel_reason: string | null;
  created_at: Date;
}
const present = (r: Row) => ({
  id: r.id,
  patient: { id: r.patient_id, fullName: r.full_name, patientNumber: r.patient_number, phone: r.phone },
  scheduledAt: r.scheduled_at,
  durationMinutes: r.duration_minutes,
  type: r.type,
  isWalkIn: r.is_walk_in,
  reason: r.reason,
  status: r.status,
  checkedInAt: r.checked_in_at,
  startedAt: r.started_at,
  completedAt: r.completed_at,
  cancelledAt: r.cancelled_at,
  cancelReason: r.cancel_reason,
  createdAt: r.created_at,
});

const idParam = z.object({ id: z.string().uuid() });
const reasonSchema = z.string().trim().max(200); // non-diagnostic visit reason
const timing = {
  scheduledAt: z.string().datetime({ offset: true }).optional(),
  // Wall-clock time in the clinic's own time zone, e.g. "2026-11-03T10:30".
  localStart: z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/).optional(),
  durationMinutes: z.number().int().min(5).max(480).optional(),
  override: z.boolean().optional(),
};

async function resolveStart(c: pg.PoolClient, timezone: string, b: { scheduledAt?: string; localStart?: string }): Promise<Date> {
  if (b.scheduledAt && b.localStart) throw badRequest('validation_error', 'Provide scheduledAt or localStart, not both');
  if (b.scheduledAt) return new Date(b.scheduledAt);
  if (b.localStart) {
    const r = await c.query('select ($1::timestamp at time zone $2) as t', [b.localStart, timezone]);
    return r.rows[0].t as Date;
  }
  throw badRequest('validation_error', 'scheduledAt or localStart is required');
}

/** Rejects with 409 (and details) unless `override` is set. Caller holds the workspace appointment lock. */
async function checkSlot(c: pg.PoolClient, workspaceId: string, start: Date, minutes: number, override: boolean | undefined, excludeId?: string) {
  const settings = await loadSettings(c, workspaceId);
  if (start.getTime() < Date.now() - 5 * 60_000) throw badRequest('in_the_past', 'Appointments cannot be scheduled in the past');
  if (override) return;
  if (!withinWorkingHours(settings, start, minutes)) {
    throw new AppError(409, 'outside_working_hours', 'This time is outside the clinic working hours', { override: true });
  }
  const end = new Date(start.getTime() + minutes * 60_000);
  const clash = (
    await c.query(
      `${SELECT}
        where a.workspace_id = $1 and a.status in ('scheduled', 'checked_in', 'in_consultation')
          and a.scheduled_at < $3 and a.scheduled_at + make_interval(mins => a.duration_minutes) > $2
          and ($4::uuid is null or a.id <> $4)
        order by a.scheduled_at`,
      [workspaceId, start, end, excludeId ?? null],
    )
  ).rows as Row[];
  if (clash.length) throw new AppError(409, 'slot_conflict', 'This time overlaps another appointment', { conflicts: clash.map(present) });
}

const lock = (c: pg.PoolClient, workspaceId: string) => c.query('select pg_advisory_xact_lock(hashtext($1))', [`appt:${workspaceId}`]);

export function appointmentRoutes(app: FastifyInstance, pool: pg.Pool) {
  // F04-5: one day in the clinic's time zone (default today), or one patient's history.
  app.get('/appointments', workspaceGuard(pool, 'appointments.read'), async (req) => {
    const q = z
      .object({
        date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
        patientId: z.string().uuid().optional(),
        status: z.enum(['scheduled', 'checked_in', 'in_consultation', 'completed', 'cancelled', 'no_show']).optional(),
      })
      .parse(req.query);
    const ws = req.workspace!.workspaceId;
    const params: unknown[] = [ws];
    let where = 'a.workspace_id = $1';
    let order = 'a.scheduled_at';
    if (q.patientId) {
      params.push(q.patientId);
      where += ` and a.care_relationship_id = $${params.length}`;
      order = 'a.scheduled_at desc';
    } else {
      params.push(q.date ?? null);
      where += ` and a.scheduled_at >= coalesce($${params.length}::date, (now() at time zone w.timezone)::date)::timestamp at time zone w.timezone
                 and a.scheduled_at < (coalesce($${params.length}::date, (now() at time zone w.timezone)::date) + 1)::timestamp at time zone w.timezone`;
    }
    if (q.status) {
      params.push(q.status);
      where += ` and a.status = $${params.length}`;
    }
    const rows = (await pool.query(`${SELECT} join workspaces w on w.id = a.workspace_id where ${where} order by ${order} limit 200`, params)).rows as Row[];
    return rows.map(present);
  });

  app.get('/appointments/:id', workspaceGuard(pool, 'appointments.read'), async (req) => {
    const { id } = idParam.parse(req.params);
    const r = (await pool.query(`${SELECT} where a.id = $1 and a.workspace_id = $2`, [id, req.workspace!.workspaceId])).rows[0] as Row | undefined;
    if (!r) throw notFound('Appointment not found');
    return present(r);
  });

  app.post('/appointments', workspaceGuard(pool, 'appointments.manage'), async (req, reply) => {
    const body = z
      .object({ patientId: z.string().uuid(), type: z.enum(['new', 'follow_up']).default('new'), reason: reasonSchema.optional(), ...timing })
      .parse(req.body);
    const ws = req.workspace!;
    const id = await tx(pool, async (c) => {
      await lock(c, ws.workspaceId);
      const settings = await loadSettings(c, ws.workspaceId);
      const rel = (await c.query('select status from care_relationships where id = $1 and workspace_id = $2', [body.patientId, ws.workspaceId])).rows[0];
      if (!rel) throw notFound('Patient not found');
      if (rel.status === 'ended') throw conflict('relationship_ended', 'This patient relationship has ended');
      const start = await resolveStart(c, settings.timezone, body);
      const minutes = body.durationMinutes ?? settings.slotMinutes;
      await checkSlot(c, ws.workspaceId, start, minutes, body.override);
      const a = (
        await c.query(
          `insert into appointments (workspace_id, care_relationship_id, scheduled_at, duration_minutes, type, reason, created_by) values ($1,$2,$3,$4,$5,$6,$7) returning id`,
          [ws.workspaceId, body.patientId, start, minutes, body.type, body.reason || null, req.auth!.userId],
        )
      ).rows[0];
      await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: 'appointment.created', targetType: 'appointment', targetId: a.id, metadata: { patientId: body.patientId, overridden: !!body.override }, ip: req.ip });
      return a.id as string;
    });
    reply.code(201);
    return present((await pool.query(`${SELECT} where a.id = $1`, [id])).rows[0]);
  });

  // Optional walk-in queue mode: joins the waiting list immediately, no slot check.
  app.post('/appointments/walk-in', workspaceGuard(pool, 'appointments.manage'), async (req, reply) => {
    const body = z.object({ patientId: z.string().uuid(), type: z.enum(['new', 'follow_up']).default('new'), reason: reasonSchema.optional() }).parse(req.body);
    const ws = req.workspace!;
    const id = await tx(pool, async (c) => {
      const rel = (await c.query('select status from care_relationships where id = $1 and workspace_id = $2', [body.patientId, ws.workspaceId])).rows[0];
      if (!rel) throw notFound('Patient not found');
      if (rel.status === 'ended') throw conflict('relationship_ended', 'This patient relationship has ended');
      const settings = await loadSettings(c, ws.workspaceId);
      const a = (
        await c.query(
          `insert into appointments (workspace_id, care_relationship_id, scheduled_at, duration_minutes, type, reason, is_walk_in, status, checked_in_at, created_by)
           values ($1,$2, now(), $3, $4, $5, true, 'checked_in', now(), $6) returning id`,
          [ws.workspaceId, body.patientId, settings.slotMinutes, body.type, body.reason || null, req.auth!.userId],
        )
      ).rows[0];
      await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: 'appointment.walk_in', targetType: 'appointment', targetId: a.id, metadata: { patientId: body.patientId }, ip: req.ip });
      return a.id as string;
    });
    reply.code(201);
    return present((await pool.query(`${SELECT} where a.id = $1`, [id])).rows[0]);
  });

  // Reschedule / edit: only while still `scheduled`.
  app.patch('/appointments/:id', workspaceGuard(pool, 'appointments.manage'), async (req) => {
    const { id } = idParam.parse(req.params);
    const body = z
      .object({ type: z.enum(['new', 'follow_up']).optional(), reason: reasonSchema.nullable().optional(), ...timing })
      .refine((b) => b.scheduledAt || b.localStart || b.durationMinutes || b.type || b.reason !== undefined, 'Nothing to update')
      .parse(req.body);
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      await lock(c, ws.workspaceId);
      const cur = (await c.query('select * from appointments where id = $1 and workspace_id = $2 for update', [id, ws.workspaceId])).rows[0];
      if (!cur) throw notFound('Appointment not found');
      if (cur.status !== 'scheduled') throw conflict('invalid_state', `Only scheduled appointments can be changed (this one is ${cur.status})`);
      const settings = await loadSettings(c, ws.workspaceId);
      const timeChanged = !!(body.scheduledAt || body.localStart || body.durationMinutes);
      const start = body.scheduledAt || body.localStart ? await resolveStart(c, settings.timezone, body) : cur.scheduled_at;
      const minutes = body.durationMinutes ?? cur.duration_minutes;
      if (timeChanged) await checkSlot(c, ws.workspaceId, start, minutes, body.override, id);
      await c.query(
        `update appointments set scheduled_at = $2, duration_minutes = $3, type = $4, reason = $5, updated_at = now() where id = $1`,
        [id, start, minutes, body.type ?? cur.type, body.reason === undefined ? cur.reason : body.reason || null],
      );
      await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: timeChanged ? 'appointment.rescheduled' : 'appointment.updated', targetType: 'appointment', targetId: id, metadata: { overridden: !!body.override }, ip: req.ip });
    });
    return present((await pool.query(`${SELECT} where a.id = $1`, [id])).rows[0]);
  });

  // F04-3: status machine. Starting/finishing a consultation is a clinical action; the rest is front-desk work.
  const transitions: {
    path: string;
    from: string[];
    to: string;
    perm: Permission;
    column?: string;
    guard?: string;
  }[] = [
    { path: 'check-in', from: ['scheduled'], to: 'checked_in', perm: 'appointments.manage', column: 'checked_in_at' },
    { path: 'start', from: ['checked_in'], to: 'in_consultation', perm: 'clinical.write', column: 'started_at' },
    { path: 'complete', from: ['in_consultation'], to: 'completed', perm: 'clinical.write', column: 'completed_at' },
    { path: 'cancel', from: ['scheduled', 'checked_in'], to: 'cancelled', perm: 'appointments.manage', column: 'cancelled_at' },
    { path: 'no-show', from: ['scheduled'], to: 'no_show', perm: 'appointments.manage', guard: 'scheduled_at <= now()' },
  ];
  for (const t of transitions) {
    app.post(`/appointments/:id/${t.path}`, workspaceGuard(pool, t.perm), async (req) => {
      const { id } = idParam.parse(req.params);
      const body = t.path === 'cancel' ? z.object({ reason: reasonSchema.optional() }).parse(req.body ?? {}) : {};
      const ws = req.workspace!;
      await tx(pool, async (c) => {
        const cur = (await c.query('select status, scheduled_at from appointments where id = $1 and workspace_id = $2 for update', [id, ws.workspaceId])).rows[0];
        if (!cur) throw notFound('Appointment not found');
        if (!t.from.includes(cur.status)) throw conflict('invalid_state', `Cannot ${t.path} an appointment that is ${cur.status}`);
        if (t.guard && cur.scheduled_at.getTime() > Date.now()) throw conflict('too_early', 'Cannot mark no-show before the appointment time');
        await c.query(
          `update appointments set status = $2, ${t.column ? `${t.column} = now(),` : ''} cancel_reason = coalesce($3, cancel_reason), updated_at = now() where id = $1`,
          [id, t.to, 'reason' in body ? body.reason || null : null],
        );
        await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: `appointment.${t.to}`, targetType: 'appointment', targetId: id, metadata: { from: cur.status }, ip: req.ip });
      });
      return present((await pool.query(`${SELECT} where a.id = $1`, [id])).rows[0]);
    });
  }
}
