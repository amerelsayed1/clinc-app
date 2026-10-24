import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { verifyChain } from '../src/audit.js';
import { enableMfa, login, makeVerifiedDoctor, reset, setupApp } from './helpers.js';

let ctx: Awaited<ReturnType<typeof setupApp>>;
beforeAll(async () => void (ctx = await setupApp()));
afterAll(async () => {
  await ctx.app.close();
  await ctx.pool.end();
});
beforeEach(() => reset(ctx.pool));

const doctorPhone = '+201000000001';
const recPhone = '+201000000002';
const nursePhone = '+201000000003';

async function inviteAndAccept(doctor: Awaited<ReturnType<typeof makeVerifiedDoctor>>, phone: string, role: 'nurse' | 'receptionist') {
  const inv = await ctx.app.inject({ method: 'POST', url: '/workspace/invitations', headers: doctor.headers, payload: { phone, role } });
  expect(inv.statusCode).toBe(201);
  const staff = await login(ctx.app, phone);
  const acc = await ctx.app.inject({ method: 'POST', url: '/invitations/accept', headers: staff.headers, payload: { code: inv.json().code } });
  expect(acc.statusCode).toBe(200);
  return staff;
}

describe('doctor onboarding', () => {
  it('requires a doctor profile before creating a workspace', async () => {
    const s = await login(ctx.app, doctorPhone);
    const r = await ctx.app.inject({ method: 'POST', url: '/workspaces', headers: s.headers, payload: {} });
    expect(r.statusCode).toBe(403);
  });

  it('allows one workspace per doctor', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, doctorPhone);
    const again = await ctx.app.inject({ method: 'POST', url: '/workspaces', headers: d.headers, payload: {} });
    expect(again.statusCode).toBe(409);
  });

  it('unverified doctors can manage the workspace but have no clinical permissions', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, doctorPhone, false);
    const ws = (await ctx.app.inject({ method: 'GET', url: '/workspace', headers: d.headers })).json();
    expect(ws.myPermissions).toContain('staff.manage');
    expect(ws.myPermissions).not.toContain('clinical.write');
  });

  it('platform admin verification unlocks clinical permissions', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, doctorPhone, false);
    const admin = await login(ctx.app, '+201000000099');
    expect((await ctx.app.inject({ method: 'GET', url: '/admin/doctors', headers: d.headers })).statusCode).toBe(403);
    await ctx.pool.query(`update users set is_platform_admin = true where id = $1`, [admin.user.id]);
    const pending = (await ctx.app.inject({ method: 'GET', url: '/admin/doctors', headers: admin.headers })).json();
    expect(pending).toHaveLength(1);
    const dec = await ctx.app.inject({ method: 'POST', url: `/admin/doctors/${d.user.id}/decision`, headers: admin.headers, payload: { decision: 'verified' } });
    expect(dec.statusCode).toBe(200);
    // Verified licence alone is not enough: clinical actions also need MFA (F01-3).
    const before = (await ctx.app.inject({ method: 'GET', url: '/workspace', headers: d.headers })).json();
    expect(before.myPermissions).not.toContain('clinical.write');
    await enableMfa(ctx.pool, d.user.id);
    const ws = (await ctx.app.inject({ method: 'GET', url: '/workspace', headers: d.headers })).json();
    expect(ws.myPermissions).toContain('clinical.write');
  });
});

