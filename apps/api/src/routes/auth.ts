import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { audit, writeAudit } from '../audit.js';
import { authenticate, createSession, newOtp, safeEqual, sha256, signAccess, type SmsSender, newRefreshToken } from '../auth.js';
import { config } from '../config.js';
import { tx } from '../db.js';
import { AppError, badRequest, notFound, unauthorized } from '../errors.js';

export const phoneSchema = z.string().regex(/^\+[1-9]\d{7,14}$/, 'Use international format, e.g. +201001234567');

export function authRoutes(app: FastifyInstance, pool: pg.Pool, sms: SmsSender) {
  app.post('/auth/otp/request', async (req, reply) => {
    const { phone } = z.object({ phone: phoneSchema }).parse(req.body);
    const recent = (
      await pool.query(`select count(*)::int as n from otp_codes where phone = $1 and created_at > now() - interval '15 minutes'`, [phone])
    ).rows[0].n;
    if (recent >= config.otp.maxRequestsPer15Min) throw new AppError(429, 'too_many_requests', 'Too many codes requested. Try again later.');
    const code = newOtp();
    await pool.query(`insert into otp_codes (phone, code_hash, expires_at) values ($1,$2, now() + make_interval(secs => $3))`, [
      phone,
      sha256(`${phone}:${code}`),
      config.otp.ttlSeconds,
    ]);
    await sms.send(phone, `Your verification code is ${code}`);
    reply.code(config.otpDevEcho ? 200 : 204);
    return config.otpDevEcho ? { devCode: code } : undefined;
  });

  app.post('/auth/otp/verify', async (req) => {
    const body = z.object({ phone: phoneSchema, code: z.string().length(6), deviceName: z.string().max(100).optional() }).parse(req.body);
    const otp = (
      await pool.query(
        `select * from otp_codes where phone = $1 and consumed_at is null and expires_at > now() order by created_at desc limit 1`,
        [body.phone],
      )
    ).rows[0];
    if (!otp || otp.attempts >= config.otp.maxAttempts) {
      await audit(pool, { action: 'auth.login_failed', metadata: { phone: body.phone, reason: otp ? 'locked' : 'no_active_code' }, ip: req.ip });
      throw new AppError(otp ? 429 : 400, otp ? 'too_many_attempts' : 'invalid_code', 'Invalid or expired code');
    }
    if (!safeEqual(otp.code_hash, sha256(`${body.phone}:${body.code}`))) {
      await pool.query('update otp_codes set attempts = attempts + 1 where id = $1', [otp.id]);
      await audit(pool, { action: 'auth.login_failed', metadata: { phone: body.phone, reason: 'wrong_code' }, ip: req.ip });
      throw badRequest('invalid_code', 'Invalid or expired code');
    }
    const consumed = await pool.query('update otp_codes set consumed_at = now() where id = $1 and consumed_at is null', [otp.id]);
    if (consumed.rowCount === 0) throw badRequest('invalid_code', 'Invalid or expired code');

    const user = (
      await pool.query(
        `insert into users (phone) values ($1) on conflict (phone) do update set phone = excluded.phone returning id, phone, full_name`,
        [body.phone],
      )
    ).rows[0];
    const session = await createSession(app, pool, user.id, { deviceName: body.deviceName, ip: req.ip });
    await audit(pool, { actorId: user.id, action: 'auth.login', targetType: 'session', targetId: session.sessionId, ip: req.ip });
    return { accessToken: session.accessToken, refreshToken: session.refreshToken, user: { id: user.id, phone: user.phone, fullName: user.full_name } };
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
        await writeAudit(c, { actorId: s.user_id, action: 'auth.refresh_reuse_detected', targetType: 'session', targetId: s.id, ip: req.ip });
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
    await audit(pool, { actorId: req.auth!.userId, action: 'auth.session_revoked', targetType: 'session', targetId: id, ip: req.ip });
    reply.code(204);
  });
}
