import { randomUUID } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { audit, auditAuth, writeAuthAudit } from '../audit.js';
import { authenticate, createSession, newOtp, safeEqual, sha256, signAccess, type SmsSender, newRefreshToken } from '../auth.js';
import { config } from '../config.js';
import { tx } from '../db.js';
import { AppError, badRequest, conflict, notFound, unauthorized } from '../errors.js';
import { newRecoveryCodes, newTotpSecret, openSecret, otpauthUrl, sealSecret, verifyTotp } from '../mfa.js';

export const phoneSchema = z.string().regex(/^\+[1-9]\d{7,14}$/, 'Use international format, e.g. +201001234567');

export function authRoutes(app: FastifyInstance, pool: pg.Pool, sms: SmsSender) {
  app.post('/auth/otp/request', async (req, reply) => {
    const { phone } = z.object({ phone: phoneSchema }).parse(req.body);
    const code = await issueOtp(phone);
    reply.code(config.otpDevEcho ? 200 : 204);
    return config.otpDevEcho ? { devCode: code } : undefined;
  });

  /** Checks and consumes a phone OTP; counts attempts and audits failures. */
  const consumeOtp = async (phone: string, code: string, ip: string) => {
    const otp = (
      await pool.query(
        `select * from otp_codes where phone = $1 and consumed_at is null and expires_at > now() order by created_at desc limit 1`,
        [phone],
      )
    ).rows[0];
    if (!otp || otp.attempts >= config.otp.maxAttempts) {
      await audit(pool, { action: 'auth.login_failed', result: 'denied', metadata: { phone, reason: otp ? 'locked' : 'no_active_code' }, ip });
      throw new AppError(otp ? 429 : 400, otp ? 'too_many_attempts' : 'invalid_code', 'Invalid or expired code');
    }
    if (!safeEqual(otp.code_hash, sha256(`${phone}:${code}`))) {
      await pool.query('update otp_codes set attempts = attempts + 1 where id = $1', [otp.id]);
      await audit(pool, { action: 'auth.login_failed', result: 'denied', metadata: { phone, reason: 'wrong_code' }, ip });
      throw badRequest('invalid_code', 'Invalid or expired code');
    }
    const consumed = await pool.query('update otp_codes set consumed_at = now() where id = $1 and consumed_at is null', [otp.id]);
    if (consumed.rowCount === 0) throw badRequest('invalid_code', 'Invalid or expired code');
  };

  const issueOtp = async (phone: string) => {
    const recent = (
      await pool.query(`select count(*)::int as n from otp_codes where phone = $1 and created_at > now() - interval '15 minutes'`, [phone])
    ).rows[0].n;
    if (recent >= config.otp.maxRequestsPer15Min) throw new AppError(429, 'too_many_requests', 'Too many codes requested. Try again later.');
    const code = newOtp();
    await pool.query(`insert into otp_codes (phone, code_hash, expires_at) values ($1,$2, now() + make_interval(secs => $3))`, [phone, sha256(`${phone}:${code}`), config.otp.ttlSeconds]);
    await sms.send(phone, `Your verification code is ${code}`);
    return code;
  };

  const sessionResponse = (user: { id: string; phone: string; full_name: string | null }, session: { accessToken: string; refreshToken: string }) => ({
    accessToken: session.accessToken,
    refreshToken: session.refreshToken,
    user: { id: user.id, phone: user.phone, fullName: user.full_name },
  });

  /** Spec 10: a sign-in from a device name this account has not used before (not its first ever sign-in) raises a security notice. */
  const priorSignIn = async (userId: string, deviceName?: string | null) => {
    const r = (await pool.query(`select count(*)::int as total, count(*) filter (where device_name = $2)::int as same from sessions where user_id = $1`, [userId, deviceName ?? null])).rows[0];
    return r.total > 0 && !!deviceName && r.same === 0;
  };
  const noteNewDevice = (userId: string, sessionId: string, isNew: boolean) =>
    isNew ? app.notifier.notify({ userId, type: 'security_new_login', key: `new-login:${sessionId}` }) : Promise.resolve(null);

  app.post('/auth/otp/verify', async (req) => {
    const body = z.object({ phone: phoneSchema, code: z.string().length(6), deviceName: z.string().max(100).optional() }).parse(req.body);
    await consumeOtp(body.phone, body.code, req.ip);

    const user = (
      await pool.query(
        `insert into users (phone) values ($1) on conflict (phone) do update set phone = excluded.phone returning id, phone, full_name, mfa_enabled_at`,
        [body.phone],
      )
    ).rows[0];
    // F01-3: accounts with MFA enrolled must pass a second factor before any session exists.
    if (user.mfa_enabled_at) {
      const token = newRefreshToken();
      await pool.query(
        `insert into mfa_challenges (user_id, token_hash, device_name, ip, expires_at) values ($1,$2,$3,$4, now() + make_interval(secs => $5))`,
        [user.id, sha256(token), body.deviceName ?? null, req.ip, config.otp.ttlSeconds],
      );
      return { mfaRequired: true, mfaToken: token };
    }
    const isNewDevice = await priorSignIn(user.id, body.deviceName);
    const session = await createSession(app, pool, user.id, { deviceName: body.deviceName, ip: req.ip });
    await noteNewDevice(user.id, session.sessionId, isNewDevice);
    await auditAuth(pool, { actorId: user.id, action: 'auth.login', targetType: 'session', targetId: session.sessionId, ip: req.ip });
    return sessionResponse(user, session);
  });

  /** Verifies a TOTP code (replay-protected) or a one-time recovery code for a user. */
  const checkSecondFactor = async (c: pg.PoolClient | pg.Pool, userId: string, input: { code?: string; recoveryCode?: string }) => {
    const u = (await c.query('select totp_secret_enc, totp_last_step from users where id = $1 for update', [userId])).rows[0];
    if (!u?.totp_secret_enc) return false;
    if (input.code) {
      const step = verifyTotp(openSecret(u.totp_secret_enc), input.code);
      if (step === null || (u.totp_last_step !== null && step <= Number(u.totp_last_step))) return false;
      await c.query('update users set totp_last_step = $2 where id = $1', [userId, step]);
      return true;
    }
    if (input.recoveryCode) {
      const r = await c.query('update mfa_recovery_codes set used_at = now() where user_id = $1 and code_hash = $2 and used_at is null', [userId, sha256(input.recoveryCode.trim().toUpperCase())]);
      return r.rowCount === 1;
    }
    return false;
  };

  app.post('/auth/mfa/verify', async (req) => {
    const body = z
      .object({ mfaToken: z.string().min(10), code: z.string().length(6).optional(), recoveryCode: z.string().min(8).max(20).optional() })
      .refine((b) => !!b.code !== !!b.recoveryCode, 'Provide either code or recoveryCode')
      .parse(req.body);
    const result = await tx(pool, async (c) => {
      const ch = (await c.query('select * from mfa_challenges where token_hash = $1 for update', [sha256(body.mfaToken)])).rows[0];
      if (!ch || ch.consumed_at || ch.expires_at < new Date() || ch.attempts >= config.otp.maxAttempts) {
        throw new AppError(ch && ch.attempts >= config.otp.maxAttempts ? 429 : 400, 'invalid_code', 'Invalid or expired code');
      }
      if (!(await checkSecondFactor(c, ch.user_id, body))) {
        await c.query('update mfa_challenges set attempts = attempts + 1 where id = $1', [ch.id]);
        await writeAuthAudit(c, { actorId: ch.user_id, action: 'auth.login_failed', result: 'denied', metadata: { reason: 'wrong_mfa_code' }, ip: req.ip });
        return 'bad' as const; // returned, not thrown: throwing would roll back the attempt counter
      }
      await c.query('update mfa_challenges set consumed_at = now() where id = $1', [ch.id]);
      return ch as { user_id: string; device_name: string | null };
    });
    if (result === 'bad') throw badRequest('invalid_code', 'Invalid or expired code');
    const user = (await pool.query('select id, phone, full_name from users where id = $1', [result.user_id])).rows[0];
    const isNewDevice = await priorSignIn(user.id, result.device_name);
    const session = await createSession(app, pool, user.id, { deviceName: result.device_name ?? undefined, ip: req.ip });
    await noteNewDevice(user.id, session.sessionId, isNewDevice);
    await auditAuth(pool, { actorId: user.id, action: 'auth.login', targetType: 'session', targetId: session.sessionId, metadata: { mfa: body.code ? 'totp' : 'recovery_code' }, ip: req.ip });
    return sessionResponse(user, session);
  });

  // Rotating refresh tokens. Presenting an already-rotated token signals theft: the session is revoked.
  app.post('/auth/refresh', async (req) => {
    const { refreshToken } = z.object({ refreshToken: z.string().min(10) }).parse(req.body);
    const h = sha256(refreshToken);
    const result = await tx(pool, async (c) => {
      const s = (await c.query('select * from sessions where refresh_hash = $1 or prev_refresh_hash = $1 for update', [h])).rows[0];
      if (!s || s.revoked_at || s.expires_at < new Date()) throw unauthorized('Invalid refresh token');
      if (s.prev_refresh_hash === h && s.refresh_hash !== h) {
        await c.query('update sessions set revoked_at = now() where id = $1', [s.id]);
        await writeAuthAudit(c, { actorId: s.user_id, action: 'auth.refresh_reuse_detected', targetType: 'session', targetId: s.id, ip: req.ip });
        return 'reuse' as const; // returned, not thrown: throwing would roll back the revoke
      }
      const next = newRefreshToken();
      await c.query('update sessions set prev_refresh_hash = refresh_hash, refresh_hash = $2, last_used_at = now() where id = $1', [s.id, sha256(next)]);
      return { accessToken: signAccess(app, s.user_id, s.id), refreshToken: next };
    });
    if (result === 'reuse') throw unauthorized('Refresh token reuse detected');
    return result;
  });

  const authed = { preHandler: authenticate(pool) };

  app.post('/auth/logout', authed, async (req, reply) => {
    await pool.query('update sessions set revoked_at = now() where id = $1', [req.auth!.sessionId]);
    await auditAuth(pool, { actorId: req.auth!.userId, action: 'auth.logout', targetType: 'session', targetId: req.auth!.sessionId });
    reply.code(204);
  });

  app.get('/sessions', authed, async (req) => {
    const rows = (
      await pool.query(
        `select id, device_name, ip, created_at, last_used_at from sessions where user_id = $1 and revoked_at is null and expires_at > now() order by last_used_at desc`,
        [req.auth!.userId],
      )
    ).rows;
    return rows.map((r) => ({ id: r.id, deviceName: r.device_name, ip: r.ip, createdAt: r.created_at, lastUsedAt: r.last_used_at, current: r.id === req.auth!.sessionId }));
  });

  app.delete('/sessions/:id', authed, async (req, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const r = await pool.query('update sessions set revoked_at = now() where id = $1 and user_id = $2 and revoked_at is null', [id, req.auth!.userId]);
    if (r.rowCount === 0) throw notFound('Session not found');
    await auditAuth(pool, { actorId: req.auth!.userId, action: 'auth.session_revoked', targetType: 'session', targetId: id, ip: req.ip });
    reply.code(204);
  });

  // ---------- MFA enrolment (F01-3) ----------
  app.post('/auth/mfa/enroll', authed, async (req) => {
    const u = (await pool.query('select phone, mfa_enabled_at from users where id = $1', [req.auth!.userId])).rows[0];
    if (u.mfa_enabled_at) throw conflict('mfa_already_enabled', 'MFA is already enabled');
    const secret = newTotpSecret();
    await pool.query('update users set totp_pending_enc = $2 where id = $1', [req.auth!.userId, sealSecret(secret)]);
    return { secret, otpauthUrl: otpauthUrl(secret, u.phone) };
  });

  app.post('/auth/mfa/activate', authed, async (req) => {
    const { code } = z.object({ code: z.string().length(6) }).parse(req.body);
    const userId = req.auth!.userId;
    const codes = newRecoveryCodes();
    await tx(pool, async (c) => {
      const u = (await c.query('select totp_pending_enc, mfa_enabled_at from users where id = $1 for update', [userId])).rows[0];
      if (u.mfa_enabled_at) throw conflict('mfa_already_enabled', 'MFA is already enabled');
      if (!u.totp_pending_enc) throw badRequest('no_enrolment', 'Start enrolment first');
      const step = verifyTotp(openSecret(u.totp_pending_enc), code);
      if (step === null) throw badRequest('invalid_code', 'Invalid code');
      await c.query('update users set totp_secret_enc = totp_pending_enc, totp_pending_enc = null, totp_last_step = $2, mfa_enabled_at = now() where id = $1', [userId, step]);
      await c.query('delete from mfa_recovery_codes where user_id = $1', [userId]);
      for (const rc of codes) await c.query('insert into mfa_recovery_codes (user_id, code_hash) values ($1,$2)', [userId, sha256(rc)]);
      await writeAuthAudit(c, { actorId: userId, action: 'auth.mfa_enrolled', targetType: 'user', targetId: userId, ip: req.ip });
    });
    await app.notifier.notify({ userId, type: 'security_mfa_enabled', key: `mfa-enabled:${userId}:${randomUUID()}` });
    return { recoveryCodes: codes }; // shown exactly once
  });

  // Doctors and platform admins must keep MFA on; others may switch it off with a valid code.
  app.post('/auth/mfa/disable', authed, async (req, reply) => {
    const body = z.object({ code: z.string().length(6) }).parse(req.body);
    const userId = req.auth!.userId;
    const required = (await pool.query(`select 1 from users u where u.id = $1 and (u.is_platform_admin or exists (select 1 from doctor_profiles d where d.user_id = u.id))`, [userId])).rowCount;
    if (required) throw new AppError(403, 'mfa_required', 'MFA is required for this account');
    const ok = await tx(pool, async (c) => {
      if (!(await checkSecondFactor(c, userId, body))) return false;
      await c.query('update users set totp_secret_enc = null, totp_last_step = null, mfa_enabled_at = null where id = $1', [userId]);
      await c.query('delete from mfa_recovery_codes where user_id = $1', [userId]);
      await writeAuthAudit(c, { actorId: userId, action: 'auth.mfa_disabled', targetType: 'user', targetId: userId, ip: req.ip });
      return true;
    });
    if (!ok) throw badRequest('invalid_code', 'Invalid code');
    await app.notifier.notify({ userId, type: 'security_mfa_disabled', key: `mfa-disabled:${userId}:${randomUUID()}` });
    reply.code(204);
  });

  // ---------- Session management (F01-5) ----------
  app.post('/sessions/revoke-others', authed, async (req) => {
    const r = await pool.query('update sessions set revoked_at = now() where user_id = $1 and id <> $2 and revoked_at is null', [req.auth!.userId, req.auth!.sessionId]);
    await auditAuth(pool, { actorId: req.auth!.userId, action: 'auth.sessions_revoked_others', metadata: { count: r.rowCount }, ip: req.ip });
    return { revoked: r.rowCount };
  });

  // ---------- Phone change (F01-8): OTP on the old and the new number ----------
  app.post('/auth/phone-change/request', authed, async (req, reply) => {
    const { newPhone } = z.object({ newPhone: phoneSchema }).parse(req.body);
    const u = (await pool.query('select phone from users where id = $1', [req.auth!.userId])).rows[0];
    if (newPhone === u.phone) throw badRequest('same_phone', 'That is already your number');
    if ((await pool.query('select 1 from users where phone = $1', [newPhone])).rowCount) throw conflict('phone_in_use', 'That number belongs to another account');
    await auditAuth(pool, { actorId: req.auth!.userId, action: 'auth.phone_change_requested', targetType: 'user', targetId: req.auth!.userId });
    const oldCode = await issueOtp(u.phone);
    const newCode = await issueOtp(newPhone);
    reply.code(config.otpDevEcho ? 200 : 204);
    return config.otpDevEcho ? { devOldCode: oldCode, devNewCode: newCode } : undefined;
  });

  app.post('/auth/phone-change/confirm', authed, async (req) => {
    const body = z.object({ newPhone: phoneSchema, oldCode: z.string().length(6), newCode: z.string().length(6) }).parse(req.body);
    const userId = req.auth!.userId;
    const u = (await pool.query('select phone from users where id = $1', [userId])).rows[0];
    await consumeOtp(u.phone, body.oldCode, req.ip);
    await consumeOtp(body.newPhone, body.newCode, req.ip);
    await tx(pool, async (c) => {
      if ((await c.query('select 1 from users where phone = $1 and id <> $2', [body.newPhone, userId])).rowCount) throw conflict('phone_in_use', 'That number belongs to another account');
      if ((await c.query('select 1 from patients where phone = $1 and (user_id is null or user_id <> $2)', [body.newPhone, userId])).rowCount) {
        throw conflict('phone_in_use', 'That number is registered to another patient record');
      }
      await c.query('update users set phone = $2 where id = $1', [userId, body.newPhone]);
      await c.query('update patients set phone = $2 where user_id = $1', [userId, body.newPhone]);
      // Other devices must prove the new number again.
      await c.query('update sessions set revoked_at = now() where user_id = $1 and id <> $2 and revoked_at is null', [userId, req.auth!.sessionId]);
      await writeAuthAudit(c, { actorId: userId, action: 'auth.phone_changed', targetType: 'user', targetId: userId, metadata: { from: u.phone, to: body.newPhone }, ip: req.ip });
    });
    // The notice also goes to the previous number, so a hijacked change is visible to the real owner.
    await app.notifier.notify({ userId, type: 'security_phone_changed', key: `phone-changed:${userId}:${randomUUID()}`, smsTo: u.phone });
    return { phone: body.newPhone };
  });
}
