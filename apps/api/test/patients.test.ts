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
const patientPhone = '+201111111111';

const register = (d: { headers: Record<string, string> }, payload: Record<string, unknown>) =>
  ctx.app.inject({ method: 'POST', url: '/patients', headers: d.headers, payload });
const search = async (d: { headers: Record<string, string> }, qs = '') => (await ctx.app.inject({ method: 'GET', url: `/patients${qs}`, headers: d.headers })).json();

async function staffOf(d: Doctor, phone: string, role: 'nurse' | 'receptionist') {
  const inv = (await ctx.app.inject({ method: 'POST', url: '/workspace/invitations', headers: d.headers, payload: { phone, role } })).json();
  const s = await login(ctx.app, phone);
  await ctx.app.inject({ method: 'POST', url: '/invitations/accept', headers: s.headers, payload: { code: inv.code } });
  return s;
}

describe('registration and search', () => {
  it('registers a patient with a per-workspace patient number', async () => {
    const d1 = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    const d2 = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000002');
    const a = await register(d1, { phone: patientPhone, fullName: 'Mona Hassan', dateOfBirth: '1990-05-01', sex: 'female' });
    expect(a.statusCode).toBe(201);
    expect(a.json()).toMatchObject({ patientNumber: 1, status: 'active', fullName: 'Mona Hassan', dateOfBirth: '1990-05-01', hasAccount: false });
    expect((await register(d1, { phone: '+201111111112', fullName: 'Omar Ali' })).json().patientNumber).toBe(2);
    expect((await register(d2, { phone: '+201111111113', fullName: 'Sara Adel' })).json().patientNumber).toBe(1);
  });

  it('validates input', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    expect((await register(d, { phone: '0111', fullName: 'Mona' })).statusCode).toBe(400);
    expect((await register(d, { phone: patientPhone, fullName: 'M' })).statusCode).toBe(400);
    expect((await register(d, { phone: patientPhone, fullName: 'Mona', dateOfBirth: '2999-01-01' })).statusCode).toBe(400);
  });

  it('rejects the same phone twice in one clinic', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    await register(d, { phone: patientPhone, fullName: 'Mona Hassan' });
    const again = await register(d, { phone: patientPhone, fullName: 'Someone Else' });
    expect(again.statusCode).toBe(409);
    expect(again.json().error).toBe('already_registered');
  });

  it('searches by exact phone, patient number, and name substring', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    await register(d, { phone: patientPhone, fullName: 'Mona Hassan' });
    await register(d, { phone: '+201111111112', fullName: 'Omar Ali' });
    expect((await search(d, `?q=${encodeURIComponent(patientPhone)}`)).map((p: { fullName: string }) => p.fullName)).toEqual(['Mona Hassan']);
    expect(await search(d, `?q=${encodeURIComponent('+20111111')}`)).toHaveLength(0); // phone is exact, not prefix
    expect((await search(d, '?q=%232'))[0].fullName).toBe('Omar Ali');
    expect((await search(d, '?q=hass'))[0].fullName).toBe('Mona Hassan');
    expect(await search(d, '?q=%25')).toHaveLength(0); // wildcards are escaped
    expect(await search(d)).toHaveLength(2);
  });

  it('receptionists and nurses can register and search; denied permissions are enforced', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    const rec = await staffOf(d, '+201000000002', 'receptionist');
    expect((await register(rec, { phone: patientPhone, fullName: 'Mona Hassan' })).statusCode).toBe(201);
    const member = (await ctx.app.inject({ method: 'GET', url: '/workspace/members', headers: d.headers })).json().find((m: { role: string }) => m.role === 'receptionist');
    await ctx.app.inject({ method: 'PATCH', url: `/workspace/members/${member.id}`, headers: d.headers, payload: { deniedPermissions: ['patients.write'] } });
    expect((await register(rec, { phone: '+201111111112', fullName: 'Omar Ali' })).statusCode).toBe(403);
    expect((await ctx.app.inject({ method: 'GET', url: '/patients', headers: rec.headers })).statusCode).toBe(200);
  });
});