describe('staff and permissions', () => {
  it('invitation is phone-bound, single-use, and revocable', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, doctorPhone);
    const inv = (await ctx.app.inject({ method: 'POST', url: '/workspace/invitations', headers: d.headers, payload: { phone: recPhone, role: 'receptionist' } })).json();
    expect(ctx.sent.at(-1)?.text).toContain(inv.code);

    const stranger = await login(ctx.app, nursePhone);
    const wrongPhone = await ctx.app.inject({ method: 'POST', url: '/invitations/accept', headers: stranger.headers, payload: { code: inv.code } });
    expect(wrongPhone.statusCode).toBe(400);

    const rec = await login(ctx.app, recPhone);
    expect((await ctx.app.inject({ method: 'POST', url: '/invitations/accept', headers: rec.headers, payload: { code: inv.code } })).statusCode).toBe(200);
    expect((await ctx.app.inject({ method: 'POST', url: '/invitations/accept', headers: rec.headers, payload: { code: inv.code } })).statusCode).toBe(400);

    const inv2 = (await ctx.app.inject({ method: 'POST', url: '/workspace/invitations', headers: d.headers, payload: { phone: nursePhone, role: 'nurse' } })).json();
    await ctx.app.inject({ method: 'DELETE', url: `/workspace/invitations/${inv2.id}`, headers: d.headers });
    expect((await ctx.app.inject({ method: 'POST', url: '/invitations/accept', headers: stranger.headers, payload: { code: inv2.code } })).statusCode).toBe(400);
  });

  it('expired invitations are rejected', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, doctorPhone);
    const inv = (await ctx.app.inject({ method: 'POST', url: '/workspace/invitations', headers: d.headers, payload: { phone: recPhone, role: 'receptionist' } })).json();
    await ctx.pool.query(`update invitations set expires_at = now() - interval '1 second'`);
    const rec = await login(ctx.app, recPhone);
    expect((await ctx.app.inject({ method: 'POST', url: '/invitations/accept', headers: rec.headers, payload: { code: inv.code } })).statusCode).toBe(400);
  });

  it('receptionists cannot manage staff, read the audit log, or hold clinical permissions (RULE-005)', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, doctorPhone);
    const rec = await inviteAndAccept(d, recPhone, 'receptionist');
    const invite = await ctx.app.inject({ method: 'POST', url: '/workspace/invitations', headers: rec.headers, payload: { phone: nursePhone, role: 'nurse' } });
    expect(invite.statusCode).toBe(403);
    expect((await ctx.app.inject({ method: 'GET', url: '/workspace/audit', headers: rec.headers })).statusCode).toBe(403);
    const ws = (await ctx.app.inject({ method: 'GET', url: '/workspace', headers: rec.headers })).json();
    expect(ws.myPermissions).not.toContain('clinical.write');
    expect(ws.myPermissions).not.toContain('clinical.read');
    expect(ws.myPermissions).toContain('appointments.manage');
  });

  it('users with no membership get 403 on workspace routes', async () => {
    const s = await login(ctx.app, recPhone);
    expect((await ctx.app.inject({ method: 'GET', url: '/workspace', headers: s.headers })).statusCode).toBe(403);
  });

  it('a doctor cannot act on another doctor\'s workspace', async () => {
    const d1 = await makeVerifiedDoctor(ctx.app, ctx.pool, doctorPhone);
    const d2 = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000010');
    const rec = await inviteAndAccept(d1, recPhone, 'receptionist');
    const members = (await ctx.app.inject({ method: 'GET', url: '/workspace/members', headers: d1.headers })).json();
    const recMember = members.find((m: { role: string }) => m.role === 'receptionist');
    const r = await ctx.app.inject({ method: 'DELETE', url: `/workspace/members/${recMember.id}`, headers: d2.headers });
    expect(r.statusCode).toBe(404);
    // Pointing the header at someone else's workspace does not grant membership either.
    const spoof = await ctx.app.inject({ method: 'GET', url: '/workspace', headers: { ...d2.headers, 'x-workspace-id': d1.workspaceId } });
    expect(spoof.statusCode).toBe(403);
    expect(rec).toBeTruthy();
  });

  it('doctor can deny individual permissions, which apply on the next request', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, doctorPhone);
    const nurse = await inviteAndAccept(d, nursePhone, 'nurse');
    const before = (await ctx.app.inject({ method: 'GET', url: '/workspace', headers: nurse.headers })).json();
    expect(before.myPermissions).toContain('clinical.read');

    const member = (await ctx.app.inject({ method: 'GET', url: '/workspace/members', headers: d.headers })).json().find((m: { role: string }) => m.role === 'nurse');
    const patch = await ctx.app.inject({ method: 'PATCH', url: `/workspace/members/${member.id}`, headers: d.headers, payload: { deniedPermissions: ['clinical.read'] } });
    expect(patch.statusCode).toBe(200);
    const after = (await ctx.app.inject({ method: 'GET', url: '/workspace', headers: nurse.headers })).json();
    expect(after.myPermissions).not.toContain('clinical.read');
    expect(after.myPermissions).toContain('vitals.write');
  });

  it('suspending or removing staff blocks them immediately but keeps their history', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, doctorPhone);
    const rec = await inviteAndAccept(d, recPhone, 'receptionist');
    const member = (await ctx.app.inject({ method: 'GET', url: '/workspace/members', headers: d.headers })).json().find((m: { role: string }) => m.role === 'receptionist');

    await ctx.app.inject({ method: 'PATCH', url: `/workspace/members/${member.id}`, headers: d.headers, payload: { status: 'suspended' } });
    expect((await ctx.app.inject({ method: 'GET', url: '/workspace', headers: rec.headers })).statusCode).toBe(403);
    await ctx.app.inject({ method: 'PATCH', url: `/workspace/members/${member.id}`, headers: d.headers, payload: { status: 'active' } });
    expect((await ctx.app.inject({ method: 'GET', url: '/workspace', headers: rec.headers })).statusCode).toBe(200);

    expect((await ctx.app.inject({ method: 'DELETE', url: `/workspace/members/${member.id}`, headers: d.headers })).statusCode).toBe(204);
    expect((await ctx.app.inject({ method: 'GET', url: '/workspace', headers: rec.headers })).statusCode).toBe(403);

    const audit = (await ctx.app.inject({ method: 'GET', url: '/workspace/audit', headers: d.headers })).json();
    expect(audit.some((a: { action: string; actorId: string }) => a.action === 'invitation.accepted' && a.actorId === rec.user.id)).toBe(true);
  });

  it('the owner cannot be modified or removed', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, doctorPhone);
    const owner = (await ctx.app.inject({ method: 'GET', url: '/workspace/members', headers: d.headers })).json()[0];
    expect((await ctx.app.inject({ method: 'DELETE', url: `/workspace/members/${owner.id}`, headers: d.headers })).statusCode).toBe(403);
    expect((await ctx.app.inject({ method: 'PATCH', url: `/workspace/members/${owner.id}`, headers: d.headers, payload: { status: 'suspended' } })).statusCode).toBe(403);
  });
});

