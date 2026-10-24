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
type H = { headers: Record<string, string> };

const post = (s: H, url: string, payload: Record<string, unknown> = {}) => ctx.app.inject({ method: 'POST', url, headers: s.headers, payload });
const patch = (s: H, url: string, payload: Record<string, unknown>) => ctx.app.inject({ method: 'PATCH', url, headers: s.headers, payload });
const get = async (s: H, url: string) => ctx.app.inject({ method: 'GET', url, headers: s.headers });

async function staffOf(d: Doctor, phone: string, role: 'nurse' | 'receptionist') {
  const inv = (await post(d, '/workspace/invitations', { phone, role })).json();
  const s = await login(ctx.app, phone);
  await post(s, '/invitations/accept', { code: inv.code });
  return s;
}

async function setup() {
  const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
  const pat = (await post(d, '/patients', { phone: '+201111111111', fullName: 'Mona Hassan', dateOfBirth: '1990-05-01' })).json();
  return { d, pat };
}
const newEncounter = async (d: H, patientId: string) => (await post(d, `/patients/${patientId}/encounters`)).json();

/** A signed encounter with the given content. */
async function signed(d: H, patientId: string, content: Record<string, unknown> = { chiefComplaint: 'Cough for 3 days', diagnosis: 'Acute bronchitis', plan: 'Rest and fluids', privateNotes: 'Consider TB screen', history: 'Smoker' }) {
  const e = await newEncounter(d, patientId);
  const saved = await patch(d, `/encounters/${e.id}`, { revision: e.revision, ...content });
  const s = await post(d, `/encounters/${e.id}/sign`, { revision: saved.json().revision });
  return s.json();
}

describe('creating and editing drafts', () => {
  it('creates an empty draft and autosaves with a rising revision', async () => {
    const { d, pat } = await setup();
    const e = await newEncounter(d, pat.id);
    expect(e).toMatchObject({ status: 'draft', revision: 1, currentVersion: 1, content: { chiefComplaint: '', prescriptions: [] }, patient: { fullName: 'Mona Hassan' } });
    const r1 = (await patch(d, `/encounters/${e.id}`, { revision: 1, chiefComplaint: 'Headache' })).json();
    expect(r1).toMatchObject({ revision: 2, content: { chiefComplaint: 'Headache' } });
    const r2 = (await patch(d, `/encounters/${e.id}`, { revision: 2, plan: 'Paracetamol', prescriptions: [{ medication: 'Paracetamol', dose: '500 mg' }] })).json();
    expect(r2.content).toMatchObject({ chiefComplaint: 'Headache', plan: 'Paracetamol', prescriptions: [{ medication: 'Paracetamol', dose: '500 mg', frequency: '', duration: '', notes: '' }] });
  });

  it('rejects a stale revision and returns the current content (no lost updates)', async () => {
    const { d, pat } = await setup();
    const e = await newEncounter(d, pat.id);
    await patch(d, `/encounters/${e.id}`, { revision: 1, chiefComplaint: 'Tab A' });
    const stale = await patch(d, `/encounters/${e.id}`, { revision: 1, chiefComplaint: 'Tab B' });
    expect(stale.statusCode).toBe(409);
    expect(stale.json()).toMatchObject({ error: 'revision_conflict', details: { revision: 2, content: { chiefComplaint: 'Tab A' } } });
  });

  it('only one of many concurrent saves with the same revision wins', async () => {
    const { d, pat } = await setup();
    const e = await newEncounter(d, pat.id);
    const rs = await Promise.all(Array.from({ length: 10 }, (_, i) => patch(d, `/encounters/${e.id}`, { revision: 1, plan: `Plan ${i}` })));
    expect(rs.filter((r) => r.statusCode === 200)).toHaveLength(1);
    expect(rs.filter((r) => r.statusCode === 409)).toHaveLength(9);
  });

  it('validates content', async () => {
    const { d, pat } = await setup();
    const e = await newEncounter(d, pat.id);
    expect((await patch(d, `/encounters/${e.id}`, { revision: 1, prescriptions: [{ dose: '5 mg' }] })).statusCode).toBe(400);
    expect((await patch(d, `/encounters/${e.id}`, { revision: 1, chiefComplaint: 'x'.repeat(10_001) })).statusCode).toBe(400);
    expect((await patch(d, `/encounters/${e.id}`, { chiefComplaint: 'no revision' })).statusCode).toBe(400);
  });

  it('only verified doctors can create or edit; ended patients are blocked', async () => {
    const { d, pat } = await setup();
    const rec = await staffOf(d, '+201000000002', 'receptionist');
    const nurse = await staffOf(d, '+201000000003', 'nurse');
    expect((await post(rec, `/patients/${pat.id}/encounters`)).statusCode).toBe(403);
    expect((await post(nurse, `/patients/${pat.id}/encounters`)).statusCode).toBe(403);
    const e = await newEncounter(d, pat.id);
    expect((await patch(nurse, `/encounters/${e.id}`, { revision: 1, diagnosis: 'x' })).statusCode).toBe(403);

    const unverified = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000009', false);
    const p2 = (await post(unverified, '/patients', { phone: '+201222222222', fullName: 'Omar Ali' })).json();
    expect((await post(unverified, `/patients/${p2.id}/encounters`)).statusCode).toBe(403);

    await post(d, `/patients/${pat.id}/end`);
    expect((await post(d, `/patients/${pat.id}/encounters`)).json().error).toBe('relationship_ended');
  });

  it('discarding a draft hides it; signed encounters cannot be discarded', async () => {
    const { d, pat } = await setup();
    const e = await newEncounter(d, pat.id);
    expect((await ctx.app.inject({ method: 'DELETE', url: `/encounters/${e.id}`, headers: d.headers })).statusCode).toBe(204);
    expect((await get(d, `/encounters/${e.id}`)).statusCode).toBe(404);
    expect((await get(d, `/patients/${pat.id}/encounters`)).json()).toHaveLength(0);
    const s = await signed(d, pat.id);
    expect((await ctx.app.inject({ method: 'DELETE', url: `/encounters/${s.id}`, headers: d.headers })).statusCode).toBe(409);
  });
});