describe('isolation between clinics (RULE-003)', () => {
  it('the same phone in two clinics yields independent records that neither can see', async () => {
    const d1 = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    const d2 = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000002');
    const a = (await register(d1, { phone: patientPhone, fullName: 'Mona Hassan', dateOfBirth: '1990-05-01' })).json();
    const b = await register(d2, { phone: patientPhone, fullName: 'Mona H.' });
    expect(b.statusCode).toBe(201);
    expect(b.json().fullName).toBe('Mona H.');
    expect(b.json().dateOfBirth).toBeNull();
    expect(a.id).not.toBe(b.json().id);

    expect(await search(d2, '?q=Hassan')).toHaveLength(0);
    expect((await ctx.app.inject({ method: 'GET', url: `/patients/${a.id}`, headers: d2.headers })).statusCode).toBe(404);
    expect((await ctx.app.inject({ method: 'PATCH', url: `/patients/${a.id}`, headers: d2.headers, payload: { fullName: 'Hacked' } })).statusCode).toBe(404);
    expect((await ctx.app.inject({ method: 'POST', url: `/patients/${a.id}/end`, headers: d2.headers })).statusCode).toBe(404);
  });
});

describe('duplicate suspicion', () => {
  it('warns on same name + date of birth with a different phone, and allows an explicit override', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    await register(d, { phone: patientPhone, fullName: 'Mona  Hassan', dateOfBirth: '1990-05-01' });
    const dup = await register(d, { phone: '+201111111112', fullName: 'mona hassan', dateOfBirth: '1990-05-01' });
    expect(dup.statusCode).toBe(409);
    expect(dup.json().error).toBe('possible_duplicate');
    expect((await register(d, { phone: '+201111111112', fullName: 'mona hassan', dateOfBirth: '1990-05-02' })).statusCode).toBe(201);
    expect((await register(d, { phone: '+201111111113', fullName: 'mona hassan', dateOfBirth: '1990-05-01', confirmNotDuplicate: true })).statusCode).toBe(201);
  });
});

describe('patient accounts and confirmation (F03-3, F01-7)', () => {
  it('a patient who already has an account must confirm the connection', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    const pat = await login(ctx.app, patientPhone);
    await ctx.app.inject({ method: 'POST', url: '/patient/claim', headers: pat.headers });

    const reg = (await register(d, { phone: patientPhone, fullName: 'Mona Hassan' })).json();
    expect(reg).toMatchObject({ status: 'invited', hasAccount: true });

    const mine = (await ctx.app.inject({ method: 'GET', url: '/patient/relationships', headers: pat.headers })).json();
    expect(mine).toHaveLength(1);
    expect(mine[0]).toMatchObject({ status: 'invited', workspaceName: 'Test Clinic' });

    expect((await ctx.app.inject({ method: 'POST', url: `/patient/relationships/${reg.id}/accept`, headers: pat.headers })).statusCode).toBe(200);
    expect((await search(d))[0].status).toBe('active');
    expect((await ctx.app.inject({ method: 'POST', url: `/patient/relationships/${reg.id}/accept`, headers: pat.headers })).statusCode).toBe(409);
  });

  it('declining ends the relationship, and the clinic can re-invite', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    const pat = await login(ctx.app, patientPhone);
    await ctx.app.inject({ method: 'POST', url: '/patient/claim', headers: pat.headers });
    const reg = (await register(d, { phone: patientPhone, fullName: 'Mona Hassan' })).json();
    await ctx.app.inject({ method: 'POST', url: `/patient/relationships/${reg.id}/decline`, headers: pat.headers });
    expect(await search(d)).toHaveLength(0);
    const ended = await search(d, '?status=ended');
    expect(ended[0]).toMatchObject({ status: 'ended', endedBy: 'patient' });
    const again = await register(d, { phone: patientPhone, fullName: 'Mona Hassan' });
    expect(again.statusCode).toBe(201);
    expect(again.json()).toMatchObject({ id: reg.id, patientNumber: 1, status: 'invited', endedAt: null });
  });

  it('claiming links existing unclaimed records without merging or changing them', async () => {
    const d1 = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    const d2 = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000002');
    await register(d1, { phone: patientPhone, fullName: 'Mona Hassan' });
    await register(d2, { phone: patientPhone, fullName: 'Mona H.' });

    const pat = await login(ctx.app, patientPhone);
    const claimed = (await ctx.app.inject({ method: 'POST', url: '/patient/claim', headers: pat.headers })).json();
    expect(claimed).toHaveLength(2);
    expect(claimed.every((r: { status: string }) => r.status === 'active')).toBe(true);
    // Claim is idempotent.
    expect((await ctx.app.inject({ method: 'POST', url: '/patient/claim', headers: pat.headers })).json()).toHaveLength(2);
    expect((await search(d1))[0].hasAccount).toBe(true);
    expect((await search(d1))[0].fullName).toBe('Mona Hassan');
  });

  it('patients can only act on their own relationships', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    const reg = (await register(d, { phone: patientPhone, fullName: 'Mona Hassan' })).json();
    const other = await login(ctx.app, '+201222222222');
    await ctx.app.inject({ method: 'POST', url: '/patient/claim', headers: other.headers });
    expect((await ctx.app.inject({ method: 'POST', url: `/patient/relationships/${reg.id}/end`, headers: other.headers })).statusCode).toBe(404);
    expect((await ctx.app.inject({ method: 'GET', url: '/patient/relationships', headers: other.headers })).json()).toHaveLength(0);
  });

  it('a patient can end an active relationship and the clinic loses access to edits', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    const reg = (await register(d, { phone: patientPhone, fullName: 'Mona Hassan' })).json();
    const pat = await login(ctx.app, patientPhone);
    await ctx.app.inject({ method: 'POST', url: '/patient/claim', headers: pat.headers });
    expect((await ctx.app.inject({ method: 'POST', url: `/patient/relationships/${reg.id}/end`, headers: pat.headers })).statusCode).toBe(200);
    const edit = await ctx.app.inject({ method: 'PATCH', url: `/patients/${reg.id}`, headers: d.headers, payload: { fullName: 'New Name' } });
    expect(edit.statusCode).toBe(409);
  });
});

