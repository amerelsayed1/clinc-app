import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { VITAL_KEYS, VITAL_KINDS } from '@clinic/shared';
import { writeAudit } from '../audit.js';
import { authenticate, workspaceGuard } from '../auth.js';
import { tx, type Db } from '../db.js';
import { conflict, forbidden, notFound, badRequest } from '../errors.js';

/** Wording shown to the doctor next to an out-of-range patient-reported value. No clinical conclusion is drawn (spec 09). */
export const OUTSIDE_RANGE_LABEL = 'patient-reported, outside expected range';
const DAY_MS = 86_400_000;
/** A measurement counts as overdue (doctor "needs attention") once it is a full day past its due time. */
const OVERDUE_GRACE_MS = DAY_MS;
const idParam = z.object({ id: z.string().uuid() });
const dateStr = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD')
  .refine((d) => !Number.isNaN(Date.parse(d)) && d >= '1900-01-01' && d <= '2200-01-01', 'Invalid date');

// ---------- validation ----------
const measurementIn = z
  .object({
    id: z.string().uuid().optional(),
    kind: z.enum(VITAL_KEYS).optional(),
    name: z.string().trim().min(1).max(80).optional(),
    unit: z.string().trim().max(20).optional(),
    frequency: z.enum(['daily', 'weekly', 'custom']),
    intervalDays: z.number().int().min(1).max(90).optional(),
    normalMin: z.number().finite().nullable().optional(),
    normalMax: z.number().finite().nullable().optional(),
  })
  .superRefine((m, ctx) => {
    if (!m.kind && !m.name) ctx.addIssue({ code: 'custom', message: 'Give a known kind or a custom name', path: ['name'] });
    if (m.frequency === 'custom' && !m.intervalDays) ctx.addIssue({ code: 'custom', message: 'A custom frequency needs intervalDays', path: ['intervalDays'] });
    if (m.normalMin != null && m.normalMax != null && m.normalMin > m.normalMax) ctx.addIssue({ code: 'custom', message: 'normalMin must not exceed normalMax', path: ['normalMin'] });
  });
type MeasurementIn = z.infer<typeof measurementIn>;

const createBody = z.object({
  nextVisitDate: dateStr.nullable().optional(),
  instructions: z.string().trim().max(2000).default(''),
  startDate: dateStr.optional(),
  endDate: dateStr.nullable().optional(),
  measurements: z.array(measurementIn).max(10).default([]),
});
const editBody = z
  .object({
    version: z.number().int().optional(),
    nextVisitDate: dateStr.nullable().optional(),
    instructions: z.string().trim().max(2000).optional(),
    endDate: dateStr.nullable().optional(),
    measurements: z.array(measurementIn).max(10).optional(),
  })
  .refine((b) => b.nextVisitDate !== undefined || b.instructions !== undefined || b.endDate !== undefined || b.measurements !== undefined, 'Nothing to update');

const resolve = (m: MeasurementIn) => ({
  kind: m.kind ?? null,
  name: m.name ?? VITAL_KINDS[m.kind!].label,
  unit: m.unit ?? (m.kind ? VITAL_KINDS[m.kind].unit : ''),
  frequency: m.frequency,
  intervalDays: m.frequency === 'daily' ? 1 : m.frequency === 'weekly' ? 7 : m.intervalDays!,
  normalMin: m.normalMin ?? null,
  normalMax: m.normalMax ?? null,
});

// ---------- due / overdue computation ----------
interface StateRow {
  measurement_id: string;
  plan_id: string;
  care_relationship_id: string;
  workspace_id: string;
  name: string;
  unit: string;
  frequency: string;
  interval_days: number;
  plan_status: string;
  start_at: Date;
  end_at: Date | null;
  last_at: Date | null;
  full_name: string;
  patient_user_id: string | null;
}

/**
 * Loads one row per active measurement with the instants needed to decide what is due.
 * Plan start/end dates are interpreted in the clinic's timezone; the end date is inclusive.
 */
