import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { Writable } from 'node:stream';
import { config } from './config.js';
import { AppError } from './errors.js';
import { deviceOf, requestContext } from './request-context.js';

// ---------- rate limiting (F11-4) ----------

export interface RateLimiter {
  /** Counts one hit for `key`. Swap for a shared store (Redis) when running more than one API instance. */
  hit(key: string, limit: number, windowMs: number): { allowed: boolean; retryAfterSeconds: number };
}

export class InMemoryRateLimiter implements RateLimiter {
  private buckets = new Map<string, { count: number; resetAt: number }>();
  hit(key: string, limit: number, windowMs: number) {
    const now = Date.now();
    let b = this.buckets.get(key);
    if (!b || b.resetAt <= now) {
      b = { count: 0, resetAt: now + windowMs };
      this.buckets.set(key, b);
      if (this.buckets.size > 20_000) for (const [k, v] of this.buckets) if (v.resetAt <= now) this.buckets.delete(k);
    }
    b.count++;
    return { allowed: b.count <= limit, retryAfterSeconds: Math.max(1, Math.ceil((b.resetAt - now) / 1000)) };
  }
}

/** Throws 429 when `key` exceeded `limit` hits per window. */
export function enforce(limiter: RateLimiter, key: string, limit: number, windowMs: number, message = 'Too many requests. Try again later.') {
  const r = limiter.hit(key, limit, windowMs);
  if (!r.allowed) throw new AppError(429, 'rate_limited', message, { retryAfterSeconds: r.retryAfterSeconds });
}

/** Per-IP limit for every unauthenticated entry point under /auth (OTP request/verify, MFA, refresh). */
export function registerAuthRateLimit(app: FastifyInstance, limiter: RateLimiter, perMinute: number) {
  app.addHook('onRequest', async (req, reply) => {
    if (!req.url.startsWith('/auth/')) return;
    const r = limiter.hit(`auth:${req.ip}`, perMinute, 60_000);
    if (!r.allowed) {
      reply.header('retry-after', String(r.retryAfterSeconds));
      throw new AppError(429, 'rate_limited', 'Too many requests. Try again later.');
    }
  });
}

// ---------- response headers and request context ----------

export function registerSecurityHooks(app: FastifyInstance) {
  // Carries IP and device into every audit entry written while handling the request.
  app.addHook('onRequest', (req, _reply, done) => {
    requestContext.run({ ip: req.ip, device: deviceOf(req.headers['user-agent']) }, done);
  });
  // Helmet-style headers set by hand: this API only returns JSON and files, never HTML.
  app.addHook('onSend', async (_req, reply, payload) => {
    reply.header('x-content-type-options', 'nosniff');
    reply.header('x-frame-options', 'DENY');
    reply.header('referrer-policy', 'no-referrer');
    reply.header('cross-origin-opener-policy', 'same-origin');
    reply.header('x-permitted-cross-domain-policies', 'none');
    if (!reply.hasHeader('content-security-policy')) reply.header('content-security-policy', "default-src 'none'; frame-ancestors 'none'");
    if (!reply.hasHeader('cache-control')) reply.header('cache-control', 'no-store'); // responses can contain PHI
    if (config.isProd) reply.header('strict-transport-security', 'max-age=31536000; includeSubDomains');
    return payload;
  });
}

// ---------- log redaction (F11-8: no PHI, codes or tokens in logs) ----------

const SENSITIVE_KEYS = ['phone', 'code', 'otp', 'oldCode', 'newCode', 'newPhone', 'token', 'accessToken', 'refreshToken', 'mfaToken', 'recoveryCode', 'recoveryCodes', 'secret', 'password', 'authorization', 'cookie', 'fullName', 'description', 'chiefComplaint', 'diagnosis', 'privateNotes', 'doctorPhone'];

/** Masks signed file links in the path and drops the query string, which can carry phone numbers (patient search). */
export const safeUrl = (url: string) => url.split('?')[0]!.replace(/^\/files\/.+/, '/files/[redacted]');

export function loggerOptions(stream?: Writable) {
  const paths = SENSITIVE_KEYS.flatMap((k) => [k, `*.${k}`, `*.*.${k}`, `req.headers.${k}`]);
  return {
    level: process.env.LOG_LEVEL ?? 'info',
    redact: { paths: ['req.headers.authorization', 'req.headers.cookie', 'req.body', 'body', ...paths], censor: '[redacted]' },
    serializers: {
      req: (req: FastifyRequest) => ({ method: req.method, url: safeUrl(req.url), id: req.id }),
      res: (res: { statusCode: number }) => ({ statusCode: res.statusCode }),
    },
    ...(stream && { stream }),
  };
}

declare module 'fastify' {
  interface FastifyInstance {
    routeTable: { method: string; url: string }[];
  }
}
