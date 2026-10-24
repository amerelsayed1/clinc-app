import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
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
const del = (s: H, url: string) => call('DELETE', s, url);

interface Entry {
  type: string;
  id: string;
  refType: string;
  date: string;
  title: string;
  summary: string;
  author: { id: string; name: string } | null;
  source: { kind: string; workspaceId: string | null; name: string | null };
  versionCount: number;
  amended: boolean;
  historyPath: string | null;
  verificationBadge: string;
  shared?: { sharedBy: string; via: string; grantId: string | null; expiresAt: string | null; originClinic: string | null; label: string };
}
const tl = async (s: H, rel: string, qs = '') => {
  const r = await get(s, `/patients/${rel}/timeline${qs ? `?${qs}` : ''}`);
  return { status: r.statusCode, items: (r.json().items ?? []) as Entry[], next: r.json().nextCursor as string | null };
};
const ptl = async (s: H, qs = '') => {
  const r = await get(s, `/patient/timeline${qs ? `?${qs}` : ''}`);
  return { status: r.statusCode, items: (r.json().items ?? []) as Entry[], next: r.json().nextCursor as string | null };
};

const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.from(`JFIF-${'x'.repeat(200)}`)]);
async function uploadAsPatient(s: H, category = 'lab_result', title = 'CBC') {
  const b = '----t';
  const body = Buffer.concat([
    Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="category"\r\n\r\n${category}\r\n--${b}\r\nContent-Disposition: form-data; name="title"\r\n\r\n${title}\r\n`),
    Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="file"; filename="a.jpg"\r\nContent-Type: image/jpeg\r\n\r\n`),
    jpeg,
    Buffer.from(`\r\n--${b}--\r\n`),
  ]);
  const r = await ctx.app.inject({ method: 'POST', url: '/patient/documents', headers: { ...s.headers, 'content-type': `multipart/form-data; boundary=${b}` }, payload: body });
  return r.json();
}

async function signedEncounter(d: H, rel: string, content: Record<string, unknown>, publish = true) {
  const e = (await post(d, `/patients/${rel}/encounters`)).json();
  const saved = await call('PATCH', d, `/encounters/${e.id}`, { revision: e.revision, ...content });
  await post(d, `/encounters/${e.id}/sign`, { revision: saved.json().revision });
  if (publish) await post(d, `/encounters/${e.id}/publish`);
  return e.id as string;
}

/** Doctor A treats the patient; Doctor B is another verified clinician who also has the patient registered. */
async function world() {
  const a = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
  const b = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000002');
  const relA = (await post(a, '/patients', { phone: '+201111111111', fullName: 'Mona Hassan' })).json();
  const relB = (await post(b, '/patients', { phone: '+201111111111', fullName: 'Mona H' })).json();
  const pt = await login(ctx.app, '+201111111111');
  await post(pt, '/patient/claim');
  await post(pt, `/patient/relationships/${relA.id}/accept`);
  await post(pt, `/patient/relationships/${relB.id}/accept`);
  const encA = await signedEncounter(a, relA.id, {
    chiefComplaint: 'Cough', diagnosis: 'Bronchitis', plan: 'Rest', privateNotes: 'SECRET NOTE', history: 'SECRET HISTORY',
    prescriptions: [{ medication: 'Amoxicillin', dose: '500mg' }],
  });
  const encB = await signedEncounter(b, relB.id, { chiefComplaint: 'Back pain', diagnosis: 'Strain', plan: 'Physio', privateNotes: 'B PRIVATE' });
  return { a, b, pt, relA: relA.id as string, relB: relB.id as string, encA, encB };
}
const grantToB = (pt: H, scope: Record<string, unknown>, extra: Record<string, unknown> = {}) =>
  post(pt, '/patient/grants', { recipient: { doctorPhone: '+201000000002' }, acknowledgeRetention: true, acknowledgeSensitive: true, days: 7, scope, ...extra });