async function measurementStates(db: Db, where: string, params: unknown[]): Promise<StateRow[]> {
  return (
    await db.query(
      `select m.id as measurement_id, m.name, m.unit, m.frequency, m.interval_days,
              p.id as plan_id, p.status as plan_status, p.care_relationship_id, p.workspace_id,
              (p.start_date::timestamp at time zone w.timezone) as start_at,
              ((p.end_date + 1)::timestamp at time zone w.timezone) as end_at,
              (select max(s.created_at) from followup_submissions s where s.measurement_id = m.id) as last_at,
              r.full_name, pt.user_id as patient_user_id
         from followup_measurements m
         join followup_plans p on p.id = m.plan_id
         join workspaces w on w.id = p.workspace_id
         join care_relationships r on r.id = p.care_relationship_id
         join patients pt on pt.id = r.patient_id
        where m.active and ${where}`,
      params,
    )
  ).rows as StateRow[];
}

export function dueState(r: Pick<StateRow, 'plan_status' | 'start_at' | 'end_at' | 'last_at' | 'interval_days'>, now: Date) {
  const dueAt = r.last_at ? new Date(r.last_at.getTime() + r.interval_days * DAY_MS) : r.start_at;
  const running = r.plan_status === 'active' && now >= r.start_at && (!r.end_at || now < r.end_at);
  return { dueAt, isDue: running && now >= dueAt, overdue: running && now.getTime() >= dueAt.getTime() + OVERDUE_GRACE_MS };
}

const ACTIVE_PLAN = `p.status = 'active' and r.status = 'active'`;

/**
 * Seam for the notification service (spec 10): everything a patient is due to report at `now`.
 * Stateless and idempotent: the caller decides what has already been reminded. Contains no clinical content.
 */
export async function dueReminders(
  pool: Db,
  now: Date = new Date(),
): Promise<{ patientUserId: string; planId: string; measurementName: string; dueAt: Date }[]> {
  const rows = await measurementStates(pool, `${ACTIVE_PLAN} and pt.user_id is not null`, []);
  return rows
    .map((r) => ({ r, s: dueState(r, now) }))
    .filter((x) => x.s.isDue)
    .map((x) => ({ patientUserId: x.r.patient_user_id!, planId: x.r.plan_id, measurementName: x.r.name, dueAt: x.s.dueAt }));
}

// ---------- presentation ----------
const num = (v: unknown) => (v == null ? null : Number(v));
const outside = (value: number, min: number | null, max: number | null) => (min != null && value < min) || (max != null && value > max);

interface MRow {
  id: string;
  plan_id: string;
  kind: string | null;
  name: string;
  unit: string;
  frequency: string;
  interval_days: number;
  normal_min: string | null;
  normal_max: string | null;
  active: boolean;
}
const presentMeasurement = (m: MRow, clinic: boolean) => ({
  id: m.id,
  kind: m.kind,
  name: m.name,
  unit: m.unit,
  frequency: m.frequency,
  intervalDays: m.interval_days,
  active: m.active,
  // The expected range is a clinic-side tool; the patient app never receives it (and so cannot display a verdict).
  ...(clinic && { normalMin: num(m.normal_min), normalMax: num(m.normal_max) }),
});

const PLAN_SELECT = `
  select p.id, p.workspace_id, p.care_relationship_id, p.status, p.current_version, p.instructions, p.close_reason,
         to_char(p.next_visit_date, 'YYYY-MM-DD') as next_visit_date, to_char(p.start_date, 'YYYY-MM-DD') as start_date,
         to_char(p.end_date, 'YYYY-MM-DD') as end_date, p.closed_at, p.created_at, p.updated_at,
         r.full_name as patient_name, r.patient_number, w.name as clinic_name, du.full_name as doctor_name
    from followup_plans p
    join care_relationships r on r.id = p.care_relationship_id
    join workspaces w on w.id = p.workspace_id
    join users du on du.id = w.owner_id`;

type PRow = Record<string, unknown> & { id: string; status: string; start_date: string; end_date: string | null };
const presentPlan = (p: PRow) => ({
  id: p.id,
  careRelationshipId: p.care_relationship_id,
  patientName: p.patient_name,
  status: p.status,
  currentVersion: p.current_version,
  nextVisitDate: p.next_visit_date,
  instructions: p.instructions,
  startDate: p.start_date,
  endDate: p.end_date,
  closedAt: p.closed_at,
  closeReason: p.close_reason,
  createdAt: p.created_at,
  updatedAt: p.updated_at,
});

async function measurementsOf(db: Db, planIds: string[], includeInactive: boolean) {
  const rows = (
    await db.query(`select * from followup_measurements where plan_id = any($1) ${includeInactive ? '' : 'and active'} order by position`, [planIds])
  ).rows as MRow[];
  return rows;
}

