import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { verifyChain } from '../src/audit.js';
import { dueReminders } from '../src/routes/followups.js';
import { login, makeVerifiedDoctor, reset, setupApp } from './helpers.js';

let ctx: Awaited<ReturnType<typeof setupApp>>;
beforeAll(async () => void (ctx = await setupApp()));
afterAll(async () => {
  await ctx.app.close();
  await ctx.pool.end();
});
beforeEach(() => reset(ctx.pool));

type H = { headers: Record<string, string> };
const call = (method: 'GET' | 'POST' | 'PATCH' | 'DELETE', s: H, url: string, payload?: Record<string, unknown>) => ctx.app.inject({ method, url, headers: s.headers, payload });
const post = (s: H, url: string, p: Record<string, unknown> = {}) => call('POST', s, url, p);
const get = (s: H, url: string) => call('GET', s, url);
const patch = (s: H, url: string, p: Record<string, unknown>) => call('PATCH', s, url, p);

const day = (offset: number) => new Date(Date.now() + offset * 86_400_000).toISOString().slice(0, 10);
const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.from(`JFIF-${'x'.repeat(200)}`)]);
async function uploadAsPatient(s: H) {
  const b = '----t';
  const body = Buffer.concat([
    Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="category"\r\n\r\nother\r\n--${b}\r\nContent-Disposition: form-data; name="title"\r\n\r\nBP photo\r\n`),
    Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="file"; filename="a.jpg"\r\nContent-Type: image/jpeg\r\n\r\n`),
    jpeg,
    Buffer.from(`\r\n--${b}--\r\n`),
  ]);
  const r = await ctx.app.inject({ method: 'POST', url: '/patient/documents', headers: { ...s.headers, 'content-type': `multipart/form-data; boundary=${b}` }, payload: body });
  return r.json().id as string;
}

async function connectPatient(doc: H, phone: string, name: string) {
  const rel = (await post(doc, '/patients', { phone, fullName: name })).json();
  const pt = await login(ctx.app, phone);
  await post(pt, '/patient/claim');
  for (const r of (await get(pt, '/patient/relationships')).json() as { id: string; status: string }[]) {
    if (r.status === 'invited') await post(pt, `/patient/relationships/${r.id}/accept`);
  }
  return { rel, pt };
}

const HR = { kind: 'heart_rate', frequency: 'daily', normalMin: 50, normalMax: 100 };
const SYMPTOM = { name: 'Pain score', unit: '/10', frequency: 'custom', intervalDays: 3, normalMax: 4 };

async function world() {
  const a = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
  const b = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000002');
  const { rel, pt } = await connectPatient(a, '+201111111111', 'Mona Hassan');
  const plan = (await post(a, `/patients/${rel.id}/followups`, { instructions: 'Measure at rest', nextVisitDate: day(14), endDate: day(14), measurements: [HR, SYMPTOM] })).json();
  return { a, b, rel, pt, plan };
}
const submit = (pt: H, planId: string, measurementId: string, value: number, extra: Record<string, unknown> = {}) =>
  post(pt, `/patient/followups/${planId}/submissions`, { measurementId, value, measuredAt: new Date().toISOString(), ...extra });