describe('doctor timeline (F07-4)', () => {
  it('shows own signed encounter, prescription and vitals, never mixes in other clinics, and hides nothing the doctor may read', async () => {
    const { a, relA, encA } = await world();
    await ctx.pool.query(`insert into observations (workspace_id, care_relationship_id, encounter_id, kind, value, recorded_by, recorded_role) select workspace_id, care_relationship_id, id, 'weight_kg', 70, author_id, 'doctor' from encounters where id = $1`, [encA]);
    const { items } = await tl(a, relA);
    expect(items.map((i) => i.type).sort()).toEqual(['encounter', 'observation', 'prescription']);
    const obs = items.find((i) => i.type === 'observation')!;
    expect(obs.summary).toBe('Weight 70 kg');
    expect(items.find((i) => i.type === 'prescription')!.summary).toBe('Amoxicillin');
    expect(items.every((i) => i.source.kind === 'clinic' && !i.shared && i.verificationBadge === 'clinician_authored')).toBe(true);
    expect(JSON.stringify(items)).not.toContain('B PRIVATE');
  });

  it('receptionists get 403; nurses read but never match on private notes; unknown relationships are 404', async () => {
    const { a, relA } = await world();
    const mk = async (phone: string, role: 'nurse' | 'receptionist') => {
      const inv = (await post(a, '/workspace/invitations', { phone, role })).json();
      const s = await login(ctx.app, phone);
      await post(s, '/invitations/accept', { code: inv.code });
      return s;
    };
    const rec = await mk('+201000000050', 'receptionist');
    expect((await get(rec, `/patients/${relA}/timeline`)).statusCode).toBe(403);
    const nurse = await mk('+201000000051', 'nurse');
    expect((await tl(nurse, relA)).items.length).toBeGreaterThan(0);
    expect((await tl(nurse, relA, 'q=SECRET%20NOTE')).items).toHaveLength(0);
    expect((await tl(a, relA, 'q=SECRET%20NOTE')).items.map((i) => i.type)).toEqual(['encounter']); // the authoring doctor may search own private notes
    expect((await tl(a, '00000000-0000-4000-8000-000000000000')).status).toBe(404);
  });

  it('a doctor cannot read another clinic relationship even for the same patient', async () => {
    const { a, relB } = await world();
    expect((await tl(a, relB)).status).toBe(404);
  });

  it('the same patient as two doctors yields different entries; grants add marked entries; revocation removes them at once', async () => {
    const { a, b, pt, relA, relB, encA } = await world();
    const before = await tl(b, relB);
    expect(before.items.map((i) => i.title)).toEqual(['Back pain']);
    expect((await tl(a, relA)).items.some((i) => i.title === 'Back pain')).toBe(false);

    const doc = await uploadAsPatient(pt, 'lab_result', 'Lipid panel');
    const g = (await grantToB(pt, { items: [{ type: 'encounter', id: encA }, { type: 'document', id: doc.id }] })).json();
    const after = await tl(b, relB);
    const shared = after.items.filter((i) => i.shared);
    expect(shared.map((i) => `${i.type}:${i.title}`).sort()).toEqual(['document:Lipid panel', 'encounter:Cough', 'prescription:Prescription']);
    for (const s of shared) expect(s.shared).toMatchObject({ sharedBy: 'patient', via: 'grant', grantId: g.id });
    expect(shared.find((i) => i.type === 'encounter')!.shared).toMatchObject({ originClinic: 'Test Clinic' });
    expect(new Date(shared[0]!.shared!.expiresAt!).getTime()).toBeGreaterThan(Date.now());
    expect(after.items.some((i) => i.type === 'shared_notice')).toBe(true);
    // Shared consultation content is the published version: no history, no private notes.
    expect(JSON.stringify(after.items)).not.toContain('SECRET');
    // A still sees only its own records.
    expect((await tl(a, relA)).items.some((i) => i.shared || i.title === 'Lipid panel')).toBe(false);
    // Viewing shared content is recorded for the patient (F08-7).
    const log = (await get(pt, '/patient/access-log')).json() as { itemId: string }[];
    expect(log.map((l) => l.itemId).sort()).toEqual([encA, doc.id].sort());

    expect((await del(pt, `/patient/grants/${g.id}`)).statusCode).toBe(200);
    const gone = await tl(b, relB);
    expect(gone.items.map((i) => i.title)).toEqual(['Back pain']);
  });

  it('expired grants disappear without a sweep, and a category grant respects its date range', async () => {
    const { b, pt, relB } = await world();
    await uploadAsPatient(pt, 'lab_result', 'CBC');
    const g = (await grantToB(pt, { categories: ['lab_result'] })).json();
    expect((await tl(b, relB)).items.some((i) => i.title === 'CBC')).toBe(true);
    await ctx.pool.query(`update sharing_grants set expires_at = now() - interval '1 minute' where id = $1`, [g.id]);
    expect((await tl(b, relB)).items.some((i) => i.title === 'CBC' || i.type === 'shared_notice')).toBe(false);
    const g2 = (await grantToB(pt, { categories: ['lab_result'], from: '2001-01-01', to: '2001-12-31' })).json();
    expect(g2.id).toBeTruthy();
    expect((await tl(b, relB)).items.some((i) => i.title === 'CBC')).toBe(false);
  });

  it('search never reaches text outside the permitted scope', async () => {
    const { a, b, pt, relA, relB, encA } = await world();
    // B searching for A's consultation text finds nothing without a grant...
    for (const term of ['Bronchitis', 'Amoxicillin', 'Cough', 'SECRET']) expect((await tl(b, relB, `q=${term}`)).items).toHaveLength(0);
    // ...and with an encounter grant finds published text only, never history/private notes.
    await grantToB(pt, { items: [{ type: 'encounter', id: encA }] });
    expect((await tl(b, relB, 'q=Bronchitis')).items.map((i) => i.type)).toContain('encounter');
    expect((await tl(b, relB, 'q=Amoxicillin')).items.map((i) => i.type)).toContain('prescription');
    expect((await tl(b, relB, 'q=SECRET')).items).toHaveLength(0);
    expect((await tl(b, relB, 'q=B%20PRIVATE')).items.map((i) => i.type)).toEqual(['encounter']); // B's own private note
    // A does not find B's text.
    expect((await tl(a, relA, 'q=Strain')).items).toHaveLength(0);
    // Patient view: no private notes/history through search either.
    expect((await ptl(pt, 'q=SECRET')).items).toHaveLength(0);
    expect((await ptl(pt, 'q=B%20PRIVATE')).items).toHaveLength(0);
    expect((await ptl(pt, 'q=Bronchitis')).items.map((i) => i.type)).toContain('encounter');
    // LIKE wildcards in the query are literals.
    expect((await tl(a, relA, 'q=%25')).items).toHaveLength(0);
  });

  it('shows patient-sent uploads with a patient-submitted badge, reviewed once a clinician reviews them, and drops them when un-sent', async () => {
    const { a, pt, relA } = await world();
    const doc = await uploadAsPatient(pt, 'report', 'Home ECG');
    await post(pt, `/patient/documents/${doc.id}/send`, { relationshipId: relA });
    let e = (await tl(a, relA)).items.find((i) => i.id === doc.id)!;
    expect(e).toMatchObject({ verificationBadge: 'patient_submitted', source: { kind: 'patient' }, shared: { via: 'send', sharedBy: 'patient' } });
    await post(a, `/documents/${doc.id}/review`, { note: 'ok' });
    e = (await tl(a, relA)).items.find((i) => i.id === doc.id)!;
    expect(e.verificationBadge).toBe('reviewed');
    await del(pt, `/patient/documents/${doc.id}/send/${relA}`);
    expect((await tl(a, relA)).items.some((i) => i.id === doc.id)).toBe(false);
  });

  it('amended encounters show the version count and a history link, plus appointment and follow-up entries', async () => {
    const { a, relA, encA } = await world();
    const amended = await post(a, `/encounters/${encA}/amend`, { baseVersion: 1, reason: 'Typo fix', changes: { diagnosis: 'Acute bronchitis' } });
    expect(amended.statusCode).toBe(200);
    await ctx.pool.query(`insert into appointments (workspace_id, care_relationship_id, scheduled_at, duration_minutes, reason, status) select workspace_id, id, now() + interval '1 day', 15, 'Recheck chest', 'scheduled' from care_relationships where id = $1`, [relA]);
    const plan = (await ctx.pool.query(`insert into followup_plans (workspace_id, care_relationship_id, created_by, instructions, start_date) select workspace_id, id, created_by, 'Track temperature', current_date from care_relationships where id = $1 returning id, workspace_id`, [relA])).rows[0];
    const m = (await ctx.pool.query(`insert into followup_measurements (plan_id, kind, name, unit, frequency, interval_days) values ($1,'temperature_c','Temperature','C','daily',1) returning id`, [plan.id])).rows[0];
    await ctx.pool.query(`insert into followup_submissions (plan_id, measurement_id, workspace_id, care_relationship_id, patient_id, value, measured_at, created_by) select $1,$2,$3,r.id,r.patient_id,37.5,now(),p.user_id from care_relationships r join patients p on p.id = r.patient_id where r.id = $4`, [plan.id, m.id, plan.workspace_id, relA]);
    const { items } = await tl(a, relA);
    const enc = items.find((i) => i.type === 'encounter')!;
    expect(enc).toMatchObject({ amended: true, versionCount: 2, historyPath: `/encounters/${encA}/versions` });
    expect(items.find((i) => i.type === 'appointment')).toMatchObject({ summary: 'Scheduled · Recheck chest' });
    const fu = items.filter((i) => i.type === 'followup');
    expect(fu.map((i) => i.title).sort()).toEqual(['Follow-up plan', 'Temperature: 37.5 C']);
    expect(fu.find((i) => i.refType === 'followup_submission')!.verificationBadge).toBe('patient_submitted');
    // The patient sees them too; follow-ups are never shared to other clinics.
    const p = await ptl((await world2Patient()));
    expect(p.items.some((i) => i.type === 'followup')).toBe(true);
  });
});