describe('audit log', () => {
  it('records workspace events and verifies as an intact chain', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, doctorPhone);
    await inviteAndAccept(d, recPhone, 'receptionist');
    const log = (await ctx.app.inject({ method: 'GET', url: '/workspace/audit', headers: d.headers })).json();
    expect(log.map((l: { action: string }) => l.action)).toEqual(expect.arrayContaining(['workspace.created', 'invitation.sent', 'invitation.accepted']));
    const v = (await ctx.app.inject({ method: 'GET', url: '/workspace/audit/verify', headers: d.headers })).json();
    expect(v).toMatchObject({ valid: true, checked: 3 });
  });

  it('concurrent writes keep the chain valid', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, doctorPhone);
    await Promise.all(
      Array.from({ length: 8 }, (_, i) =>
        ctx.app.inject({ method: 'POST', url: '/workspace/invitations', headers: d.headers, payload: { phone: `+20100000010${i}`, role: 'nurse' } }),
      ),
    );
    expect(await verifyChain(ctx.pool, d.workspaceId)).toMatchObject({ valid: true, checked: 9 });
  });

  it('detects tampering and refuses updates/deletes at the database level', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, doctorPhone);
    await inviteAndAccept(d, recPhone, 'receptionist');
    await expect(ctx.pool.query(`update audit_log set action = 'x'`)).rejects.toThrow(/append-only/);
    await expect(ctx.pool.query(`delete from audit_log`)).rejects.toThrow(/append-only/);

    // Simulate an attacker with superuser access bypassing the trigger.
    await ctx.pool.query('alter table audit_log disable trigger audit_log_no_update');
    await ctx.pool.query(`update audit_log set action = 'invitation.nothing' where seq = 2 and chain_key = $1`, [d.workspaceId]);
    await ctx.pool.query('alter table audit_log enable trigger audit_log_no_update');
    const v = await verifyChain(ctx.pool, d.workspaceId);
    expect(v).toMatchObject({ valid: false, brokenAtSeq: 2 });
  });
});
