import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { base32Decode, totpCode, totpStep } from '../src/mfa.js';
import { login, makeVerifiedDoctor, reset, setupApp } from './helpers.js';

let ctx: Awaited<ReturnType<typeof setupApp>>;
beforeAll(async () => void (ctx = await setupApp()));
afterAll(async () => {
  await ctx.app.close();
  await ctx.pool.end();
});
beforeEach(() => reset(ctx.pool));

const phone = '+201001234567';

describe('OTP login', () => {
  it('logs in with a valid code and creates the user', async () => {
    const s = await login(ctx.app, phone);
    const me = await ctx.app.inject({ method: 'GET', url: '/me', headers: s.headers });
    expect(me.statusCode).toBe(200);
    expect(me.json().phone).toBe(phone);
  });

  it('rejects malformed phone numbers', async () => {
    const r = await ctx.app.inject({ method: 'POST', url: '/auth/otp/request', payload: { phone: '0100123' } });
    expect(r.statusCode).toBe(400);
  });

  it('codes are single use', async () => {
    const { devCode } = (await ctx.app.inject({ method: 'POST', url: '/auth/otp/request', payload: { phone } })).json();
    const ok = await ctx.app.inject({ method: 'POST', url: '/auth/otp/verify', payload: { phone, code: devCode } });
    expect(ok.statusCode).toBe(200);
    const again = await ctx.app.inject({ method: 'POST', url: '/auth/otp/verify', payload: { phone, code: devCode } });
    expect(again.statusCode).toBe(400);
  });

  it('locks the code after 5 wrong attempts, even if the right code is then used', async () => {
    const { devCode } = (await ctx.app.inject({ method: 'POST', url: '/auth/otp/request', payload: { phone } })).json();
    const wrong = devCode === '000000' ? '111111' : '000000';
    for (let i = 0; i < 5; i++) {
      const r = await ctx.app.inject({ method: 'POST', url: '/auth/otp/verify', payload: { phone, code: wrong } });
      expect(r.statusCode).toBe(400);
    }
    const locked = await ctx.app.inject({ method: 'POST', url: '/auth/otp/verify', payload: { phone, code: devCode } });
    expect(locked.statusCode).toBe(429);
  });

  it('rate limits code requests per phone', async () => {
    for (let i = 0; i < 5; i++) {
      expect((await ctx.app.inject({ method: 'POST', url: '/auth/otp/request', payload: { phone } })).statusCode).toBe(200);
    }
    expect((await ctx.app.inject({ method: 'POST', url: '/auth/otp/request', payload: { phone } })).statusCode).toBe(429);
  });

  it('rejects expired codes', async () => {
    const { devCode } = (await ctx.app.inject({ method: 'POST', url: '/auth/otp/request', payload: { phone } })).json();
    await ctx.pool.query(`update otp_codes set expires_at = now() - interval '1 second'`);
    const r = await ctx.app.inject({ method: 'POST', url: '/auth/otp/verify', payload: { phone, code: devCode } });
    expect(r.statusCode).toBe(400);
  });
});