async function world2Patient() {
  return login(ctx.app, '+201111111111');
}

describe('patient timeline (F07-5)', () => {
  it('shows uploads and everything doctors published across clinics, never unpublished items or private content', async () => {
    const { a, pt, relA, encA, encB } = await world();
    const hiddenEnc = await signedEncounter(a, relA, { chiefComplaint: 'Unpublished visit', privateNotes: 'SECRET2' }, false);
    const up = await uploadAsPatient(pt, 'lab_result', 'My CBC');
    // A clinic document: visible only after publishing.
    const b = '----c';
    const upload = async (title: string) => {
      const body = Buffer.concat([
        Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="category"\r\n\r\nimaging\r\n--${b}\r\nContent-Disposition: form-data; name="title"\r\n\r\n${title}\r\n`),
        Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="file"; filename="a.jpg"\r\nContent-Type: image/jpeg\r\n\r\n`),
        jpeg,
        Buffer.from(`\r\n--${b}--\r\n`),
      ]);
      return (await ctx.app.inject({ method: 'POST', url: `/patients/${relA}/documents`, headers: { ...a.headers, 'content-type': `multipart/form-data; boundary=${b}` }, payload: body })).json();
    };
    const pubDoc = await upload('Chest X-ray');
    const privDoc = await upload('Draft imaging');
    await post(a, `/documents/${pubDoc.id}/publish`);
    const { items } = await ptl(pt);
    const ids = items.map((i) => i.id);
    expect(ids).toEqual(expect.arrayContaining([encA, encB, up.id, pubDoc.id]));
    expect(ids).not.toContain(hiddenEnc);
    expect(ids).not.toContain(privDoc.id);
    expect(JSON.stringify(items)).not.toMatch(/SECRET|B PRIVATE/);
    expect(new Set(items.map((i) => i.source.name))).toEqual(new Set(['Test Clinic', null]));
    expect(items.find((i) => i.id === up.id)).toMatchObject({ verificationBadge: 'patient_submitted', source: { kind: 'patient' } });
    expect(items.find((i) => i.id === encB && i.type === 'encounter')).toMatchObject({ verificationBadge: 'clinician_authored', author: { name: 'Dr Test' } });
  });

  it('is scoped to the caller: another patient sees nothing, an unclaimed user gets an empty list, and anonymous is rejected', async () => {
    const { pt } = await world();
    const other = await login(ctx.app, '+201222222222');
    expect((await ptl(other)).items).toEqual([]);
    await post(other, '/patient/claim');
    expect((await ptl(other)).items).toEqual([]);
    expect((await ptl(pt)).items.length).toBeGreaterThan(0);
    expect((await ctx.app.inject({ method: 'GET', url: '/patient/timeline' })).statusCode).toBe(401);
  });

  it('includes appointments only after the patient accepted, and lists grants the patient made', async () => {
    const { a, pt, relA, encA } = await world();
    await ctx.pool.query(`insert into appointments (workspace_id, care_relationship_id, scheduled_at, duration_minutes, reason, cancel_reason, status) select workspace_id, id, now() + interval '2 day', 15, 'Checkup', 'INTERNAL CANCEL', 'cancelled' from care_relationships where id = $1`, [relA]);
    await grantToB(pt, { items: [{ type: 'encounter', id: encA }] });
    const { items } = await ptl(pt);
    expect(items.find((i) => i.type === 'appointment')).toMatchObject({ summary: 'Cancelled · Checkup' });
    expect(JSON.stringify(items)).not.toContain('INTERNAL CANCEL');
    expect(items.find((i) => i.type === 'shared_notice')!.title).toContain('You shared records with');
    void a;
  });
});