describe('plans (clinic)', () => {
  it('creates a plan with known and custom measurements and records version 1', async () => {
    const { a, plan } = await world();
    expect(plan).toMatchObject({ status: 'active', currentVersion: 1, instructions: 'Measure at rest' });
    expect(plan.measurements).toHaveLength(2);
    expect(plan.measurements[0]).toMatchObject({ kind: 'heart_rate', name: 'Heart rate', unit: 'bpm', frequency: 'daily', intervalDays: 1, normalMin: 50, normalMax: 100 });
    expect(plan.measurements[1]).toMatchObject({ kind: null, name: 'Pain score', frequency: 'custom', intervalDays: 3 });
    const h = (await get(a, `/followups/${plan.id}/history`)).json();
    expect(h).toHaveLength(1);
    expect(h[0]).toMatchObject({ version: 1, change: 'created' });
  });

  it('validates input', async () => {
    const { a, rel } = await world();
    const bad = (p: Record<string, unknown>) => post(a, `/patients/${rel.id}/followups`, p);
    expect((await bad({ measurements: [{ frequency: 'daily' }] })).statusCode).toBe(400);
    expect((await bad({ measurements: [{ name: 'x', frequency: 'custom' }] })).statusCode).toBe(400);
    expect((await bad({ measurements: [{ name: 'x', frequency: 'daily', normalMin: 9, normalMax: 1 }] })).statusCode).toBe(400);
    expect((await bad({ startDate: day(5), endDate: day(1) })).statusCode).toBe(400);
  });

  it('keeps history across edits and close, and writes audit events', async () => {
    const { a, plan } = await world();
    const e1 = await patch(a, `/followups/${plan.id}`, { version: 1, instructions: 'Measure twice a day', measurements: [{ ...HR, id: plan.measurements[0].id, normalMax: 110 }, { id: plan.measurements[1].id, ...SYMPTOM }] });
    expect(e1.statusCode).toBe(200);
    expect(e1.json()).toMatchObject({ currentVersion: 2, instructions: 'Measure twice a day' });
    expect((await patch(a, `/followups/${plan.id}`, { version: 1, instructions: 'stale' })).statusCode).toBe(409);
    const closed = await post(a, `/followups/${plan.id}/close`, { reason: 'Recovered' });
    expect(closed.json()).toMatchObject({ status: 'closed', currentVersion: 3, closeReason: 'Recovered' });
    expect((await patch(a, `/followups/${plan.id}`, { instructions: 'after close' })).statusCode).toBe(409);
    expect((await post(a, `/followups/${plan.id}/close`)).statusCode).toBe(409);

    const h = (await get(a, `/followups/${plan.id}/history`)).json();
    expect(h.map((v: { version: number; change: string }) => [v.version, v.change])).toEqual([[3, 'closed'], [2, 'edited'], [1, 'created']]);
    expect(h[2].snapshot.plan.instructions).toBe('Measure at rest');
    expect(h[1].snapshot.plan.instructions).toBe('Measure twice a day');
    expect(h[1].snapshot.measurements.find((m: { kind: string }) => m.kind === 'heart_rate').normalMax).toBe(110);
    expect(h[2].snapshot.measurements.find((m: { kind: string }) => m.kind === 'heart_rate').normalMax).toBe(100);

    const actions = (await ctx.pool.query(`select action from audit_log where action like 'followup.%' order by seq`)).rows.map((r) => r.action);
    expect(actions).toEqual(['followup.plan_created', 'followup.plan_edited', 'followup.plan_closed']);
    expect(await verifyChain(ctx.pool, (await ctx.pool.query('select workspace_id from followup_plans')).rows[0].workspace_id)).toMatchObject({ valid: true });
  });

  it('retires dropped measurements without losing their submissions', async () => {
    const { a, pt, plan } = await world();
    await submit(pt, plan.id, plan.measurements[1].id, 3);
    const e = (await patch(a, `/followups/${plan.id}`, { measurements: [{ ...HR, id: plan.measurements[0].id }] })).json();
    expect(e.measurements.find((m: { id: string }) => m.id === plan.measurements[1].id).active).toBe(false);
    expect(e.submissions).toHaveLength(1);
    expect((await submit(pt, plan.id, plan.measurements[1].id, 3)).statusCode).toBe(404);
  });
});