describe('starting a consultation (F04-6)', () => {
  it('opens a linked draft encounter once; a discarded one can be recreated', async () => {
    const { d, pat } = await setup();
    await ctx.app.inject({ method: 'PATCH', url: '/workspace/settings', headers: d.headers, payload: { workingHours: Object.fromEntries(['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'].map((x) => [x, [{ start: '00:00', end: '23:59' }]])) } });
    const a = (await post(d, '/appointments/walk-in', { patientId: pat.id })).json();
    expect(a.encounterId).toBeNull();
    const started = (await post(d, `/appointments/${a.id}/start`)).json();
    expect(started.encounterId).toBeTruthy();
    const e = (await get(d, `/encounters/${started.encounterId}`)).json();
    expect(e).toMatchObject({ status: 'draft', appointmentId: a.id });
    expect((await post(d, `/patients/${pat.id}/encounters`, { appointmentId: a.id })).json().error).toBe('encounter_exists');
    await ctx.app.inject({ method: 'DELETE', url: `/encounters/${e.id}`, headers: d.headers });
    expect((await post(d, `/patients/${pat.id}/encounters`, { appointmentId: a.id })).statusCode).toBe(201);
  });
});

describe('vitals (F05-3)', () => {
  it('nurses record attributed vitals on a draft; doctors see them inside the encounter', async () => {
    const { d, pat } = await setup();
    const nurse = await staffOf(d, '+201000000003', 'nurse');
    const e = await newEncounter(d, pat.id);
    const o = await post(nurse, `/encounters/${e.id}/observations`, { kind: 'systolic_bp', value: 128 });
    expect(o.statusCode).toBe(201);
    expect(o.json()).toMatchObject({ kind: 'systolic_bp', value: 128, unit: 'mmHg', recordedRole: 'nurse', voided: false });
    const full = (await get(d, `/encounters/${e.id}`)).json();
    expect(full.observations).toHaveLength(1);
    expect(full.observations[0].recordedBy).toBe(nurse.user.id);
  });

  it('rejects implausible values and receptionists', async () => {
    const { d, pat } = await setup();
    const rec = await staffOf(d, '+201000000002', 'receptionist');
    const e = await newEncounter(d, pat.id);
    expect((await post(d, `/encounters/${e.id}/observations`, { kind: 'weight_kg', value: 700 })).json().error).toBe('out_of_range');
    expect((await post(d, `/encounters/${e.id}/observations`, { kind: 'pulse', value: 70 })).statusCode).toBe(400);
    expect((await post(rec, `/encounters/${e.id}/observations`, { kind: 'weight_kg', value: 70 })).statusCode).toBe(403);
  });

  it('voiding keeps the row; nurses can void only their own entries', async () => {
    const { d, pat } = await setup();
    const nurse = await staffOf(d, '+201000000003', 'nurse');
    const e = await newEncounter(d, pat.id);
    const mine = (await post(nurse, `/encounters/${e.id}/observations`, { kind: 'heart_rate', value: 80 })).json();
    const docs = (await post(d, `/encounters/${e.id}/observations`, { kind: 'heart_rate', value: 90 })).json();
    expect((await post(nurse, `/encounters/${e.id}/observations/${docs.id}/void`, { reason: 'typo' })).statusCode).toBe(403);
    expect((await post(nurse, `/encounters/${e.id}/observations/${mine.id}/void`, { reason: 'wrong patient' })).statusCode).toBe(200);
    expect((await post(d, `/encounters/${e.id}/observations/${mine.id}/void`, { reason: 'again' })).statusCode).toBe(409);
    const obs = (await get(d, `/encounters/${e.id}`)).json().observations;
    expect(obs).toHaveLength(2);
    expect(obs.find((o: { id: string }) => o.id === mine.id)).toMatchObject({ voided: true, voidReason: 'wrong patient' });
  });

  it('are locked once the encounter is signed', async () => {
    const { d, pat } = await setup();
    const s = await signed(d, pat.id);
    expect((await post(d, `/encounters/${s.id}/observations`, { kind: 'weight_kg', value: 70 })).json().error).toBe('encounter_signed');
  });

  it('trend lists non-voided points across encounters, only for this clinic', async () => {
    const { d, pat } = await setup();
    for (const w of [72, 70, 69]) {
      const e = await newEncounter(d, pat.id);
      await post(d, `/encounters/${e.id}/observations`, { kind: 'weight_kg', value: w });
      if (w === 70) {
        const o = (await get(d, `/encounters/${e.id}`)).json().observations[0];
        await post(d, `/encounters/${e.id}/observations/${o.id}/void`, { reason: 'mis-scaled' });
      }
      await ctx.pool.query('select pg_sleep(0.01)');
    }
    const t = (await get(d, `/patients/${pat.id}/observations?kind=weight_kg`)).json();
    expect(t.unit).toBe('kg');
    expect(t.points.map((p: { value: number }) => p.value)).toEqual([72, 69]);
    const other = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000009');
    expect((await get(other, `/patients/${pat.id}/observations?kind=weight_kg`)).statusCode).toBe(404);
  });
});

