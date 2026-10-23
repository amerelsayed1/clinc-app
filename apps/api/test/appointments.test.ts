import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { verifyChain } from '../src/audit.js';
import { login, makeVerifiedDoctor, reset, setupApp } from './helpers.js';

let ctx: Awaited<ReturnType<typeof setupApp>>;
beforeAll(async () => void (ctx = await setupApp()));
afterAll(async () => {
  await ctx.app.close();
  await ctx.pool.end();
});
beforeEach(() => reset(ctx.pool));

type Doctor = Awaited<ReturnType<typeof makeVerifiedDoctor>>;
const ALL_DAY = Object.fromEntries(['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'].map((d) => [d, [{ start: '00:00', end: '23:59' }]]));

/** Doctor with an open-all-day clinic, so tests control hours explicitly when they care. */
async function setup() {
  const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
  await ctx.app.inject({ method: 'PATCH', url: '/workspace/settings', headers: d.headers, payload: { workingHours: ALL_DAY } });
  const pat = (await ctx.app.inject({ method: 'POST', url: '/patients', headers: d.headers, payload: { phone: '+201111111111', fullName: 'Mona Hassan' } })).json();
  return { d, pat };
}
const at = (hours: number, dayOffset = 1) => {
  const t = new Date();
  t.setUTCDate(t.getUTCDate() + dayOffset);
  t.setUTCHours(hours, 0, 0, 0);
  return t.toISOString();
};
const book = (d: { headers: Record<string, string> }, payload: Record<string, unknown>) =>
  ctx.app.inject({ method: 'POST', url: '/appointments', headers: d.headers, payload });
const post = (d: { headers: Record<string, string> }, url: string, payload: Record<string, unknown> = {}) =>
  ctx.app.inject({ method: 'POST', url, headers: d.headers, payload });
async function staffOf(d: Doctor, phone: string, role: 'nurse' | 'receptionist') {
  const inv = (await post(d, '/workspace/invitations', { phone, role })).json();
  const s = await login(ctx.app, phone);
  await post(s, '/invitations/accept', { code: inv.code });
  return s;
}