describe('authorization', () => {
  it('receptionists cannot see or change plan content; nurses read but cannot write', async () => {
    const { a, rel, plan } = await world();
    const staff = async (phone: string, role: string) => {
      const inv = (await post(a, '/workspace/invitations', { phone, role })).json();
      const s = await login(ctx.app, phone);
      await post(s, '/invitations/accept', { code: inv.code });
      return s;
    };
    const rec = await staff('+201222222221', 'receptionist');
    const nurse = await staff('+201222222222', 'nurse');
    for (const r of [await get(rec, `/followups/${plan.id}`), await get(rec, `/patients/${rel.id}/followups`), await get(rec, '/followups/attention'), await get(rec, `/followups/${plan.id}/history`)]) {
      expect(r.statusCode).toBe(403);
    }
    expect((await post(rec, `/patients/${rel.id}/followups`, {})).statusCode).toBe(403);
    expect((await get(nurse, `/followups/${plan.id}`)).statusCode).toBe(200);
    expect((await post(nurse, `/patients/${rel.id}/followups`, {})).statusCode).toBe(403);
    expect((await patch(nurse, `/followups/${plan.id}`, { instructions: 'x' })).statusCode).toBe(403);
    expect((await post(nurse, `/followups/${plan.id}/close`)).statusCode).toBe(403);
  });

  it('a doctor without MFA / verification cannot write plans', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000009', false);
    const rel = (await post(d, '/patients', { phone: '+201333333333', fullName: 'X Y' })).json();
    const r = await post(d, `/patients/${rel.id}/followups`, {});
    expect(r.statusCode).toBe(403);
  });

  it('another doctor cannot see, edit, close, chart or list a plan (RULE-003)', async () => {
    const { a, b, rel, pt, plan } = await world();
    await submit(pt, plan.id, plan.measurements[0].id, 150);
    expect((await get(b, `/followups/${plan.id}`)).statusCode).toBe(404);
    expect((await get(b, `/followups/${plan.id}/history`)).statusCode).toBe(404);
    expect((await get(b, `/followups/${plan.id}/measurements/${plan.measurements[0].id}/trend`)).statusCode).toBe(404);
    expect((await patch(b, `/followups/${plan.id}`, { instructions: 'hijack' })).statusCode).toBe(404);
    expect((await post(b, `/followups/${plan.id}/close`)).statusCode).toBe(404);
    expect((await get(b, `/patients/${rel.id}/followups`)).statusCode).toBe(404);
    expect((await post(b, `/patients/${rel.id}/followups`, {})).statusCode).toBe(404);
    expect((await get(b, '/followups/attention')).json()).toEqual([]);
    expect((await get(a, `/followups/${plan.id}`)).json().instructions).toBe('Measure at rest');
  });

  it('a patient sees only their own plans, and not before accepting the relationship', async () => {
    const { a, pt, plan } = await world();
    const other = await login(ctx.app, '+201444444444');
    await post(other, '/patient/claim');
    expect((await get(other, '/patient/followups')).json()).toEqual([]);
    expect((await get(other, `/patient/followups/${plan.id}/submissions`)).statusCode).toBe(404);
    expect((await submit(other, plan.id, plan.measurements[0].id, 70)).statusCode).toBe(404);
    expect((await get(other, '/patient/followups/due')).json()).toEqual([]);

    // Invited (not yet accepted) relationships expose nothing.
    const rel2 = (await post(a, '/patients', { phone: '+201444444444', fullName: 'Other P' })).json();
    const plan2 = (await post(a, `/patients/${rel2.id}/followups`, { measurements: [HR] })).json();
    expect((await get(other, '/patient/followups')).json()).toEqual([]);
    expect((await submit(other, plan2.id, plan2.measurements[0].id, 70)).statusCode).toBe(404);
    await post(other, `/patient/relationships/${rel2.id}/accept`);
    const mine = (await get(other, '/patient/followups')).json();
    expect(mine.map((p: { id: string }) => p.id)).toEqual([plan2.id]);
    // The first patient still only sees theirs.
    expect((await get(pt, '/patient/followups')).json().map((p: { id: string }) => p.id)).toEqual([plan.id]);
    // Unauthenticated
    expect((await ctx.app.inject({ method: 'GET', url: '/patient/followups' })).statusCode).toBe(401);
  });

  it('an ended relationship hides the plan from the patient and stops submissions', async () => {
    const { a, rel, pt, plan } = await world();
    await post(a, `/patients/${rel.id}/end`);
    expect((await get(pt, '/patient/followups')).json()).toEqual([]);
    expect((await submit(pt, plan.id, plan.measurements[0].id, 70)).statusCode).toBe(404);
    expect((await dueReminders(ctx.pool, new Date(Date.now() + 5 * 86_400_000))).length).toBe(0);
  });
});