const SUB_SELECT = `select s.id, s.plan_id, s.measurement_id, s.value, s.measured_at, s.note, s.document_id, s.source, s.created_at,
         m.normal_min, m.normal_max, m.name as measurement_name, m.unit
    from followup_submissions s join followup_measurements m on m.id = s.measurement_id`;

interface SRow {
  id: string;
  plan_id: string;
  measurement_id: string;
  value: string;
  measured_at: Date;
  note: string;
  document_id: string | null;
  source: string;
  created_at: Date;
  normal_min: string | null;
  normal_max: string | null;
  measurement_name: string;
  unit: string;
}
/** `clinic` rows carry the range flag; patient rows never do. Every row says it is patient-reported and unverified. */
const presentSubmission = (s: SRow, clinic: boolean) => {
  const value = Number(s.value);
  const flagged = clinic && outside(value, num(s.normal_min), num(s.normal_max));
  return {
    id: s.id,
    planId: s.plan_id,
    measurementId: s.measurement_id,
    measurementName: s.measurement_name,
    unit: s.unit,
    value,
    measuredAt: s.measured_at,
    note: s.note,
    documentId: s.document_id,
    source: s.source,
    verified: false,
    submittedAt: s.created_at,
    ...(clinic && { outsideExpectedRange: flagged, flagLabel: flagged ? OUTSIDE_RANGE_LABEL : null }),
  };
};