describe('signing and immutability (RULE-002)', () => {
  it('needs the current revision and a chief complaint', async () => {
    const { d, pat } = await setup();
    const e = await newEncounter(d, pat.id);
    expect((await post(d, `/encounters/${e.id}/sign`, { revision: 1 })).json().error).toBe('incomplete');
    await patch(d, `/encounters/${e.id}`, { revision: 1, chiefComplaint: 'Pain' });
    expect((await post(d, `/encounters/${e.id}/sign`, { revision: 1 })).json().error).toBe('revision_conflict');
    const ok = await post(d, `/encounters/${e.id}/sign`, { revision: 2 });
    expect(ok.json()).toMatchObject({ status: 'signed', currentVersion: 1 });
    expect(ok.json().signedAt).toBeTruthy();
  });

  it('signed encounters reject draft edits and even direct database edits', async () => {
    const { d, pat } = await setup();
    const s = await signed(d, pat.id);
    expect((await patch(d, `/encounters/${s.id}`, { revision: s.revision, plan: 'Sneaky' })).json().error).toBe('encounter_signed');
    await expect(ctx.pool.query(`update encounter_versions set plan = 'x' where encounter_id = $1`, [s.id])).rejects.toThrow(/immutable/);
    await expect(ctx.pool.query(`delete from encounter_versions where encounter_id = $1`, [s.id])).rejects.toThrow(/cannot be deleted/);
  });
});