describe('booking', () => {
  it('creates an appointment using the clinic slot length by default', async () => {
    const { d, pat } = await setup();
    const r = await book(d, { patientId: pat.id, scheduledAt: at(10), reason: 'Check-up' });
    expect(r.statusCode).toBe(201);
    expect(r.json()).toMatchObject({ status: 'scheduled', durationMinutes: 15, type: 'new', isWalkIn: false, reason: 'Check-up', patient: { fullName: 'Mona Hassan', patientNumber: 1 } });
  });

  it('interprets localStart in the clinic time zone', async () => {
    const { d, pat } = await setup();
    const s = await ctx.app.inject({ method: 'PATCH', url: '/workspace/settings', headers: d.headers, payload: { timezone: 'Asia/Karachi' } }); // UTC+5, no DST
    expect(s.statusCode).toBe(200);
    const r = await book(d, { patientId: pat.id, localStart: '2030-06-03T10:30' });
    expect(r.statusCode).toBe(201);
    expect(new Date(r.json().scheduledAt).toISOString()).toBe('2030-06-03T05:30:00.000Z');
  });

  it('rejects the past, bad input and unknown patients', async () => {
    const { d, pat } = await setup();
    expect((await book(d, { patientId: pat.id, scheduledAt: at(10, -1) })).json().error).toBe('in_the_past');
    expect((await book(d, { patientId: pat.id })).statusCode).toBe(400);
    expect((await book(d, { patientId: pat.id, scheduledAt: at(10), localStart: '2030-01-01T10:00' })).statusCode).toBe(400);
    expect((await book(d, { patientId: pat.id, scheduledAt: at(10), durationMinutes: 1 })).statusCode).toBe(400);
    expect((await book(d, { patientId: '00000000-0000-0000-0000-000000000000', scheduledAt: at(10) })).statusCode).toBe(404);
  });

  it('blocks overlaps with details, allows back-to-back and explicit override, ignores cancelled', async () => {
    const { d, pat } = await setup();
    const first = (await book(d, { patientId: pat.id, scheduledAt: at(10), durationMinutes: 30 })).json();
    const clash = await book(d, { patientId: pat.id, scheduledAt: new Date(Date.parse(at(10)) + 15 * 60_000).toISOString() });
    expect(clash.statusCode).toBe(409);
    expect(clash.json().error).toBe('slot_conflict');
    expect(clash.json().details.conflicts).toHaveLength(1);
    expect(clash.json().details.conflicts[0].id).toBe(first.id);

    const adjacent = await book(d, { patientId: pat.id, scheduledAt: new Date(Date.parse(at(10)) + 30 * 60_000).toISOString() });
    expect(adjacent.statusCode).toBe(201);
    const forced = await book(d, { patientId: pat.id, scheduledAt: at(10), override: true });
    expect(forced.statusCode).toBe(201);

    await post(d, `/appointments/${first.id}/cancel`);
    await post(d, `/appointments/${forced.json().id}/cancel`);
    expect((await book(d, { patientId: pat.id, scheduledAt: at(10) })).statusCode).toBe(201);
  });

  it('warns outside working hours and lets staff override', async () => {
    const { d, pat } = await setup();
    await ctx.app.inject({ method: 'PATCH', url: '/workspace/settings', headers: d.headers, payload: { timezone: 'Africa/Cairo', workingHours: { sat: [{ start: '09:00', end: '17:00' }] } } });
    const friday = await book(d, { patientId: pat.id, localStart: '2030-01-04T10:00' });
    expect(friday.statusCode).toBe(409);
    expect(friday.json().error).toBe('outside_working_hours');
    expect((await book(d, { patientId: pat.id, localStart: '2030-01-05T10:00' })).statusCode).toBe(201);
    expect((await book(d, { patientId: pat.id, localStart: '2030-01-05T16:50' })).json().error).toBe('outside_working_hours'); // would end 17:05
    expect((await book(d, { patientId: pat.id, localStart: '2030-01-04T10:00', override: true })).statusCode).toBe(201);
  });

  it('never double-books under concurrent requests', async () => {
    const { d, pat } = await setup();
    const results = await Promise.all(Array.from({ length: 30 }, () => book(d, { patientId: pat.id, scheduledAt: at(11) })));
    expect(results.filter((r) => r.statusCode === 201)).toHaveLength(1);
    expect(results.filter((r) => r.statusCode === 409)).toHaveLength(29);
  });
});

describe('reschedule', () => {
  it('moves a scheduled appointment, ignoring its own old slot, and checks conflicts', async () => {
    const { d, pat } = await setup();
    const a = (await book(d, { patientId: pat.id, scheduledAt: at(10), durationMinutes: 30 })).json();
    const b = (await book(d, { patientId: pat.id, scheduledAt: at(12) })).json();
    const ext = await ctx.app.inject({ method: 'PATCH', url: `/appointments/${a.id}`, headers: d.headers, payload: { durationMinutes: 45 } });
    expect(ext.statusCode).toBe(200);
    expect(ext.json().durationMinutes).toBe(45);
    const onto = await ctx.app.inject({ method: 'PATCH', url: `/appointments/${a.id}`, headers: d.headers, payload: { scheduledAt: at(12) } });
    expect(onto.json().error).toBe('slot_conflict');
    const moved = await ctx.app.inject({ method: 'PATCH', url: `/appointments/${a.id}`, headers: d.headers, payload: { scheduledAt: at(14), reason: 'Moved' } });
    expect(moved.json()).toMatchObject({ reason: 'Moved' });
    expect(b.id).toBeTruthy();
  });

  it('cannot change an appointment once the patient checked in', async () => {
    const { d, pat } = await setup();
    const a = (await book(d, { patientId: pat.id, scheduledAt: at(10) })).json();
    await post(d, `/appointments/${a.id}/check-in`);
    const r = await ctx.app.inject({ method: 'PATCH', url: `/appointments/${a.id}`, headers: d.headers, payload: { scheduledAt: at(11) } });
    expect(r.statusCode).toBe(409);
  });
});

