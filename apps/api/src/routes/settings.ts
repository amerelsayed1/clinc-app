import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { writeAudit } from '../audit.js';
import { workspaceGuard } from '../auth.js';
import { tx } from '../db.js';

export const DAYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'] as const;
export type Day = (typeof DAYS)[number];
export type WorkingHours = Record<Day, { start: string; end: string }[]>;

const hhmm = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'Use HH:MM');
const range = z.object({ start: hhmm, end: hhmm }).refine((r) => r.start < r.end, 'Range start must be before end');
const workingHoursSchema = z.object(Object.fromEntries(DAYS.map((d) => [d, z.array(range).max(3).default([])])) as Record<Day, z.ZodDefault<z.ZodArray<typeof range>>>);

const tzSchema = z.string().refine((tz) => {
  try {
    new Intl.DateTimeFormat('en', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}, 'Unknown time zone');

export interface WorkspaceSettings {
  timezone: string;
  slotMinutes: number;
  workingHours: WorkingHours;
}

export async function loadSettings(db: Pick<pg.Pool, 'query'>, workspaceId: string): Promise<WorkspaceSettings> {
  const r = (await db.query('select timezone, slot_minutes, working_hours from workspaces where id = $1', [workspaceId])).rows[0];
  return { timezone: r.timezone, slotMinutes: r.slot_minutes, workingHours: r.working_hours };
}

/** Local weekday + minutes since midnight of an instant in the given time zone. */
export function localParts(at: Date, timeZone: string): { day: Day; minutes: number } {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone, weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(at);
  const get = (t: string) => parts.find((p) => p.type === t)!.value;
  return { day: get('weekday').slice(0, 3).toLowerCase() as Day, minutes: Number(get('hour')) * 60 + Number(get('minute')) };
}

const toMinutes = (s: string) => Number(s.slice(0, 2)) * 60 + Number(s.slice(3));

/** True when [start, start+duration) fits inside one working-hours range of that local day. */
export function withinWorkingHours(s: WorkspaceSettings, start: Date, durationMinutes: number): boolean {
  const { day, minutes } = localParts(start, s.timezone);
  return (s.workingHours[day] ?? []).some((r) => minutes >= toMinutes(r.start) && minutes + durationMinutes <= toMinutes(r.end));
}

export function settingsRoutes(app: FastifyInstance, pool: pg.Pool) {
  app.get('/workspace/settings', workspaceGuard(pool), async (req) => loadSettings(pool, req.workspace!.workspaceId));

  app.patch('/workspace/settings', workspaceGuard(pool, 'staff.manage'), async (req) => {
    const body = z
      .object({ timezone: tzSchema.optional(), slotMinutes: z.number().int().min(5).max(120).optional(), workingHours: workingHoursSchema.optional() })
      .refine((b) => Object.keys(b).length > 0, 'Nothing to update')
      .parse(req.body);
    const ws = req.workspace!;
    await tx(pool, async (c) => {
      await c.query(
        `update workspaces set timezone = coalesce($2, timezone), slot_minutes = coalesce($3, slot_minutes), working_hours = coalesce($4::jsonb, working_hours) where id = $1`,
        [ws.workspaceId, body.timezone ?? null, body.slotMinutes ?? null, body.workingHours ? JSON.stringify(body.workingHours) : null],
      );
      await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: 'workspace.settings_updated', metadata: { fields: Object.keys(body) }, ip: req.ip });
    });
    return loadSettings(pool, ws.workspaceId);
  });
}