describe('sessions', () => {
  it('rejects requests without a token', async () => {
    expect((await ctx.app.inject({ method: 'GET', url: '/me' })).statusCode).toBe(401);
  });

  it('rotates refresh tokens and revokes the session when an old one is replayed', async () => {
    const s = await login(ctx.app, phone);
    const r1 = await ctx.app.inject({ method: 'POST', url: '/auth/refresh', payload: { refreshToken: s.refreshToken } });
    expect(r1.statusCode).toBe(200);
    const next = r1.json();
    expect(next.refreshToken).not.toBe(s.refreshToken);

    const replay = await ctx.app.inject({ method: 'POST', url: '/auth/refresh', payload: { refreshToken: s.refreshToken } });
    expect(replay.statusCode).toBe(401);

    // The whole session, including the legitimately rotated token and access token, is now dead.
    const after = await ctx.app.inject({ method: 'POST', url: '/auth/refresh', payload: { refreshToken: next.refreshToken } });
    expect(after.statusCode).toBe(401);
    const me = await ctx.app.inject({ method: 'GET', url: '/me', headers: { authorization: `Bearer ${next.accessToken}` } });
    expect(me.statusCode).toBe(401);
  });

  it('revoking a session invalidates its access token immediately', async () => {
    const a = await login(ctx.app, phone);
    const b = await login(ctx.app, phone);
    const list = (await ctx.app.inject({ method: 'GET', url: '/sessions', headers: a.headers })).json();
    expect(list).toHaveLength(2);
    const other = list.find((x: { current: boolean }) => !x.current);
    expect((await ctx.app.inject({ method: 'DELETE', url: `/sessions/${other.id}`, headers: a.headers })).statusCode).toBe(204);
    expect((await ctx.app.inject({ method: 'GET', url: '/me', headers: b.headers })).statusCode).toBe(401);
    expect((await ctx.app.inject({ method: 'GET', url: '/me', headers: a.headers })).statusCode).toBe(200);
  });

  it('users cannot revoke another user\'s session', async () => {
    const a = await login(ctx.app, phone);
    const other = await login(ctx.app, '+201009999999');
    const sid = (await ctx.app.inject({ method: 'GET', url: '/sessions', headers: other.headers })).json()[0].id;
    expect((await ctx.app.inject({ method: 'DELETE', url: `/sessions/${sid}`, headers: a.headers })).statusCode).toBe(404);
  });

  it('logout revokes the session', async () => {
    const s = await login(ctx.app, phone);
    expect((await ctx.app.inject({ method: 'POST', url: '/auth/logout', headers: s.headers })).statusCode).toBe(204);
    expect((await ctx.app.inject({ method: 'GET', url: '/me', headers: s.headers })).statusCode).toBe(401);
  });
});

describe('MFA (F01-3)', () => {
  const inject = (method: 'GET' | 'POST', url: string, headers?: Record<string, string>, payload?: object) => ctx.app.inject({ method, url, headers, payload });

  async function enrol(headers: Record<string, string>) {
    const { secret } = (await inject('POST', '/auth/mfa/enroll', headers)).json();
    const step = totpStep();
    const act = await inject('POST', '/auth/mfa/activate', headers, { code: totpCode(secret, step) });
    return { secret, step, recoveryCodes: act.json().recoveryCodes as string[], status: act.statusCode };
  }
  const otpLogin = async (p = phone) => {
    const { devCode } = (await inject('POST', '/auth/otp/request', undefined, { phone: p })).json();
    return (await inject('POST', '/auth/otp/verify', undefined, { phone: p, code: devCode })).json();
  };

  it('enrolment rejects a wrong code and activates with a right one', async () => {
    const s = await login(ctx.app, phone);
    await inject('POST', '/auth/mfa/enroll', s.headers);
    expect((await inject('POST', '/auth/mfa/activate', s.headers, { code: '000000' })).statusCode).toBe(400);
    const e = await enrol(s.headers);
    expect(e.status).toBe(200);
    expect(e.recoveryCodes).toHaveLength(8);
    expect((await inject('GET', '/me', s.headers)).json().mfaEnabled).toBe(true);
  });

  it('login then requires a second factor and no session exists before it', async () => {
    const s = await login(ctx.app, phone);
    const e = await enrol(s.headers);
    const first = await otpLogin();
    expect(first).toMatchObject({ mfaRequired: true });
    expect(first.accessToken).toBeUndefined();

    // The code used to activate is not accepted again (replay); the next step is.
    const replay = await inject('POST', '/auth/mfa/verify', undefined, { mfaToken: first.mfaToken, code: totpCode(e.secret, e.step) });
    expect(replay.statusCode).toBe(400);
    const ok = await inject('POST', '/auth/mfa/verify', undefined, { mfaToken: first.mfaToken, code: totpCode(e.secret, e.step + 1) });
    expect(ok.statusCode).toBe(200);
    expect((await inject('GET', '/me', { authorization: `Bearer ${ok.json().accessToken}` })).statusCode).toBe(200);
    // Challenges are single use.
    expect((await inject('POST', '/auth/mfa/verify', undefined, { mfaToken: first.mfaToken, code: totpCode(e.secret, e.step + 1) })).statusCode).toBe(400);
  });

  it('locks the challenge after 5 wrong codes', async () => {
    const s = await login(ctx.app, phone);
    const e = await enrol(s.headers);
    const ch = await otpLogin();
    for (let i = 0; i < 5; i++) expect((await inject('POST', '/auth/mfa/verify', undefined, { mfaToken: ch.mfaToken, code: '000000' })).statusCode).toBe(400);
    const locked = await inject('POST', '/auth/mfa/verify', undefined, { mfaToken: ch.mfaToken, code: totpCode(e.secret, e.step + 1) });
    expect(locked.statusCode).toBe(429);
  });

  it('recovery codes work once', async () => {
    const s = await login(ctx.app, phone);
    const e = await enrol(s.headers);
    const rc = e.recoveryCodes[0]!;
    const a = await otpLogin();
    expect((await inject('POST', '/auth/mfa/verify', undefined, { mfaToken: a.mfaToken, recoveryCode: rc })).statusCode).toBe(200);
    const b = await otpLogin();
    expect((await inject('POST', '/auth/mfa/verify', undefined, { mfaToken: b.mfaToken, recoveryCode: rc })).statusCode).toBe(400);
  });

  it('clinical permissions need MFA, and doctors cannot switch it off', async () => {
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201001110000', false);
    await ctx.pool.query(`update doctor_profiles set verification_status = 'verified' where user_id = $1`, [d.user.id]);
    expect((await inject('GET', '/me', d.headers)).json()).toMatchObject({ mfaRequired: true, mfaEnabled: false });
    expect((await inject('GET', '/workspace', d.headers)).json().myPermissions).not.toContain('clinical.write');
    const e = await enrol(d.headers);
    expect((await inject('GET', '/workspace', d.headers)).json().myPermissions).toContain('clinical.write');
    const dis = await inject('POST', '/auth/mfa/disable', d.headers, { code: totpCode(e.secret, e.step + 1) });
    expect(dis.statusCode).toBe(403);
  });

  it('non-doctors can disable MFA with a valid code', async () => {
    const s = await login(ctx.app, phone);
    const e = await enrol(s.headers);
    expect((await inject('POST', '/auth/mfa/disable', s.headers, { code: '000000' })).statusCode).toBe(400);
    expect((await inject('POST', '/auth/mfa/disable', s.headers, { code: totpCode(e.secret, e.step + 1) })).statusCode).toBe(204);
    expect((await inject('GET', '/me', s.headers)).json().mfaEnabled).toBe(false);
  });

  it('TOTP matches the RFC 6238 test vector', () => {
    // Appendix B, SHA-1, T=59s -> 94287082 (8 digits); the 6-digit code is its last 6 digits.
    const b32 = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
    expect(base32Decode(b32).toString()).toBe('12345678901234567890');
    expect(totpCode(b32, Math.floor(59 / 30))).toBe('287082');
  });
});