describe('status machine and permissions', () => {
  it('walks scheduled -> checked_in -> in_consultation -> completed with timestamps', async () => {
    const { d, pat } = await setup();
    const a = (await book(d, { patientId: pat.id, scheduledAt: at(10) })).json();
    expect((await post(d, `/appointments/${a.id}/start`)).statusCode).toBe(409); // must check in first
    const ci = (await post(d, `/appointments/${a.id}/check-in`)).json();
    expect(ci).toMatchObject({ status: 'checked_in' });
    expect(ci.checkedInAt).toBeTruthy();
    expect((await post(d, `/appointments/${a.id}/check-in`)).statusCode).toBe(409);
    expect((await post(d, `/appointments/${a.id}/start`)).json()).toMatchObject({ status: 'in_consultation' });
    const done = (await post(d, `/appointments/${a.id}/complete`)).json();
    expect(done.status).toBe('completed');
    expect(done.startedAt && done.completedAt).toBeTruthy();
    expect((await post(d, `/appointments/${a.id}/cancel`)).statusCode).toBe(409);
  });

  it('front desk can check in and cancel but cannot run the consultation (RULE-005/006)', async () => {
    const { d, pat } = await setup();
    const rec = await staffOf(d, '+201000000002', 'receptionist');
    const a = (await book(rec, { patientId: pat.id, scheduledAt: at(10) })).json();
    expect((await post(rec, `/appointments/${a.id}/check-in`)).statusCode).toBe(200);
    expect((await post(rec, `/appointments/${a.id}/start`)).statusCode).toBe(403);
    expect((await post(d, `/appointments/${a.id}/start`)).statusCode).toBe(200);
    expect((await post(rec, `/appointments/${a.id}/complete`)).statusCode).toBe(403);
  });

  it('an unverified doctor cannot start consultations', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001', false);
    await ctx.app.inject({ method: 'PATCH', url: '/workspace/settings', headers: d.headers, payload: { workingHours: ALL_DAY } });
    const pat = (await post(d, '/patients', { phone: '+201111111111', fullName: 'Mona Hassan' })).json();
    const a = (await book(d, { patientId: pat.id, scheduledAt: at(10) })).json();
    await post(d, `/appointments/${a.id}/check-in`);
    expect((await post(d, `/appointments/${a.id}/start`)).statusCode).toBe(403);
  });

  it('nurses can view the schedule but not change it', async () => {
    const { d, pat } = await setup();
    const nurse = await staffOf(d, '+201000000003', 'nurse');
    const a = (await book(d, { patientId: pat.id, scheduledAt: at(10) })).json();
    expect((await book(nurse, { patientId: pat.id, scheduledAt: at(12) })).statusCode).toBe(403);
    expect((await post(nurse, `/appointments/${a.id}/check-in`)).statusCode).toBe(403);
    expect((await ctx.app.inject({ method: 'GET', url: `/appointments/${a.id}`, headers: nurse.headers })).statusCode).toBe(200);
  });

  it('no-show only after the appointment time', async () => {
    const { d, pat } = await setup();
    const a = (await book(d, { patientId: pat.id, scheduledAt: at(10) })).json();
    expect((await post(d, `/appointments/${a.id}/no-show`)).json().error).toBe('too_early');
    await ctx.pool.query(`update appointments set scheduled_at = now() - interval '1 hour' where id = $1`, [a.id]);
    expect((await post(d, `/appointments/${a.id}/no-show`)).json().status).toBe('no_show');
  });

  it('cancel keeps the reason and frees the slot', async () => {
    const { d, pat } = await setup();
    const a = (await book(d, { patientId: pat.id, scheduledAt: at(10) })).json();
    const c = (await post(d, `/appointments/${a.id}/cancel`, { reason: 'Patient called' })).json();
    expect(c).toMatchObject({ status: 'cancelled', cancelReason: 'Patient called' });
    expect((await post(d, `/appointments/${a.id}/check-in`)).statusCode).toBe(409);
  });
});

