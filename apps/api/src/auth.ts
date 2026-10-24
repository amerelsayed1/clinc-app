import { createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type pg from 'pg';
import { effectivePermissions, type Permission, type Role } from '@clinic/shared';
import { audit } from './audit.js';
import { config } from './config.js';
import { AppError, forbidden, unauthorized } from './errors.js';

export const sha256 = (s: string) => createHash('sha256').update(s).digest('hex');

export function safeEqual(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

export const newOtp = () => String(randomInt(0, 1_000_000)).padStart(6, '0');
export const newRefreshToken = () => randomBytes(32).toString('base64url');
// Unambiguous alphabet, 10 chars ≈ 50 bits; single-use, phone-bound and expiring.
export const newInviteCode = () => {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return Array.from({ length: 10 }, () => alphabet[randomInt(alphabet.length)]).join('');
};

/** SMS provider boundary. Replace with a real gateway; dev just logs. */
export interface SmsSender {
  send(phone: string, text: string): Promise<void>;
}
export const consoleSms: SmsSender = {
  async send(phone, text) {
    if (!config.isProd) console.log(`[sms] -> ${phone}: ${text}`);
  },
};

export interface AuthContext {
  userId: string;
  sessionId: string;
}
declare module 'fastify' {
  interface FastifyRequest {
    auth?: AuthContext;
    workspace?: WorkspaceContext;
  }
}

export interface WorkspaceContext {
  workspaceId: string;
  membershipId: string;
  role: Role;
  permissions: Permission[];
}

export function signAccess(app: FastifyInstance, userId: string, sessionId: string) {
  return app.jwt.sign({ sub: userId, sid: sessionId }, { expiresIn: config.accessTtlSeconds });
}

export async function createSession(
  app: FastifyInstance,
  pool: pg.Pool,
  userId: string,
  meta: { deviceName?: string; ip?: string },
) {
  const refresh = newRefreshToken();
  const row = (
    await pool.query(
      `insert into sessions (user_id, refresh_hash, device_name, ip, expires_at)
       values ($1,$2,$3,$4, now() + make_interval(secs => $5)) returning id`,
      [userId, sha256(refresh), meta.deviceName ?? null, meta.ip ?? null, config.refreshTtlSeconds],
    )
  ).rows[0];
  return { accessToken: signAccess(app, userId, row.id), refreshToken: refresh, sessionId: row.id as string };
}

/** Verifies the JWT and that its session is still live, so revocation is immediate. */
export function authenticate(pool: pg.Pool) {
  return async (req: FastifyRequest) => {
    let payload: { sub: string; sid: string };
    try {
      payload = await req.jwtVerify();
    } catch {
      throw unauthorized();
    }
    const s = (
      await pool.query('select 1 from sessions where id = $1 and user_id = $2 and revoked_at is null and expires_at > now()', [payload.sid, payload.sub])
    ).rows[0];
    if (!s) throw unauthorized('Session revoked or expired');
    req.auth = { userId: payload.sub, sessionId: payload.sid };
  };
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Refused attempts are written to the workspace chain (F11-1 result=denied), at most once a minute per user/route/permission.
const recentDenials = new Map<string, number>();
async function auditDenied(pool: pg.Pool, req: FastifyRequest, workspaceId: string, role: string, permission: string) {
  const route = req.routeOptions?.url ?? req.url.split('?')[0];
  const key = `${req.auth!.userId}|${req.method}|${route}|${permission}`;
  const now = Date.now();
  if ((recentDenials.get(key) ?? 0) > now - 60_000) return;
  recentDenials.set(key, now);
  if (recentDenials.size > 5000) for (const [k, t] of recentDenials) if (t < now - 60_000) recentDenials.delete(k);
  await audit(pool, { workspaceId, actorId: req.auth!.userId, actorRole: role, action: 'access.denied', result: 'denied', metadata: { permission, method: req.method, route } }).catch(() => undefined);
}

/**
 * Resolves the caller's active workspace membership and effective permissions on every request.
 * Optional `x-workspace-id` selects among several memberships (future multi-clinic users).
 */
export function requireWorkspace(pool: pg.Pool, ...needed: Permission[]) {
  return async (req: FastifyRequest) => {
    if (!req.auth) throw unauthorized();
    const wanted = req.headers['x-workspace-id'];
    if (typeof wanted === 'string' && !UUID.test(wanted)) throw new AppError(400, 'bad_workspace_id', 'x-workspace-id must be a UUID');
    const rows = (
      await pool.query(
        `select m.id, m.workspace_id, m.role, m.denied_permissions, coalesce(d.verification_status = 'verified' and u.mfa_enabled_at is not null, false) as doctor_verified
           from memberships m
           join users u on u.id = m.user_id
           left join doctor_profiles d on d.user_id = m.user_id
          where m.user_id = $1 and m.status = 'active' and ($2::uuid is null or m.workspace_id = $2::uuid)
          order by m.created_at`,
        [req.auth.userId, typeof wanted === 'string' ? wanted : null],
      )
    ).rows;
    const m = rows[0];
    if (!m) throw forbidden('No active workspace membership');
    const permissions = effectivePermissions({ role: m.role, denied: m.denied_permissions, doctorVerified: m.doctor_verified });
    for (const p of needed) {
      if (!permissions.includes(p)) {
        await auditDenied(pool, req, m.workspace_id, m.role, p);
        throw new AppError(403, 'missing_permission', `Missing permission: ${p}`);
      }
    }
    req.workspace = { workspaceId: m.workspace_id, membershipId: m.id, role: m.role, permissions };
  };
}

export type Guard = (req: FastifyRequest, reply: FastifyReply) => Promise<void>;

/** preHandler pair for routes that need a live session and workspace permissions. */
export function workspaceGuard(pool: pg.Pool, ...needed: Permission[]) {
  return { preHandler: [authenticate(pool), requireWorkspace(pool, ...needed)] };
}