describe('amendments (F05-5)', () => {
  it('creates a new version with a reason and preserves the original', async () => {
    const { d, pat } = await setup();
    const s = await signed(d, pat.id);
    const a = await post(d, `/encounters/${s.id}/amend`, { baseVersion: 1, reason: 'Corrected diagnosis', changes: { diagnosis: 'Pneumonia' } });
    expect(a.statusCode).toBe(200);
    expect(a.json()).toMatchObject({ currentVersion: 2, content: { diagnosis: 'Pneumonia', chiefComplaint: 'Cough for 3 days' }, version: { version: 2, amendmentReason: 'Corrected diagnosis', changedFields: ['diagnosis'] } });
    const versions = (await get(d, `/encounters/${s.id}/versions`)).json();
    expect(versions.map((v: { version: number }) => v.version)).toEqual([1, 2]);
    expect(versions[0].content.diagnosis).toBe('Acute bronchitis');
    expect(versions[1].content.diagnosis).toBe('Pneumonia');
  });

  it('requires a reason, a real change, the latest version, and a signed encounter', async () => {
    const { d, pat } = await setup();
    const s = await signed(d, pat.id);
    const amend = (p: Record<string, unknown>) => post(d, `/encounters/${s.id}/amend`, p);
    expect((await amend({ baseVersion: 1, changes: { plan: 'x' } })).statusCode).toBe(400);
    expect((await amend({ baseVersion: 1, reason: 'ab', changes: { plan: 'x' } })).statusCode).toBe(400);
    expect((await amend({ baseVersion: 1, reason: 'No-op edit', changes: { plan: 'Rest and fluids' } })).json().error).toBe('no_changes');
    expect((await amend({ baseVersion: 1, reason: 'Unknown field', changes: { signedAt: 'now' } })).statusCode).toBe(400);
    await amend({ baseVersion: 1, reason: 'First fix', changes: { plan: 'New plan' } });
    expect((await amend({ baseVersion: 1, reason: 'Stale fix', changes: { plan: 'Other' } })).json().error).toBe('version_conflict');
    const draft = await newEncounter(d, pat.id);
    expect((await post(d, `/encounters/${draft.id}/amend`, { baseVersion: 1, reason: 'On a draft', changes: { plan: 'x' } })).json().error).toBe('invalid_state');
  });

  it('audits only field names and versions, never clinical text', async () => {
    const { d, pat } = await setup();
    const s = await signed(d, pat.id);
    await post(d, `/encounters/${s.id}/amend`, { baseVersion: 1, reason: 'Corrected', changes: { diagnosis: 'Pneumonia' } });
    await get(d, `/encounters/${s.id}`);
    const log = (await get(d, '/workspace/audit')).json();
    const actions = log.map((l: { action: string }) => l.action);
    expect(actions).toEqual(expect.arrayContaining(['encounter.created', 'encounter.signed', 'encounter.amended', 'encounter.viewed']));
    const text = JSON.stringify(log);
    for (const secret of ['bronchitis', 'Pneumonia', 'Cough', 'TB screen', 'Smoker', 'Corrected']) expect(text).not.toContain(secret);
    expect(log.find((l: { action: string }) => l.action === 'encounter.amended').metadata).toEqual({ version: 2, changedFields: ['diagnosis'] });
    expect((await verifyChain(ctx.pool, d.workspaceId)).valid).toBe(true);
  });
});