describe('daily view, walk-ins and history', () => {
  it('walk-ins join the waiting list immediately and appear in today\'s view', async () => {
    const { d, pat } = await setup();
    const w = await post(d, '/appointments/walk-in', { patientId: pat.id, reason: 'No booking' });
    expect(w.statusCode).toBe(201);
    expect(w.json()).toMatchObject({ status: 'checked_in', isWalkIn: true });
    const today = (await ctx.app.inject({ method: 'GET', url: '/appointments', headers: d.headers })).json();
    expect(today).toHaveLength(1);
    const tomorrow = (await ctx.app.inject({ method: 'GET', url: '/appointments?date=2999-01-01', headers: d.headers })).json();
    expect(tomorrow).toHaveLength(0);
  });

  it('filters by day in the clinic time zone and by status, ordered by time', async () => {
    const { d, pat } = await setup();
    await ctx.app.inject({ method: 'PATCH', url: '/workspace/settings', headers: d.headers, payload: { timezone: 'Asia/Karachi' } });
    // 20:30Z is 01:30 the NEXT day in Karachi (UTC+5)
    await book(d, { patientId: pat.id, scheduledAt: '2030-06-03T20:30:00Z' });
    await book(d, { patientId: pat.id, scheduledAt: '2030-06-03T07:00:00Z' });
    const day3 = (await ctx.app.inject({ method: 'GET', url: '/appointments?date=2030-06-03', headers: d.headers })).json();
    const day4 = (await ctx.app.inject({ method: 'GET', url: '/appointments?date=2030-06-04', headers: d.headers })).json();
    expect(day3).toHaveLength(1);
    expect(day4).toHaveLength(1);
    expect(new Date(day3[0].scheduledAt).toISOString()).toBe('2030-06-03T07:00:00.000Z');
    expect((await ctx.app.inject({ method: 'GET', url: '/appointments?date=2030-06-03&status=cancelled', headers: d.headers })).json()).toHaveLength(0);
  });

  it('lists one patient\'s appointments newest first', async () => {
    const { d, pat } = await setup();
    await book(d, { patientId: pat.id, scheduledAt: at(10, 1) });
    await book(d, { patientId: pat.id, scheduledAt: at(10, 3) });
    const h = (await ctx.app.inject({ method: 'GET', url: `/appointments?patientId=${pat.id}`, headers: d.headers })).json();
    expect(h).toHaveLength(2);
    expect(Date.parse(h[0].scheduledAt)).toBeGreaterThan(Date.parse(h[1].scheduledAt));
  });
});