export function followupRoutes(app: FastifyInstance, pool: pg.Pool) {
  const ctxAudit = (req: import('fastify').FastifyRequest) => ({ workspaceId: req.workspace!.workspaceId, actorId: req.auth!.userId, actorRole: req.workspace!.role, ip: req.ip });

  async function snapshot(c: Db, planId: string) {
    const p = (await c.query(`${PLAN_SELECT} where p.id = $1`, [planId])).rows[0] as PRow;
    const ms = await measurementsOf(c, [planId], true);
    return { plan: { ...presentPlan(p), patientName: undefined }, measurements: ms.map((m) => presentMeasurement(m, true)) };
  }

  async function ownedPlan(c: Db, id: string, workspaceId: string, lock = false) {
    const p = (await c.query(`select *, to_char(start_date, 'YYYY-MM-DD') as start_str from followup_plans where id = $1 and workspace_id = $2 ${lock ? 'for update' : ''}`, [id, workspaceId])).rows[0];
    if (!p) throw notFound('Follow-up plan not found');
    return p;
  }

  async function detail(id: string, workspaceId: string) {
    const p = (await pool.query(`${PLAN_SELECT} where p.id = $1 and p.workspace_id = $2`, [id, workspaceId])).rows[0] as PRow | undefined;
    if (!p) throw notFound('Follow-up plan not found');
    const ms = await measurementsOf(pool, [id], true);
    const now = new Date();
    const states = new Map((await measurementStates(pool, 'p.id = $1', [id])).map((s) => [s.measurement_id, dueState(s, now)]));
    const lastBy = new Map(
      (await pool.query('select measurement_id, max(created_at) as last_at from followup_submissions where plan_id = $1 group by 1', [id])).rows.map((r) => [r.measurement_id, r.last_at]),
    );
    const subs = (await pool.query(`${SUB_SELECT} where s.plan_id = $1 order by s.measured_at desc, s.created_at desc limit 500`, [id])).rows as SRow[];
    return {
      ...presentPlan(p),
      measurements: ms.map((m) => {
        const st = states.get(m.id);
        return { ...presentMeasurement(m, true), lastSubmittedAt: lastBy.get(m.id) ?? null, dueAt: st?.dueAt ?? null, overdue: st?.overdue ?? false };
      }),
      submissions: subs.map((s) => presentSubmission(s, true)),
    };
  }

  // ---------- clinic side ----------
  app.post('/patients/:id/followups', workspaceGuard(pool, 'clinical.write'), async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = createBody.parse(req.body);
    const ws = req.workspace!;
    const planId = await tx(pool, async (c) => {
      const rel = (
        await c.query(
          `select r.status, (now() at time zone w.timezone)::date::text as today from care_relationships r join workspaces w on w.id = r.workspace_id where r.id = $1 and r.workspace_id = $2`,
          [id, ws.workspaceId],
        )
      ).rows[0];
      if (!rel) throw notFound('Patient not found');
      if (rel.status === 'ended') throw conflict('relationship_ended', 'This patient relationship has ended');
      const start = body.startDate ?? rel.today;
      if (body.endDate && body.endDate < start) throw badRequest('invalid_dates', 'The end date cannot be before the start date');
      const plan = (
        await c.query(
          `insert into followup_plans (workspace_id, care_relationship_id, created_by, next_visit_date, instructions, start_date, end_date) values ($1,$2,$3,$4,$5,$6,$7) returning id`,
          [ws.workspaceId, id, req.auth!.userId, body.nextVisitDate ?? null, body.instructions, start, body.endDate ?? null],
        )
      ).rows[0];
      for (const m of body.measurements.map(resolve)) {
        await c.query(
          `insert into followup_measurements (plan_id, kind, name, unit, frequency, interval_days, normal_min, normal_max) values ($1,$2,$3,$4,$5,$6,$7,$8)`,
          [plan.id, m.kind, m.name, m.unit, m.frequency, m.intervalDays, m.normalMin, m.normalMax],
        );
      }
      await c.query(`insert into followup_plan_versions (plan_id, version, edited_by, change, snapshot) values ($1,1,$2,'created',$3)`, [plan.id, req.auth!.userId, JSON.stringify(await snapshot(c, plan.id))]);
      await writeAudit(c, { ...ctxAudit(req), action: 'followup.plan_created', targetType: 'followup_plan', targetId: plan.id, metadata: { patientId: id, measurements: body.measurements.length } });
      return plan.id as string;
    });
    reply.code(201);
    return detail(planId, ws.workspaceId);
  });

  app.get('/patients/:id/followups', workspaceGuard(pool, 'clinical.read'), async (req) => {
    const { id } = idParam.parse(req.params);
    const ws = req.workspace!;
    const rel = await pool.query('select 1 from care_relationships where id = $1 and workspace_id = $2', [id, ws.workspaceId]);
    if (!rel.rowCount) throw notFound('Patient not found');
    const plans = (await pool.query(`${PLAN_SELECT} where p.care_relationship_id = $1 and p.workspace_id = $2 order by p.created_at desc`, [id, ws.workspaceId])).rows as PRow[];
    const ms = await measurementsOf(pool, plans.map((p) => p.id), false);
    return plans.map((p) => ({ ...presentPlan(p), measurements: ms.filter((m) => m.plan_id === p.id).map((m) => presentMeasurement(m, true)) }));
  });

  // F09-4: patients with overdue / missed submissions. Registered before /followups/:id so the static path wins.
  app.get('/followups/attention', workspaceGuard(pool, 'clinical.read'), async (req) => {
    const ws = req.workspace!;
    const now = new Date();
    const rows = await measurementStates(pool, `${ACTIVE_PLAN} and p.workspace_id = $1`, [ws.workspaceId]);
    const byPatient = new Map<string, { careRelationshipId: string; patientName: string; items: Record<string, unknown>[]; oldest: number }>();
    for (const r of rows) {
      const s = dueState(r, now);
      if (!s.overdue) continue;
      const e = byPatient.get(r.care_relationship_id) ?? { careRelationshipId: r.care_relationship_id, patientName: r.full_name, items: [], oldest: Infinity };
      e.items.push({
        planId: r.plan_id,
        measurementId: r.measurement_id,
        measurementName: r.name,
        dueAt: s.dueAt,
        daysOverdue: Math.floor((now.getTime() - s.dueAt.getTime()) / DAY_MS),
        lastSubmittedAt: r.last_at,
      });
      e.oldest = Math.min(e.oldest, s.dueAt.getTime());
      byPatient.set(r.care_relationship_id, e);
    }
    return [...byPatient.values()].sort((a, b) => a.oldest - b.oldest).map(({ oldest: _o, ...rest }) => rest);
  });

  app.get('/followups/:id', workspaceGuard(pool, 'clinical.read'), async (req) => {
    const { id } = idParam.parse(req.params);
    return detail(id, req.workspace!.workspaceId);
  });

  // F09-5: every edit appends an immutable version snapshot.
  app.patch('/followups/:id', workspaceGuard(pool, 'clinical.write'), async (req) => {
    const { id } = idParam.parse(req.params);
    const body = editBody.parse(req.body);
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      const cur = await ownedPlan(c, id, ws.workspaceId, true);
      if (cur.status === 'closed') throw conflict('plan_closed', 'This plan is closed');
      if (body.version !== undefined && body.version !== cur.current_version) throw conflict('version_conflict', 'The plan was changed by someone else. Reload and try again.');
      const startDate = cur.start_str as string;
      const end = body.endDate === undefined ? undefined : body.endDate;
      if (end && end < startDate) throw badRequest('invalid_dates', 'The end date cannot be before the start date');
      await c.query(
        `update followup_plans set next_visit_date = case when $2 then $3::date else next_visit_date end,
                instructions = coalesce($4, instructions),
                end_date = case when $5 then $6::date else end_date end,
                current_version = current_version + 1, updated_at = now() where id = $1`,
        [id, body.nextVisitDate !== undefined, body.nextVisitDate ?? null, body.instructions ?? null, end !== undefined, end ?? null],
      );
      if (body.measurements) {
        const existing = (await c.query('select id from followup_measurements where plan_id = $1', [id])).rows.map((r) => r.id as string);
        const keep = new Set<string>();
        for (const mi of body.measurements) {
          const m = resolve(mi);
          if (mi.id) {
            if (!existing.includes(mi.id)) throw notFound('Measurement not found in this plan');
            keep.add(mi.id);
            await c.query(
              `update followup_measurements set kind=$2, name=$3, unit=$4, frequency=$5, interval_days=$6, normal_min=$7, normal_max=$8, active=true where id=$1`,
              [mi.id, m.kind, m.name, m.unit, m.frequency, m.intervalDays, m.normalMin, m.normalMax],
            );
          } else {
            await c.query(
              `insert into followup_measurements (plan_id, kind, name, unit, frequency, interval_days, normal_min, normal_max) values ($1,$2,$3,$4,$5,$6,$7,$8)`,
              [id, m.kind, m.name, m.unit, m.frequency, m.intervalDays, m.normalMin, m.normalMax],
            );
          }
        }
        // Dropped measurements are retired, not deleted: their submissions stay in the record.
        await c.query('update followup_measurements set active = false where plan_id = $1 and not (id = any($2))', [id, [...keep]]);
      }
      const version = cur.current_version + 1;
      await c.query(`insert into followup_plan_versions (plan_id, version, edited_by, change, snapshot) values ($1,$2,$3,'edited',$4)`, [id, version, req.auth!.userId, JSON.stringify(await snapshot(c, id))]);
      await writeAudit(c, { ...ctxAudit(req), action: 'followup.plan_edited', targetType: 'followup_plan', targetId: id, metadata: { version, fields: Object.keys(body).filter((k) => k !== 'version') } });
    });
    return detail(id, ws.workspaceId);
  });

  app.post('/followups/:id/close', workspaceGuard(pool, 'clinical.write'), async (req) => {
    const { id } = idParam.parse(req.params);
    const { reason } = z.object({ reason: z.string().trim().max(300).default('') }).parse(req.body ?? {});
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      const cur = await ownedPlan(c, id, ws.workspaceId, true);
      if (cur.status === 'closed') throw conflict('plan_closed', 'This plan is already closed');
      const version = cur.current_version + 1;
      await c.query(`update followup_plans set status = 'closed', closed_at = now(), closed_by = $2, close_reason = $3, current_version = $4, updated_at = now() where id = $1`, [id, req.auth!.userId, reason, version]);
      await c.query(`insert into followup_plan_versions (plan_id, version, edited_by, change, snapshot) values ($1,$2,$3,'closed',$4)`, [id, version, req.auth!.userId, JSON.stringify(await snapshot(c, id))]);
      await writeAudit(c, { ...ctxAudit(req), action: 'followup.plan_closed', targetType: 'followup_plan', targetId: id, metadata: { version } });
    });
    return detail(id, ws.workspaceId);
  });

  app.get('/followups/:id/history', workspaceGuard(pool, 'clinical.read'), async (req) => {
    const { id } = idParam.parse(req.params);
    await ownedPlan(pool, id, req.workspace!.workspaceId);
    const rows = (
      await pool.query(
        `select v.version, v.change, v.snapshot, v.created_at, u.full_name as edited_by_name from followup_plan_versions v join users u on u.id = v.edited_by where v.plan_id = $1 order by v.version desc`,
        [id],
      )
    ).rows;
    return rows.map((r) => ({ version: r.version, change: r.change, editedBy: r.edited_by_name, at: r.created_at, snapshot: r.snapshot }));
  });

  // Chart data for one measurement. Patient-reported points only; nothing from clinician observations is mixed in.
  app.get('/followups/:id/measurements/:mid/trend', workspaceGuard(pool, 'clinical.read'), async (req) => {
    const { id, mid } = z.object({ id: z.string().uuid(), mid: z.string().uuid() }).parse(req.params);
    await ownedPlan(pool, id, req.workspace!.workspaceId);
    const m = (await pool.query('select * from followup_measurements where id = $1 and plan_id = $2', [mid, id])).rows[0] as MRow | undefined;
    if (!m) throw notFound('Measurement not found');
    const rows = (
      await pool.query(`${SUB_SELECT} where s.measurement_id = $1 order by s.measured_at desc, s.created_at desc limit 200`, [mid])
    ).rows as SRow[];
    return {
      measurement: presentMeasurement(m, true),
      source: 'patient',
      verified: false,
      points: rows.reverse().map((s) => {
        const p = presentSubmission(s, true);
        return { id: p.id, measuredAt: p.measuredAt, value: p.value, outsideExpectedRange: p.outsideExpectedRange, flagLabel: p.flagLabel };
      }),
    };
  });

  // ---------- patient side ----------
  const authed = { preHandler: authenticate(pool) };
  const myPatient = async (userId: string): Promise<string> => {
    const p = (await pool.query('select id from patients where user_id = $1', [userId])).rows[0];
    if (!p) throw forbidden('Claim your patient profile first');
    return p.id;
  };

  /** A patient only ever sees plans of their own active relationships. */
  const MINE = `r.status = 'active' and r.patient_id = $1`;

  app.get('/patient/followups', authed, async (req) => {
    const patientId = await myPatient(req.auth!.userId);
    const plans = (await pool.query(`${PLAN_SELECT} where ${MINE} order by p.status, p.created_at desc`, [patientId])).rows as PRow[];
    const ms = await measurementsOf(pool, plans.map((p) => p.id), false);
    const states = new Map(
      (await measurementStates(pool, `r.patient_id = $1 and r.status = 'active'`, [patientId])).map((s) => [s.measurement_id, s]),
    );
    const now = new Date();
    return plans.map((p) => ({
      id: p.id,
      clinicName: p.clinic_name,
      doctorName: p.doctor_name,
      status: p.status,
      nextVisitDate: p.next_visit_date,
      instructions: p.instructions,
      startDate: p.start_date,
      endDate: p.end_date,
      measurements: ms
        .filter((m) => m.plan_id === p.id)
        .map((m) => {
          const st = states.get(m.id);
          const d = st ? dueState(st, now) : null;
          return { ...presentMeasurement(m, false), lastSubmittedAt: st?.last_at ?? null, dueAt: d?.dueAt ?? null, isDue: d?.isDue ?? false };
        }),
    }));
  });

  // What the patient should report right now (also the basis for reminders via dueReminders).
  app.get('/patient/followups/due', authed, async (req) => {
    const patientId = await myPatient(req.auth!.userId);
    const rows = await measurementStates(pool, `${ACTIVE_PLAN} and r.patient_id = $1`, [patientId]);
    const now = new Date();
    return rows
      .map((r) => ({ r, s: dueState(r, now) }))
      .filter((x) => x.s.isDue)
      .map((x) => ({ planId: x.r.plan_id, measurementId: x.r.measurement_id, measurementName: x.r.name, unit: x.r.unit, dueAt: x.s.dueAt }));
  });

  const submitBody = z.object({
    measurementId: z.string().uuid(),
    value: z.number().finite().min(-1e9).max(1e9),
    measuredAt: z.string().datetime({ offset: true }),
    note: z.string().trim().max(500).default(''),
    documentId: z.string().uuid().optional(),
  });

  app.post('/patient/followups/:id/submissions', authed, async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = submitBody.parse(req.body);
    const userId = req.auth!.userId;
    const patientId = await myPatient(userId);
    const measuredAt = new Date(body.measuredAt);
    const now = new Date();
    if (measuredAt.getTime() > now.getTime() + 5 * 60_000) throw badRequest('invalid_time', 'The measurement time cannot be in the future');
    if (measuredAt.getTime() < now.getTime() - 90 * DAY_MS) throw badRequest('invalid_time', 'The measurement time is too far in the past');

    const out = await tx(pool, async (c) => {
      const p = (
        await c.query(
          `select p.id, p.status, p.workspace_id, p.care_relationship_id,
                  (p.start_date::timestamp at time zone w.timezone) as start_at, ((p.end_date + 1)::timestamp at time zone w.timezone) as end_at
             from followup_plans p join care_relationships r on r.id = p.care_relationship_id join workspaces w on w.id = p.workspace_id
            where p.id = $1 and ${MINE.replace('$1', '$2')} for update of p`,
          [id, patientId],
        )
      ).rows[0];
      if (!p) throw notFound('Follow-up plan not found');
      // Acceptance (spec 09): nothing is accepted after the plan ended or was closed.
      if (p.status === 'closed') throw conflict('plan_closed', 'This follow-up plan is closed');
      if (p.end_at && now >= p.end_at) throw conflict('plan_ended', 'This follow-up plan has ended');
      if (now < p.start_at) throw conflict('plan_not_started', 'This follow-up plan has not started yet');
      const m = (await c.query('select * from followup_measurements where id = $1 and plan_id = $2 and active', [body.measurementId, id])).rows[0] as MRow | undefined;
      if (!m) throw notFound('Measurement not found in this plan');
      // Plausibility bounds only catch typing mistakes; they are not clinical ranges.
      const vital = m.kind ? VITAL_KINDS[m.kind as keyof typeof VITAL_KINDS] : undefined;
      if (vital && (body.value < vital.min || body.value > vital.max)) throw badRequest('implausible_value', `${vital.label} must be between ${vital.min} and ${vital.max} ${vital.unit}`);

      if (body.documentId) {
        const d = await c.query(`select 1 from documents where id = $1 and patient_id = $2 and source = 'patient' and status = 'available'`, [body.documentId, patientId]);
        if (!d.rowCount) throw notFound('Attachment not found');
      }
      const s = (
        await c.query(
          `insert into followup_submissions (plan_id, measurement_id, workspace_id, care_relationship_id, patient_id, value, measured_at, note, document_id, created_by)
           values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) returning id`,
          [id, m.id, p.workspace_id, p.care_relationship_id, patientId, body.value, measuredAt, body.note, body.documentId ?? null, userId],
        )
      ).rows[0];
      if (body.documentId) {
        // Attaching a file sends it to this clinic (revocable by the patient like any other share).
        await c.query(
          `insert into document_shares (document_id, care_relationship_id, shared_by) values ($1,$2,$3)
           on conflict (document_id, care_relationship_id) do update set revoked_at = null, shared_by = excluded.shared_by`,
          [body.documentId, p.care_relationship_id, userId],
        );
        await writeAudit(c, { workspaceId: p.workspace_id, actorId: userId, actorRole: 'patient', action: 'document.shared_with_clinic', targetType: 'document', targetId: body.documentId, ip: req.ip });
      }
      // Audit carries ids only: the value is health data and stays in the record.
      await writeAudit(c, { workspaceId: p.workspace_id, actorId: userId, actorRole: 'patient', action: 'followup.submission_created', targetType: 'followup_plan', targetId: id, metadata: { submissionId: s.id, measurementId: m.id, attachment: !!body.documentId }, ip: req.ip });
      return s.id as string;
    });
    reply.code(201);
    const row = (await pool.query(`${SUB_SELECT} where s.id = $1`, [out])).rows[0] as SRow;
    return presentSubmission(row, false);
  });

  // The patient's own history: no range flag, no verdict.
  app.get('/patient/followups/:id/submissions', authed, async (req) => {
    const { id } = idParam.parse(req.params);
    const patientId = await myPatient(req.auth!.userId);
    const ok = await pool.query(`select 1 from followup_plans p join care_relationships r on r.id = p.care_relationship_id where p.id = $2 and ${MINE}`, [patientId, id]);
    if (!ok.rowCount) throw notFound('Follow-up plan not found');
    const rows = (await pool.query(`${SUB_SELECT} where s.plan_id = $1 and s.patient_id = $2 order by s.measured_at desc, s.created_at desc limit 500`, [id, patientId])).rows as SRow[];
    return rows.map((s) => presentSubmission(s, false));
  });
}