describe('private notes (F05-2)', () => {
  it('are visible to the doctor only: never to nurses, in any version', async () => {
    const { d, pat } = await setup();
    const nurse = await staffOf(d, '+201000000003', 'nurse');
    const s = await signed(d, pat.id);
    await post(d, `/encounters/${s.id}/amend`, { baseVersion: 1, reason: 'Added note', changes: { privateNotes: 'Second secret' } });

    const asDoctor = (await get(d, `/encounters/${s.id}`)).json();
    expect(asDoctor.content.privateNotes).toBe('Second secret');
    const asNurse = await get(nurse, `/encounters/${s.id}`);
    expect(asNurse.statusCode).toBe(200);
    expect(asNurse.json().content).not.toHaveProperty('privateNotes');
    expect(asNurse.json().content.diagnosis).toBe('Acute bronchitis');
    const versions = JSON.stringify((await get(nurse, `/encounters/${s.id}/versions`)).json());
    expect(versions).not.toContain('secret');
    expect(versions).not.toContain('TB screen');
    expect(asNurse.body).not.toContain('TB screen');
  });

  it('a nurse with clinical.read denied cannot read encounters at all', async () => {
    const { d, pat } = await setup();
    const nurse = await staffOf(d, '+201000000003', 'nurse');
    const s = await signed(d, pat.id);
    const m = (await get(d, '/workspace/members')).json().find((x: { role: string }) => x.role === 'nurse');
    await patch(d, `/workspace/members/${m.id}`, { deniedPermissions: ['clinical.read'] });
    expect((await get(nurse, `/encounters/${s.id}`)).statusCode).toBe(403);
  });
});

describe('publishing to the patient (F05-10)', () => {
  async function patientSession() {
    const p = await login(ctx.app, '+201111111111');
    await post(p, '/patient/claim');
    return p;
  }

  it('shows only the published summary, never history or private notes; unpublished is invisible', async () => {
    const { d, pat } = await setup();
    const pt = await patientSession();
    const s = await signed(d, pat.id, { chiefComplaint: 'Cough', diagnosis: 'Bronchitis', plan: 'Rest', history: 'Smoker', privateNotes: 'TB?', prescriptions: [{ medication: 'Amoxicillin', dose: '500 mg' }] });
    expect((await get(pt, '/patient/encounters')).json()).toHaveLength(0);
    expect((await get(pt, `/patient/encounters/${s.id}`)).statusCode).toBe(404);

    const pub = await post(d, `/encounters/${s.id}/publish`);
    expect(pub.json()).toMatchObject({ publishedVersion: 1 });

    const list = (await get(pt, '/patient/encounters')).json();
    expect(list).toHaveLength(1);
    expect(list[0]).toMatchObject({ clinicName: 'Test Clinic', doctorName: 'Dr Test', chiefComplaint: 'Cough', diagnosis: 'Bronchitis', plan: 'Rest' });
    const one = await get(pt, `/patient/encounters/${s.id}`);
    expect(one.json().prescriptions[0].medication).toBe('Amoxicillin');
    expect(one.body).not.toContain('Smoker');
    expect(one.body).not.toContain('TB?');

    await post(d, `/encounters/${s.id}/unpublish`);
    expect((await get(pt, '/patient/encounters')).json()).toHaveLength(0);
  });

  it('includes non-voided vitals recorded on the encounter', async () => {
    const { d, pat } = await setup();
    const pt = await patientSession();
    const e = await newEncounter(d, pat.id);
    await post(d, `/encounters/${e.id}/observations`, { kind: 'weight_kg', value: 70 });
    const bad = (await post(d, `/encounters/${e.id}/observations`, { kind: 'weight_kg', value: 7 })).json();
    await post(d, `/encounters/${e.id}/observations/${bad.id}/void`, { reason: 'typo' });
    await patch(d, `/encounters/${e.id}`, { revision: 1, chiefComplaint: 'Check' });
    await post(d, `/encounters/${e.id}/sign`, { revision: 2 });
    await post(d, `/encounters/${e.id}/publish`);
    const vitals = (await get(pt, `/patient/encounters/${e.id}`)).json().vitals;
    expect(vitals.map((v: { value: number }) => v.value)).toEqual([70]);
  });

  it('keeps showing the published version after an amendment until the doctor republishes', async () => {
    const { d, pat } = await setup();
    const pt = await patientSession();
    const s = await signed(d, pat.id);
    await post(d, `/encounters/${s.id}/publish`);
    await post(d, `/encounters/${s.id}/amend`, { baseVersion: 1, reason: 'Fix', changes: { diagnosis: 'Pneumonia' } });
    expect((await get(pt, `/patient/encounters/${s.id}`)).json().diagnosis).toBe('Acute bronchitis');
    await post(d, `/encounters/${s.id}/publish`);
    expect((await get(pt, `/patient/encounters/${s.id}`)).json().diagnosis).toBe('Pneumonia');
  });

  it('drafts cannot be published, and other patients cannot read someone else\'s record', async () => {
    const { d, pat } = await setup();
    const e = await newEncounter(d, pat.id);
    expect((await post(d, `/encounters/${e.id}/publish`)).json().error).toBe('invalid_state');
    const s = await signed(d, pat.id);
    await post(d, `/encounters/${s.id}/publish`);
    const stranger = await login(ctx.app, '+201999999999');
    await post(stranger, '/patient/claim');
    expect((await get(stranger, `/patient/encounters/${s.id}`)).statusCode).toBe(404);
    expect((await get(stranger, '/patient/encounters')).json()).toHaveLength(0);
  });

  it('patients keep access to published records after the relationship ends', async () => {
    const { d, pat } = await setup();
    const pt = await patientSession();
    const s = await signed(d, pat.id);
    await post(d, `/encounters/${s.id}/publish`);
    await post(d, `/patients/${pat.id}/end`);
    expect((await get(pt, '/patient/encounters')).json()).toHaveLength(1);
  });
});