describe('phone change (F01-8)', () => {
  const newPhone = '+201002223333';
  const request = (headers: Record<string, string>) => ctx.app.inject({ method: 'POST', url: '/auth/phone-change/request', headers, payload: { newPhone } });
  const confirm = (headers: Record<string, string>, oldCode: string, newCode: string) =>
    ctx.app.inject({ method: 'POST', url: '/auth/phone-change/confirm', headers, payload: { newPhone, oldCode, newCode } });

  it('needs OTP on both numbers, moves the identity, and signs out other devices', async () => {
    const a = await login(ctx.app, phone);
    const b = await login(ctx.app, phone);
    const first = (await request(a.headers)).json();
    expect((await confirm(a.headers, first.devOldCode, first.devNewCode === '000000' ? '111111' : '000000')).statusCode).toBe(400);
    const second = (await request(a.headers)).json();
    expect((await confirm(a.headers, second.devOldCode, second.devNewCode)).statusCode).toBe(200);
    expect((await ctx.app.inject({ method: 'GET', url: '/me', headers: a.headers })).json().phone).toBe(newPhone);
    expect((await ctx.app.inject({ method: 'GET', url: '/me', headers: b.headers })).statusCode).toBe(401);
  });

  it('refuses a number owned by another account', async () => {
    const a = await login(ctx.app, phone);
    await login(ctx.app, newPhone);
    expect((await request(a.headers)).statusCode).toBe(409);
  });
});

describe('revoke other sessions', () => {
  it('keeps only the current session', async () => {
    const a = await login(ctx.app, phone);
    const b = await login(ctx.app, phone);
    const r = await ctx.app.inject({ method: 'POST', url: '/sessions/revoke-others', headers: a.headers });
    expect(r.json().revoked).toBe(1);
    expect((await ctx.app.inject({ method: 'GET', url: '/me', headers: b.headers })).statusCode).toBe(401);
    expect((await ctx.app.inject({ method: 'GET', url: '/me', headers: a.headers })).statusCode).toBe(200);
  });
});