describe('isolation and relationship lifecycle', () => {
  it('another clinic cannot see, book for, or change these appointments', async () => {
    const { d, pat } = await setup();
    const a = (await book(d, { patientId: pat.id, scheduledAt: at(10) })).json();
    const d2 = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000009');
    expect((await ctx.app.inject({ method: 'GET', url: `/appointments/${a.id}`, headers: d2.headers })).statusCode).toBe(404);
    expect((await post(d2, `/appointments/${a.id}/cancel`)).statusCode).toBe(404);
    expect((await ctx.app.inject({ method: 'PATCH', url: `/appointments/${a.id}`, headers: d2.headers, payload: { reason: 'x' } })).statusCode).toBe(404);
    expect((await book(d2, { patientId: pat.id, scheduledAt: at(10), override: true })).statusCode).toBe(404);
    expect((await ctx.app.inject({ method: 'GET', url: '/appointments?date=' + at(10).slice(0, 10), headers: d2.headers })).json()).toHaveLength(0);
  });

  it('ending a relationship cancels unfinished appointments and blocks new ones', async () => {
    const { d, pat } = await setup();
    const upcoming = (await book(d, { patientId: pat.id, scheduledAt: at(10) })).json();
    const waiting = (await book(d, { patientId: pat.id, scheduledAt: at(12) })).json();
    await post(d, `/appointments/${waiting.id}/check-in`);
    const done = (await book(d, { patientId: pat.id, scheduledAt: at(14) })).json();
    await post(d, `/appointments/${done.id}/check-in`);
    await post(d, `/appointments/${done.id}/start`);
    await post(d, `/appointments/${done.id}/complete`);

    expect((await post(d, `/patients/${pat.id}/end`)).statusCode).toBe(200);
    const get = async (id: string) => (await ctx.app.inject({ method: 'GET', url: `/appointments/${id}`, headers: d.headers })).json();
    expect(await get(upcoming.id)).toMatchObject({ status: 'cancelled', cancelReason: 'Relationship ended' });
    expect((await get(waiting.id)).status).toBe('cancelled');
    expect((await get(done.id)).status).toBe('completed');
    expect((await book(d, { patientId: pat.id, scheduledAt: at(16) })).json().error).toBe('relationship_ended');
    expect((await post(d, '/appointments/walk-in', { patientId: pat.id })).statusCode).toBe(409);
  });

  it('a patient ending the relationship also cancels open appointments', async () => {
    const { d, pat } = await setup();
    const a = (await book(d, { patientId: pat.id, scheduledAt: at(10) })).json();
    const p = await login(ctx.app, '+201111111111');
    await post(p, '/patient/claim');
    await post(p, `/patient/relationships/${pat.id}/end`);
    expect((await ctx.app.inject({ method: 'GET', url: `/appointments/${a.id}`, headers: d.headers })).json().status).toBe('cancelled');
  });
});

describe('settings and audit', () => {
  it('only staff managers change settings; invalid values are rejected', async () => {
    const { d } = await setup();
    const rec = await staffOf(d, '+201000000002', 'receptionist');
    expect((await ctx.app.inject({ method: 'GET', url: '/workspace/settings', headers: rec.headers })).statusCode).toBe(200);
    expect((await ctx.app.inject({ method: 'PATCH', url: '/workspace/settings', headers: rec.headers, payload: { slotMinutes: 20 } })).statusCode).toBe(403);
    expect((await ctx.app.inject({ method: 'PATCH', url: '/workspace/settings', headers: d.headers, payload: { timezone: 'Mars/Olympus' } })).statusCode).toBe(400);
    expect((await ctx.app.inject({ method: 'PATCH', url: '/workspace/settings', headers: d.headers, payload: { slotMinutes: 3 } })).statusCode).toBe(400);
    expect((await ctx.app.inject({ method: 'PATCH', url: '/workspace/settings', headers: d.headers, payload: { workingHours: { sat: [{ start: '17:00', end: '09:00' }] } } })).statusCode).toBe(400);
    const ok = await ctx.app.inject({ method: 'PATCH', url: '/workspace/settings', headers: d.headers, payload: { slotMinutes: 20 } });
    expect(ok.json()).toMatchObject({ slotMinutes: 20, timezone: 'Africa/Cairo' });
  });

  it('audits changes without copying the visit reason, and the chain stays valid', async () => {
    const { d, pat } = await setup();
    const a = (await book(d, { patientId: pat.id, scheduledAt: at(10), reason: 'Secret reason text' })).json();
    await post(d, `/appointments/${a.id}/cancel`, { reason: 'Another secret' });
    const log = (await ctx.app.inject({ method: 'GET', url: '/workspace/audit', headers: d.headers })).json();
    expect(log.map((l: { action: string }) => l.action)).toEqual(expect.arrayContaining(['appointment.created', 'appointment.cancelled', 'workspace.settings_updated']));
    expect(JSON.stringify(log)).not.toContain('secret');
    expect(JSON.stringify(log)).not.toContain('Secret');
    expect((await verifyChain(ctx.pool, d.workspaceId)).valid).toBe(true);
  });
});