describe('isolation between clinics (RULE-003)', () => {
  it('another clinic cannot read or change any part of an encounter', async () => {
    const { d, pat } = await setup();
    const e = await newEncounter(d, pat.id);
    const other = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000009');
    for (const [m, url, body] of [
      ['GET', `/encounters/${e.id}`],
      ['GET', `/encounters/${e.id}/versions`],
      ['PATCH', `/encounters/${e.id}`, { revision: 1, plan: 'x' }],
      ['POST', `/encounters/${e.id}/sign`, { revision: 1 }],
      ['POST', `/encounters/${e.id}/observations`, { kind: 'weight_kg', value: 70 }],
      ['POST', `/encounters/${e.id}/publish`, {}],
      ['GET', `/encounters/${e.id}/prescription`],
      ['GET', `/patients/${pat.id}/encounters`],
    ] as [string, string, object?][]) {
      const r = await ctx.app.inject({ method: m as 'GET', url, headers: other.headers, payload: body });
      expect([404, 200], `${m} ${url}`).toContain(r.statusCode);
      if (r.statusCode === 200) expect(r.json()).toEqual([]); // list of own (empty) encounters
    }
    expect((await get(d, `/encounters/${e.id}`)).statusCode).toBe(200);
  });

  it('a second doctor-role user in the same clinic cannot edit another author\'s draft', async () => {
    const { d, pat } = await setup();
    const e = await newEncounter(d, pat.id);
    await ctx.pool.query('update encounters set author_id = $2 where id = $1', [e.id, (await login(ctx.app, '+201555555555')).user.id]);
    expect((await patch(d, `/encounters/${e.id}`, { revision: 1, plan: 'x' })).statusCode).toBe(403);
    expect((await post(d, `/encounters/${e.id}/sign`, { revision: 1 })).statusCode).toBe(403);
  });
});

describe('prescription output (F05-7)', () => {
  it('returns a printable payload for signed encounters with prescriptions', async () => {
    const { d, pat } = await setup();
    const none = await signed(d, pat.id, { chiefComplaint: 'Check-up' });
    expect((await get(d, `/encounters/${none.id}/prescription`)).statusCode).toBe(404);
    const draft = await newEncounter(d, pat.id);
    expect((await get(d, `/encounters/${draft.id}/prescription`)).json().error).toBe('invalid_state');

    const s = await signed(d, pat.id, { chiefComplaint: 'Cough', prescriptions: [{ medication: 'Amoxicillin', dose: '500 mg', frequency: '3x daily', duration: '7 days' }] });
    const rx = (await get(d, `/encounters/${s.id}/prescription`)).json();
    expect(rx).toMatchObject({
      clinic: 'Test Clinic',
      doctor: { fullName: 'Dr Test', licenseNumber: 'LIC-123' },
      patient: { fullName: 'Mona Hassan', dateOfBirth: '1990-05-01', patientNumber: 1 },
      items: [{ medication: 'Amoxicillin', dose: '500 mg', frequency: '3x daily', duration: '7 days' }],
    });
    const rec = await staffOf(d, '+201000000002', 'receptionist');
    expect((await get(rec, `/encounters/${s.id}/prescription`)).statusCode).toBe(403);
  });
});
