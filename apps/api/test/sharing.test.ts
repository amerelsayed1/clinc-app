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

type H = { headers: Record<string, string> };
const call = (method: 'GET' | 'POST' | 'PATCH' | 'DELETE', s: H, url: string, payload?: Record<string, unknown>) => ctx.app.inject({ method, url, headers: s.headers, payload });
const post = (s: H, url: string, p: Record<string, unknown> = {}) => call('POST', s, url, p);
const get = (s: H, url: string) => call('GET', s, url);
const del = (s: H, url: string) => call('DELETE', s, url);

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

/** Doctor A treats the patient and publishes a signed consultation; Doctor B is an unrelated verified clinician. */
async function world() {
  const a = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
  const b = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000002');
  const relA = (await post(a, '/patients', { phone: '+201111111111', fullName: 'Mona Hassan' })).json();
  const pt = await login(ctx.app, '+201111111111');
  await post(pt, '/patient/claim');
  await post(pt, `/patient/relationships/${relA.id}/accept`).catch(() => undefined);
  const e = (await post(a, `/patients/${relA.id}/encounters`)).json();
  const saved = await call('PATCH', a, `/encounters/${e.id}`, { revision: e.revision, chiefComplaint: 'Cough', diagnosis: 'Bronchitis', plan: 'Rest', privateNotes: 'SECRET NOTE', history: 'SECRET HISTORY' });
  await post(a, `/encounters/${e.id}/sign`, { revision: saved.json().revision });
  await post(a, `/encounters/${e.id}/publish`);
  const doc = await uploadAsPatient(pt);
  return { a, b, pt, relA, enc: e.id as string, doc: doc.id as string };
}
/** Doctor registers the patient; the patient accepts the invitation. */
async function connect(doc: H, pt: H, fullName = 'Mona H') {
  const rel = (await post(doc, '/patients', { phone: '+201111111111', fullName })).json();
  const mine = (await get(pt, '/patient/relationships')).json() as { id: string; status: string }[];
  for (const r of mine.filter((x) => x.status === 'invited')) await post(pt, `/patient/relationships/${r.id}/accept`);
  return rel;
}
const grantTo = (pt: H, body: Record<string, unknown>) => post(pt, '/patient/grants', { recipient: { doctorPhone: '+201000000002' }, acknowledgeRetention: true, ...body });