describe('patient submissions', () => {
  it('flags out-of-range values for the doctor only, always as unverified patient-reported data', async () => {
    const { a, pt, plan } = await world();
    const hr = plan.measurements[0].id;
    const ok = await submit(pt, plan.id, hr, 72, { note: 'resting' });
    const high = await submit(pt, plan.id, hr, 130);
    expect(ok.statusCode).toBe(201);
    // Patient-facing payloads: no flag, no range, no verdict.
    for (const r of [ok, high]) {
      expect(r.json()).toMatchObject({ source: 'patient', verified: false });
      expect(r.json()).not.toHaveProperty('outsideExpectedRange');
      expect(JSON.stringify(r.json())).not.toMatch(/outside|expected range/i);
    }
    const hist = await get(pt, `/patient/followups/${plan.id}/submissions`);
    expect(hist.json()).toHaveLength(2);
    expect(hist.body).not.toMatch(/outsideExpectedRange|outside expected|normalM/);
    const plans = await get(pt, '/patient/followups');
    expect(plans.body).not.toMatch(/normalM|outside expected/);

    // Clinic: flagged with the required wording.
    const d = (await get(a, `/followups/${plan.id}`)).json();
    const byVal = (v: number) => d.submissions.find((s: { value: number }) => s.value === v);
    expect(byVal(72)).toMatchObject({ outsideExpectedRange: false, flagLabel: null, source: 'patient', verified: false, note: 'resting' });
    expect(byVal(130)).toMatchObject({ outsideExpectedRange: true, flagLabel: 'patient-reported, outside expected range', source: 'patient', verified: false });
    expect(JSON.stringify(d)).not.toMatch(/"verified":true/);

    // Never mixed into clinician observations.
    expect((await ctx.pool.query('select count(*)::int as n from observations')).rows[0].n).toBe(0);
    expect((await ctx.pool.query(`select distinct source from followup_submissions`)).rows).toEqual([{ source: 'patient' }]);
  });

  it('the range check follows the current plan range and handles one-sided ranges', async () => {
    const { a, pt, plan } = await world();
    await submit(pt, plan.id, plan.measurements[0].id, 110);
    await submit(pt, plan.id, plan.measurements[1].id, 7);
    let d = (await get(a, `/followups/${plan.id}`)).json();
    expect(d.submissions.filter((s: { outsideExpectedRange: boolean }) => s.outsideExpectedRange)).toHaveLength(2);
    await patch(a, `/followups/${plan.id}`, { measurements: [{ ...HR, id: plan.measurements[0].id, normalMax: 120 }, { ...SYMPTOM, id: plan.measurements[1].id }] });
    d = (await get(a, `/followups/${plan.id}`)).json();
    expect(d.submissions.filter((s: { outsideExpectedRange: boolean }) => s.outsideExpectedRange)).toHaveLength(1);
  });

  it('rejects submissions after the plan is closed or has ended (F09 acceptance)', async () => {
    const { a, pt, plan } = await world();
    expect((await submit(pt, plan.id, plan.measurements[0].id, 70)).statusCode).toBe(201);
    await post(a, `/followups/${plan.id}/close`);
    const closed = await submit(pt, plan.id, plan.measurements[0].id, 71);
    expect(closed.statusCode).toBe(409);
    expect(closed.json().error).toBe('plan_closed');

    const rel = (await get(a, '/patients')).json()[0];
    const past = (await post(a, `/patients/${rel.id}/followups`, { startDate: day(-10), endDate: day(-3), measurements: [HR] })).json();
    const late = await submit(pt, past.id, past.measurements[0].id, 70);
    expect(late.statusCode).toBe(409);
    expect(late.json().error).toBe('plan_ended');
    const future = (await post(a, `/patients/${rel.id}/followups`, { startDate: day(5), measurements: [HR] })).json();
    expect((await submit(pt, future.id, future.measurements[0].id, 70)).json().error).toBe('plan_not_started');
    // Plans that ended on today's date still accept today's values (end date is inclusive).
    const today = (await post(a, `/patients/${rel.id}/followups`, { endDate: day(0), measurements: [HR] })).json();
    expect(today.endDate).toBeTruthy();
  });

  it('validates value, time, measurement ownership and attachments', async () => {
    const { a, pt, plan } = await world();
    const hr = plan.measurements[0].id;
    expect((await submit(pt, plan.id, hr, 9999)).json().error).toBe('implausible_value');
    expect((await post(pt, `/patient/followups/${plan.id}/submissions`, { measurementId: hr, value: 70, measuredAt: new Date(Date.now() + 3_600_000).toISOString() })).statusCode).toBe(400);
    expect((await post(pt, `/patient/followups/${plan.id}/submissions`, { measurementId: hr, value: 'abc', measuredAt: new Date().toISOString() })).statusCode).toBe(400);
    expect((await submit(pt, plan.id, '00000000-0000-4000-8000-000000000000', 70)).statusCode).toBe(404);

    // Another plan's measurement cannot be used.
    const rel = (await get(a, '/patients')).json()[0];
    const p2 = (await post(a, `/patients/${rel.id}/followups`, { measurements: [HR] })).json();
    expect((await submit(pt, plan.id, p2.measurements[0].id, 70)).statusCode).toBe(404);

    // Attachment must be the patient's own upload.
    const other = await login(ctx.app, '+201555555555');
    await post(other, '/patient/claim');
    const foreign = await uploadAsPatient(other);
    expect((await submit(pt, plan.id, hr, 70, { documentId: foreign })).statusCode).toBe(404);
    expect((await submit(pt, plan.id, hr, 70, { documentId: '00000000-0000-4000-8000-000000000000' })).statusCode).toBe(404);
  });

  it('an attachment is sent to the treating doctor only, via the existing document upload', async () => {
    const { a, b, pt, plan } = await world();
    const docId = await uploadAsPatient(pt);
    const s = await submit(pt, plan.id, plan.measurements[0].id, 88, { documentId: docId });
    expect(s.statusCode).toBe(201);
    expect(s.json().documentId).toBe(docId);
    const d = (await get(a, `/followups/${plan.id}`)).json();
    expect(d.submissions[0].documentId).toBe(docId);
    const doc = await get(a, `/documents/${docId}`);
    expect(doc.statusCode).toBe(200);
    expect(doc.json()).toMatchObject({ source: 'patient', provenance: 'patient_submitted_unverified' });
    expect((await get(b, `/documents/${docId}`)).statusCode).toBe(404);
  });

  it('writes a submission audit event without the measured value', async () => {
    const { pt, plan } = await world();
    await submit(pt, plan.id, plan.measurements[0].id, 87.25);
    const row = (await ctx.pool.query(`select actor_role, metadata from audit_log where action = 'followup.submission_created'`)).rows[0];
    expect(row.actor_role).toBe('patient');
    expect(JSON.stringify(row.metadata)).not.toContain('87.25');
  });
});

