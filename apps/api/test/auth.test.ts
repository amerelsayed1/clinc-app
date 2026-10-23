import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { reset, setupApp, login } from './helpers.js';

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