describe('patient-initiated grants', () => {
  it('Doctor B sees nothing before a grant and exactly the granted items after', async () => {
    const { b, pt, doc } = await world();
    expect((await get(b, '/shared-with-me')).json()).toEqual([]);
    const g = await grantTo(pt, { scope: { categories: ['lab_result'] }, days: 7, purpose: 'Second opinion' });
    expect(g.statusCode).toBe(201);
    const list = (await get(b, '/shared-with-me')).json();
    expect(list).toHaveLength(1);
    const items = (await get(b, `/shared-with-me/${list[0].id}/items`)).json();
    expect(items.map((i: { id: string }) => i.id)).toEqual([doc]);
    expect(items[0]).toMatchObject({ provenance: 'patient_submitted_unverified' });
  });

  it('never exposes private notes or history in a shared consultation, and logs each view for the patient', async () => {
    const { b, pt, enc } = await world();
    const g = (await grantTo(pt, { scope: { categories: ['encounters'] }, days: 7, acknowledgeSensitive: true })).json();
    const view = await get(b, `/shared-with-me/${g.id}/encounters/${enc}`);
    expect(view.statusCode).toBe(200);
    const text = JSON.stringify(view.json());
    expect(text).not.toContain('SECRET');
    expect(view.json()).toMatchObject({ chiefComplaint: 'Cough', diagnosis: 'Bronchitis', provenance: 'clinician_authored' });
    const log = (await get(pt, '/patient/access-log')).json();
    expect(log).toHaveLength(1);
    expect(log[0]).toMatchObject({ itemType: 'encounter', itemId: enc, grantId: g.id });
  });

  it('items outside the scope are invisible to the recipient', async () => {
    const { b, pt, enc } = await world();
    const g = (await grantTo(pt, { scope: { categories: ['lab_result'] } })).json();
    expect((await get(b, `/shared-with-me/${g.id}/encounters/${enc}`)).statusCode).toBe(404);
  });

  it('a specific-item grant covers only that item', async () => {
    const { b, pt, doc } = await world();
    const other = await uploadAsPatient(pt, 'imaging', 'X-ray');
    const g = (await grantTo(pt, { scope: { items: [{ type: 'document', id: doc }] } })).json();
    const items = (await get(b, `/shared-with-me/${g.id}/items`)).json();
    expect(items.map((i: { id: string }) => i.id)).toEqual([doc]);
    expect((await get(b, `/shared-with-me/${g.id}/documents/${other.id}`)).statusCode).toBe(404);
  });

  it('applies the date range to category scopes', async () => {
    const { b, pt } = await world();
    const g = (await grantTo(pt, { scope: { categories: ['lab_result'], from: '2001-01-01', to: '2001-12-31' } })).json();
    expect((await get(b, `/shared-with-me/${g.id}/items`)).json()).toEqual([]);
  });

  it('revocation blocks the next request immediately, including file links already issued', async () => {
    const { b, pt, doc } = await world();
    const g = (await grantTo(pt, { scope: { categories: ['lab_result'] } })).json();
    const link = (await get(b, `/shared-with-me/${g.id}/documents/${doc}/pages/1/link`)).json();
    expect((await ctx.app.inject({ method: 'GET', url: link.path })).statusCode).toBe(200);
    expect((await del(pt, `/patient/grants/${g.id}`)).statusCode).toBe(200);
    expect((await ctx.app.inject({ method: 'GET', url: link.path })).statusCode).toBe(403);
    expect((await get(b, `/shared-with-me/${g.id}/items`)).statusCode).toBe(404);
    expect((await get(b, '/shared-with-me')).json()).toEqual([]);
  });

  it('expiry blocks access and is recorded once in the audit chain', async () => {
    const { a, b, pt } = await world();
    const g = (await grantTo(pt, { scope: { categories: ['lab_result'] } })).json();
    await ctx.pool.query(`update sharing_grants set expires_at = now() - interval '1 minute'`);
    expect((await get(b, `/shared-with-me/${g.id}/items`)).statusCode).toBe(404);
    expect((await get(pt, '/patient/grants')).json()[0].status).toBe('expired');
    await get(pt, '/patient/grants');
    const n = (await ctx.pool.query(`select count(*)::int as n from audit_log where action = 'grant.expired'`)).rows[0].n;
    expect(n).toBe(1);
    const ws = (await ctx.pool.query('select id from workspaces order by created_at limit 2')).rows;
    for (const w of ws) expect((await verifyChain(ctx.pool, w.id)).valid).toBe(true);
    void a;
  });

  it('enforces retention acknowledgement, max duration and the stricter sensitive rules', async () => {
    const { pt } = await world();
    const base = { recipient: { doctorPhone: '+201000000002' }, scope: { categories: ['lab_result'] } };
    expect((await post(pt, '/patient/grants', base)).json().error).toBe('retention_ack_required');
    expect((await grantTo(pt, { scope: base.scope, days: 91 })).statusCode).toBe(400);
    expect((await grantTo(pt, { scope: { categories: ['encounters'] }, days: 7 })).json().error).toBe('sensitive_ack_required');
    expect((await grantTo(pt, { scope: { categories: ['encounters'] }, days: 30, acknowledgeSensitive: true })).json().error).toBe('duration_too_long');
  });

  it('refuses unknown recipients, unverified doctors, and items the patient cannot share', async () => {
    const { pt, enc } = await world();
    expect((await post(pt, '/patient/grants', { recipient: { doctorPhone: '+201999999999' }, scope: { categories: ['report'] }, acknowledgeRetention: true })).statusCode).toBe(404);
    await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000003', false);
    expect((await post(pt, '/patient/grants', { recipient: { doctorPhone: '+201000000003' }, scope: { categories: ['report'] }, acknowledgeRetention: true })).statusCode).toBe(404);
    expect((await grantTo(pt, { scope: { items: [{ type: 'document', id: enc }] } })).json().error).toBe('invalid_scope');
    expect((await grantTo(pt, { scope: { categories: ['administrative'] } })).statusCode).toBe(400);
  });

  it('other patients cannot see or revoke someone else\'s grants', async () => {
    const { pt } = await world();
    const g = (await grantTo(pt, { scope: { categories: ['lab_result'] } })).json();
    const stranger = await login(ctx.app, '+201555555555');
    await post(stranger, '/patient/claim');
    expect((await get(stranger, '/patient/grants')).json()).toEqual([]);
    expect((await del(stranger, `/patient/grants/${g.id}`)).statusCode).toBe(404);
  });

  it('a receptionist in the recipient clinic cannot read shared records', async () => {
    const { b, pt } = await world();
    await grantTo(pt, { scope: { categories: ['lab_result'] } });
    const inv = (await post(b, '/workspace/invitations', { phone: '+201000000077', role: 'receptionist' })).json();
    const rec = await login(ctx.app, '+201000000077');
    await post(rec, '/invitations/accept', { code: inv.code });
    expect((await get(rec, '/shared-with-me')).statusCode).toBe(403);
  });

  it('shared files are served from the grant only and each view lands in the access log', async () => {
    const { b, pt, doc } = await world();
    const g = (await grantTo(pt, { scope: { categories: ['lab_result'] } })).json();
    const link = (await get(b, `/shared-with-me/${g.id}/documents/${doc}/pages/1/link`)).json();
    const file = await ctx.app.inject({ method: 'GET', url: link.path });
    expect(file.statusCode).toBe(200);
    expect(file.rawPayload.equals(jpeg)).toBe(true);
    const log = (await get(pt, '/patient/access-log')).json();
    expect(log[0]).toMatchObject({ itemType: 'document', itemId: doc });
    // Doctor B has no ordinary clinic route to the same document.
    expect((await get(b, `/documents/${doc}`)).statusCode).toBe(404);
  });
});