describe('trend and attention', () => {
  it('returns ordered trend points with flags for the chart', async () => {
    const { a, pt, plan } = await world();
    const hr = plan.measurements[0].id;
    const at = (h: number) => new Date(Date.now() - h * 3_600_000).toISOString();
    await submit(pt, plan.id, hr, 120, { measuredAt: at(3) });
    await submit(pt, plan.id, hr, 70, { measuredAt: at(30) });
    await submit(pt, plan.id, hr, 80, { measuredAt: at(2) });
    const t = (await get(a, `/followups/${plan.id}/measurements/${hr}/trend`)).json();
    expect(t).toMatchObject({ source: 'patient', verified: false, measurement: { name: 'Heart rate', normalMin: 50, normalMax: 100 } });
    expect(t.points.map((p: { value: number }) => p.value)).toEqual([70, 120, 80]);
    expect(t.points.map((p: { outsideExpectedRange: boolean }) => p.outsideExpectedRange)).toEqual([false, true, false]);
  });

  it('lists patients with overdue measurements and drops them once they report', async () => {
    const { a, rel, pt } = await world();
    expect((await get(a, '/followups/attention')).json()).toEqual([]);
    const late = (await post(a, `/patients/${rel.id}/followups`, { startDate: day(-4), measurements: [HR, { name: 'Pain', frequency: 'weekly' }] })).json();
    let att = (await get(a, '/followups/attention')).json();
    expect(att).toHaveLength(1);
    expect(att[0]).toMatchObject({ careRelationshipId: rel.id, patientName: 'Mona Hassan' });
    // The first reading is due on the start date, so a weekly measurement with nothing reported is overdue too.
    expect(att[0].items.map((i: { measurementName: string }) => i.measurementName)).toEqual(['Heart rate', 'Pain']);
    expect(att[0].items[0].daysOverdue).toBeGreaterThanOrEqual(3);
    await submit(pt, late.id, late.measurements[0].id, 70);
    att = (await get(a, '/followups/attention')).json();
    expect(att[0].items.map((i: { measurementName: string }) => i.measurementName)).toEqual(['Pain']);
    await submit(pt, late.id, late.measurements[1].id, 3);
    att = (await get(a, '/followups/attention')).json();
    expect(att).toEqual([]);
    // Closed plans never need attention.
    const closedPlan = (await post(a, `/patients/${rel.id}/followups`, { startDate: day(-4), measurements: [HR] })).json();
    expect((await get(a, '/followups/attention')).json()).toHaveLength(1);
    await post(a, `/followups/${closedPlan.id}/close`);
    expect((await get(a, '/followups/attention')).json()).toEqual([]);
  });
});