describe('editing and ending', () => {
  it('edits demographics and audits field names only', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    const reg = (await register(d, { phone: patientPhone, fullName: 'Mona Hassan', dateOfBirth: '1990-05-01' })).json();
    const r = await ctx.app.inject({ method: 'PATCH', url: `/patients/${reg.id}`, headers: d.headers, payload: { fullName: 'Mona Hassan Ali', dateOfBirth: null, sex: 'female' } });
    expect(r.json()).toMatchObject({ fullName: 'Mona Hassan Ali', dateOfBirth: null, sex: 'female' });
    const log = (await ctx.app.inject({ method: 'GET', url: '/workspace/audit', headers: d.headers })).json();
    const upd = log.find((l: { action: string }) => l.action === 'patient.updated');
    expect(upd.metadata).toEqual({ fields: ['fullName', 'dateOfBirth', 'sex'] });
    expect(JSON.stringify(log)).not.toContain('Mona');
    expect((await verifyChain(ctx.pool, d.workspaceId)).valid).toBe(true);
  });

  it('only users with relationships.manage can end a relationship', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    const rec = await staffOf(d, '+201000000002', 'receptionist');
    const reg = (await register(rec, { phone: patientPhone, fullName: 'Mona Hassan' })).json();
    expect((await ctx.app.inject({ method: 'POST', url: `/patients/${reg.id}/end`, headers: rec.headers })).statusCode).toBe(403);
    expect((await ctx.app.inject({ method: 'POST', url: `/patients/${reg.id}/end`, headers: d.headers })).statusCode).toBe(200);
    expect((await ctx.app.inject({ method: 'POST', url: `/patients/${reg.id}/end`, headers: d.headers })).statusCode).toBe(404);
    expect(await search(d)).toHaveLength(0);
    expect((await ctx.app.inject({ method: 'GET', url: `/patients/${reg.id}`, headers: d.headers })).json().status).toBe('ended');
  });

  it('users without a workspace cannot use patient endpoints', async () => {
    const s = await login(ctx.app, '+201333333333');
    expect((await ctx.app.inject({ method: 'GET', url: '/patients', headers: s.headers })).statusCode).toBe(403);
    expect((await ctx.app.inject({ method: 'POST', url: '/patients', headers: s.headers, payload: { phone: patientPhone, fullName: 'Mona' } })).statusCode).toBe(403);
  });
});