describe('doctor-initiated access requests', () => {
  const request = (a: H, relId: string, extra: Record<string, unknown> = {}) =>
    post(a, `/patients/${relId}/access-requests`, { scope: { categories: ['lab_result', 'imaging'] }, purpose: 'Pre-operative review', days: 14, ...extra });

  it('patient approves a narrowed request and a grant is created; cannot widen', async () => {
    const { a, b, pt, relA } = await world();
    // Doctor B needs an active relationship with the patient to ask.
    const relB = await connect(b, pt);
    const q = await request(b, relB.id);
    expect(q.statusCode).toBe(201);
    const pending = (await get(pt, '/patient/access-requests')).json();
    expect(pending[0]).toMatchObject({ status: 'pending', purpose: 'Pre-operative review' });
    const widen = await post(pt, `/patient/access-requests/${pending[0].id}/approve`, { scope: { categories: ['lab_result', 'report'] }, acknowledgeRetention: true });
    expect(widen.json().error).toBe('scope_widened');
    const ok = await post(pt, `/patient/access-requests/${pending[0].id}/approve`, { scope: { categories: ['lab_result'] }, days: 30, acknowledgeRetention: true });
    expect(ok.statusCode).toBe(200);
    expect(ok.json().scope).toEqual({ categories: ['lab_result'] });
    // The grant length is capped at what was asked for.
    const days = (new Date(ok.json().expiresAt).getTime() - Date.now()) / 86_400_000;
    expect(days).toBeLessThanOrEqual(14);
    expect((await get(b, '/shared-with-me')).json()).toHaveLength(1);
    void a;
    void relA;
  });

  it('denial grants nothing; only one request may be pending', async () => {
    const { b, pt } = await world();
    const relB = await connect(b, pt);
    await request(b, relB.id);
    expect((await request(b, relB.id)).json().error).toBe('request_pending');
    const id = (await get(pt, '/patient/access-requests')).json()[0].id;
    expect((await post(pt, `/patient/access-requests/${id}/deny`)).statusCode).toBe(200);
    expect((await get(b, '/shared-with-me')).json()).toEqual([]);
    expect((await post(pt, `/patient/access-requests/${id}/approve`, { acknowledgeRetention: true })).statusCode).toBe(409);
    expect((await request(b, relB.id)).statusCode).toBe(201);
  });

  it('needs an active relationship, a registered patient and a verified doctor', async () => {
    const { a, b, relA } = await world();
    expect((await request(b, relA.id)).statusCode).toBe(404); // not B's patient
    const unregistered = (await post(a, '/patients', { phone: '+201222222222', fullName: 'Not Registered' })).json();
    expect((await request(a, unregistered.id)).json().error).toBe('patient_not_registered');
    const u = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000005', false);
    const rel = await connect(u, (await login(ctx.app, '+201111111111')));
    expect((await request(u, rel.id)).statusCode).toBe(403);
  });

  it('sensitive requests are capped and need explicit acknowledgement on approval', async () => {
    const { b, pt } = await world();
    const relB = await connect(b, pt);
    expect((await request(b, relB.id, { scope: { categories: ['encounters'] }, days: 30 })).json().error).toBe('duration_too_long');
    await request(b, relB.id, { scope: { categories: ['encounters'] }, days: 7 });
    const q = (await get(pt, '/patient/access-requests')).json()[0];
    expect(q.sensitive).toBe(true);
    expect((await post(pt, `/patient/access-requests/${q.id}/approve`, { acknowledgeRetention: true })).json().error).toBe('sensitive_ack_required');
    expect((await post(pt, `/patient/access-requests/${q.id}/approve`, { acknowledgeRetention: true, acknowledgeSensitive: true })).statusCode).toBe(200);
  });

  it('doctor can cancel a pending request', async () => {
    const { b, pt } = await world();
    const relB = await connect(b, pt);
    const q = (await request(b, relB.id)).json();
    expect((await del(b, `/access-requests/${q.id}`)).statusCode).toBe(200);
    expect((await get(pt, '/patient/access-requests')).json()[0].status).toBe('cancelled');
  });
});