describe('due and reminders', () => {
  it('GET /patient/followups/due reports what is due now', async () => {
    const { pt, plan } = await world();
    let due = (await get(pt, '/patient/followups/due')).json();
    expect(due.map((d: { measurementName: string }) => d.measurementName).sort()).toEqual(['Heart rate', 'Pain score']);
    await submit(pt, plan.id, plan.measurements[0].id, 70);
    due = (await get(pt, '/patient/followups/due')).json();
    expect(due.map((d: { measurementName: string }) => d.measurementName)).toEqual(['Pain score']);
  });

  it('dueReminders(pool, now) follows measurement frequency and carries no clinical content', async () => {
    const { pt, plan } = await world();
    const userId = (await ctx.pool.query('select user_id from patients')).rows[0].user_id;
    const now = new Date();
    let r = await dueReminders(ctx.pool, now);
    expect(r.map((x) => x.measurementName).sort()).toEqual(['Heart rate', 'Pain score']);
    expect(r[0]!).toMatchObject({ patientUserId: userId, planId: plan.id });
    expect(r[0]!.dueAt).toBeInstanceOf(Date);
    expect(Object.keys(r[0]!).sort()).toEqual(['dueAt', 'measurementName', 'patientUserId', 'planId']);

    await submit(pt, plan.id, plan.measurements[0].id, 70);
    await submit(pt, plan.id, plan.measurements[1].id, 2);
    expect(await dueReminders(ctx.pool, now)).toEqual([]);
    r = await dueReminders(ctx.pool, new Date(now.getTime() + 25 * 3_600_000));
    expect(r.map((x) => x.measurementName)).toEqual(['Heart rate']); // daily is due again, 3-day custom is not
    r = await dueReminders(ctx.pool, new Date(now.getTime() + 73 * 3_600_000));
    expect(r.map((x) => x.measurementName).sort()).toEqual(['Heart rate', 'Pain score']);
    // After the plan ended nothing is due; closed plans neither.
    expect(await dueReminders(ctx.pool, new Date(now.getTime() + 20 * 86_400_000))).toEqual([]);
  });

  it('closed plans produce no reminders', async () => {
    const { a, plan } = await world();
    await post(a, `/followups/${plan.id}/close`);
    expect(await dueReminders(ctx.pool, new Date())).toEqual([]);
  });
});