describe('filters and pagination (F07-3, F07-7)', () => {
  async function seeded(n = 320) {
    const w = await world();
    // Spread N documents (with deliberate timestamp ties) over time.
    await ctx.pool.query(
      `insert into documents (patient_id, workspace_id, care_relationship_id, source, uploaded_by, uploader_role, category, title, notes, document_date, total_bytes)
       select r.patient_id, r.workspace_id, r.id, 'clinician', w.owner_id, 'doctor', (array['lab_result','imaging','report','other'])[1 + (g % 4)], 'Doc ' || g, case when g % 50 = 0 then 'needle ' || g else '' end, date '2024-01-01' + (g / 3), 100
         from generate_series(1, $2::int) g, care_relationships r join workspaces w on w.id = r.workspace_id where r.id = $1`,
      [w.relA, n],
    );
    return w;
  }

  it('pages through 300+ entries without gaps or duplicates in stable date-desc order', async () => {
    const { a, relA, pt } = await seeded();
    const all: Entry[] = [];
    let cursor: string | null = null;
    let pages = 0;
    do {
      const r: { items: Entry[]; next: string | null; status: number } = await tl(a, relA, `limit=37${cursor ? `&cursor=${cursor}` : ''}`);
      expect(r.status).toBe(200);
      all.push(...r.items);
      cursor = r.next;
      pages++;
    } while (cursor && pages < 50);
    expect(all.length).toBeGreaterThanOrEqual(320);
    expect(new Set(all.map((i) => `${i.type}:${i.id}`)).size).toBe(all.length);
    for (let i = 1; i < all.length; i++) expect(all[i - 1]!.date >= all[i]!.date).toBe(true);
    // Same through the patient endpoint (docs are unpublished, so only published items + uploads appear there).
    const p = await ptl(pt, 'limit=100');
    expect(p.items.length).toBeLessThanOrEqual(100);
    expect(p.status).toBe(200);
  });

  it('rejects malformed cursors and limits', async () => {
    const { a, relA } = await world();
    expect((await get(a, `/patients/${relA}/timeline?cursor=garbage`)).statusCode).toBe(400);
    expect((await get(a, `/patients/${relA}/timeline?limit=0`)).statusCode).toBe(400);
    expect((await get(a, `/patients/${relA}/timeline?limit=101`)).statusCode).toBe(400);
    expect((await get(a, `/patients/${relA}/timeline?type=bogus`)).statusCode).toBe(400);
  });

  it('filters by type, date range, source, doctor and text', async () => {
    const { a, b, pt, relA, relB, encA } = await seeded(60);
    const lab = await tl(a, relA, 'type=document&limit=100');
    expect(lab.items.every((i) => i.type === 'document')).toBe(true);
    expect((await tl(a, relA, 'type=encounter,prescription')).items.map((i) => i.type).sort()).toEqual(['encounter', 'prescription']);
    const ranged = await tl(a, relA, 'type=document&from=2024-01-05&to=2024-01-06&limit=100');
    expect(ranged.items.length).toBeGreaterThan(0);
    expect(ranged.items.every((i) => i.date >= '2024-01-05' && i.date < '2024-01-07')).toBe(true);
    expect((await tl(a, relA, 'q=needle&limit=100')).items.map((i) => i.title)).toEqual(['Doc 50']);
    // Search matches titles case-insensitively.
    expect((await tl(a, relA, 'q=DOC%2012&limit=100')).items.length).toBeGreaterThan(0);

    const doctorId = (await tl(a, relA, 'type=encounter')).items[0]!.author!.id;
    expect((await tl(a, relA, `doctor=${doctorId}&limit=100`)).items.length).toBeGreaterThan(0);
    expect((await tl(a, relA, `doctor=${(await tl(b, relB, 'type=encounter')).items[0]!.author!.id}`)).items).toHaveLength(0);

    // Source filters: own / shared / a specific workspace / patient.
    const doc = await uploadAsPatient(pt, 'report', 'Patient report');
    await grantToB(pt, { items: [{ type: 'encounter', id: encA }, { type: 'document', id: doc.id }] });
    const shared = await tl(b, relB, 'source=shared');
    expect(shared.items.length).toBeGreaterThan(0);
    expect(shared.items.every((i) => i.shared)).toBe(true);
    expect((await tl(b, relB, 'source=own')).items.every((i) => !i.shared && i.type !== 'shared_notice')).toBe(true);
    const wsA = (await ctx.pool.query('select workspace_id from care_relationships where id = $1', [relA])).rows[0].workspace_id;
    expect((await tl(b, relB, `source=${wsA}`)).items.every((i) => i.source.workspaceId === wsA)).toBe(true);
    expect((await tl(b, relB, 'source=patient')).items.map((i) => i.id)).toContain(doc.id);
    const pAll = await ptl(pt, 'type=document');
    expect(pAll.items.map((i) => i.id)).toContain(doc.id);
    expect((await ptl(pt, `source=${wsA}`)).items.every((i) => i.source.workspaceId === wsA)).toBe(true);
  });
});
