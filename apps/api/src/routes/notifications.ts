import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { audit } from '../audit.js';
import { authenticate } from '../auth.js';
import { badRequest, notFound } from '../errors.js';
import { LOCALES, MANDATORY_TYPES, NOTIFICATION_TYPES, assertKnownTypes, consentRequired, loadConsent, loadPrefs, renderInbox, type Locale } from '../notifications.js';

const hhmm = z.string().regex(/^([01][0-9]|2[0-3]):[0-5][0-9]$/, 'Use HH:MM');
const validZone = (z0: string) => {
  try {
    new Intl.DateTimeFormat('en', { timeZone: z0 });
    return true;
  } catch {
    return false;
  }
};

export function notificationRoutes(app: FastifyInstance, pool: pg.Pool) {
  const authed = { preHandler: authenticate(pool) };

  // ---------- inbox ----------
  const present = (r: Record<string, any>, locale: Locale) => ({
    id: r.id,
    type: r.type,
    ...renderInbox(r.type, locale, r.params),
    data: r.params,
    createdAt: r.created_at,
    readAt: r.read_at,
    read: !!r.read_at,
  });

  app.get('/notifications', authed, async (req) => {
    const q = z.object({ limit: z.coerce.number().int().min(1).max(100).default(30), cursor: z.string().max(100).optional(), unreadOnly: z.enum(['true', 'false']).optional() }).parse(req.query);
    const userId = req.auth!.userId;
    let curAt: string | null = null;
    let curId: string | null = null;
    if (q.cursor) {
      const [a, b] = q.cursor.split('_');
      if (!a || !b || Number.isNaN(Date.parse(a)) || !z.string().uuid().safeParse(b).success) throw badRequest('invalid_cursor', 'Invalid cursor');
      curAt = a;
      curId = b;
    }
    // Microsecond precision matters for keyset paging, so the cursor carries the timestamp as text.
    const rows = (
      await pool.query(
        `select *, to_char(created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') as cursor_at from notifications
          where user_id = $1 and status <> 'suppressed' and ($4::boolean is not true or read_at is null)
            and ($2::timestamptz is null or (created_at, id) < ($2::timestamptz, $3::uuid))
          order by created_at desc, id desc limit $5`,
        [userId, curAt, curId, q.unreadOnly === 'true', q.limit + 1],
      )
    ).rows;
    const page = rows.slice(0, q.limit);
    const prefs = await loadPrefs(pool, userId);
    const last = page[page.length - 1];
    return { items: page.map((r) => present(r, prefs.locale)), nextCursor: rows.length > q.limit ? `${last.cursor_at}_${last.id}` : null };
  });

  app.get('/notifications/unread-count', authed, async (req) => {
    const r = await pool.query(`select count(*)::int as n from notifications where user_id = $1 and status <> 'suppressed' and read_at is null`, [req.auth!.userId]);
    return { count: r.rows[0].n as number };
  });

  app.post('/notifications/read-all', authed, async (req) => {
    const r = await pool.query(`update notifications set read_at = now() where user_id = $1 and read_at is null and status <> 'suppressed'`, [req.auth!.userId]);
    return { updated: r.rowCount };
  });

  app.post('/notifications/:id/read', authed, async (req) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    // Scoped to the caller: someone else's id is indistinguishable from a missing one.
    const r = await pool.query(`update notifications set read_at = coalesce(read_at, now()) where id = $1 and user_id = $2 and status <> 'suppressed' returning id`, [id, req.auth!.userId]);
    if (!r.rowCount) throw notFound('Notification not found');
    return { ok: true };
  });

  // ---------- preferences (F10-4) ----------
  const prefsResponse = async (userId: string) => {
    const p = await loadPrefs(pool, userId);
    const required = await consentRequired(pool, userId);
    const consent = await loadConsent(pool, userId);
    const explicit = (await pool.query('select 1 from notification_preferences where user_id = $1', [userId])).rowCount! > 0;
    return {
      locale: p.locale,
      localeExplicit: explicit, // false until the user saved a choice; clients then keep following the device language
      channels: p.channels,
      quietHours: p.quietStart && p.quietEnd ? { start: p.quietStart, end: p.quietEnd, timezone: p.timezone } : null,
      timezone: p.timezone,
      disabledTypes: p.disabledTypes,
      types: NOTIFICATION_TYPES.map((type) => ({ type, mandatory: MANDATORY_TYPES.includes(type) })),
      consent: { required, push: consent.push, sms: consent.sms },
    };
  };

  app.get('/notification-preferences', authed, async (req) => prefsResponse(req.auth!.userId));

  app.put('/notification-preferences', authed, async (req) => {
    const b = z
      .object({
        locale: z.enum(LOCALES).optional(),
        channels: z.array(z.enum(['push', 'sms'])).max(2).optional(),
        quietHours: z.object({ start: hhmm, end: hhmm, timezone: z.string().max(60).optional() }).nullable().optional(),
        disabledTypes: z.array(z.string().max(60)).max(50).optional(),
      })
      .parse(req.body ?? {});
    if (b.disabledTypes) assertKnownTypes(b.disabledTypes);
    if (b.quietHours?.timezone && !validZone(b.quietHours.timezone)) throw badRequest('invalid_timezone', 'Unknown time zone');
    if (b.quietHours && b.quietHours.start === b.quietHours.end) throw badRequest('invalid_quiet_hours', 'Quiet hours must have different start and end times');
    const userId = req.auth!.userId;
    const cur = await loadPrefs(pool, userId);
    const next = {
      locale: b.locale ?? cur.locale,
      channels: b.channels ? [...new Set(b.channels)] : cur.channels,
      quietStart: b.quietHours === undefined ? cur.quietStart : (b.quietHours?.start ?? null),
      quietEnd: b.quietHours === undefined ? cur.quietEnd : (b.quietHours?.end ?? null),
      timezone: b.quietHours?.timezone ?? cur.timezone,
      disabledTypes: b.disabledTypes ? [...new Set(b.disabledTypes)] : cur.disabledTypes,
    };
    await pool.query(
      `insert into notification_preferences (user_id, locale, channels, quiet_start, quiet_end, timezone, disabled_types) values ($1,$2,$3,$4,$5,$6,$7)
       on conflict (user_id) do update set locale = excluded.locale, channels = excluded.channels, quiet_start = excluded.quiet_start, quiet_end = excluded.quiet_end,
         timezone = excluded.timezone, disabled_types = excluded.disabled_types, updated_at = now()`,
      [userId, next.locale, next.channels, next.quietStart, next.quietEnd, next.timezone, next.disabledTypes],
    );
    return prefsResponse(userId);
  });

  // ---------- consent (F10-5) ----------
  app.get('/notification-consent', authed, async (req) => {
    const userId = req.auth!.userId;
    return { required: await consentRequired(pool, userId), ...(await loadConsent(pool, userId)) };
  });

  app.put('/notification-consent', authed, async (req) => {
    const b = z
      .object({ push: z.boolean().optional(), sms: z.boolean().optional() })
      .refine((x) => x.push !== undefined || x.sms !== undefined, 'Provide push and/or sms')
      .parse(req.body);
    const userId = req.auth!.userId;
    for (const ch of ['push', 'sms'] as const) {
      if (b[ch] === undefined) continue;
      await pool.query(`insert into notification_consents (user_id, channel, granted, ip) values ($1,$2,$3,$4)`, [userId, ch, b[ch], req.ip]);
    }
    await audit(pool, { actorId: userId, action: 'notification.consent_recorded', targetType: 'user', targetId: userId, metadata: { push: b.push, sms: b.sms }, ip: req.ip });
    return { required: await consentRequired(pool, userId), ...(await loadConsent(pool, userId)) };
  });

  // ---------- devices (push tokens) ----------
  app.post('/devices', authed, async (req, reply) => {
    const b = z.object({ token: z.string().min(8).max(512), platform: z.enum(['android', 'ios', 'web']) }).parse(req.body);
    // A token belongs to exactly one account/session: re-registering moves it (shared phone, new sign-in).
    const r = await pool.query(
      `insert into device_tokens (user_id, session_id, token, platform) values ($1,$2,$3,$4)
       on conflict (token) do update set user_id = excluded.user_id, session_id = excluded.session_id, platform = excluded.platform, revoked_at = null, last_seen_at = now()
       returning id`,
      [req.auth!.userId, req.auth!.sessionId, b.token, b.platform],
    );
    reply.code(201);
    return { id: r.rows[0].id as string };
  });

  const removeDevice = async (userId: string, where: string, value: string) => {
    const r = await pool.query(`update device_tokens set revoked_at = now() where user_id = $1 and ${where} and revoked_at is null`, [userId, value]);
    if (!r.rowCount) throw notFound('Device not found');
  };
  app.delete('/devices/:id', authed, async (req, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    await removeDevice(req.auth!.userId, 'id = $2', id);
    reply.code(204);
  });
  app.delete('/devices', authed, async (req, reply) => {
    const { token } = z.object({ token: z.string().min(8).max(512) }).parse(req.query);
    await removeDevice(req.auth!.userId, 'token = $2', token);
    reply.code(204);
  });
}
