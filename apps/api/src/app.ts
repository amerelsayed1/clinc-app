import cors from '@fastify/cors';
import jwt from '@fastify/jwt';
import Fastify from 'fastify';
import type pg from 'pg';
import { ZodError } from 'zod';
import { consoleSms, type SmsSender } from './auth.js';
import { config } from './config.js';
import { AppError } from './errors.js';
import { adminRoutes } from './routes/admin.js';
import { authRoutes } from './routes/auth.js';
import { meRoutes } from './routes/me.js';
import { workspaceRoutes } from './routes/workspaces.js';

export async function buildApp(pool: pg.Pool, opts: { sms?: SmsSender; logger?: boolean } = {}) {
  const app = Fastify({ logger: opts.logger ?? false, trustProxy: true });
  await app.register(cors, { origin: config.isProd ? false : true, methods: ['GET', 'POST', 'PATCH', 'DELETE'] });
  await app.register(jwt, { secret: config.jwtSecret });

  app.setErrorHandler((err, _req, reply) => {
    if (err instanceof ZodError) {
      return reply.code(400).send({ error: 'validation_error', message: err.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; ') });
    }
    if (err instanceof AppError) return reply.code(err.status).send({ error: err.code, message: err.message });
    app.log.error(err);
    return reply.code(500).send({ error: 'internal_error', message: 'Something went wrong' });
  });

  const sms = opts.sms ?? consoleSms;
  app.get('/health', async () => ({ ok: true }));
  authRoutes(app, pool, sms);
  meRoutes(app, pool);
  adminRoutes(app, pool);
  workspaceRoutes(app, pool, sms);
  return app;
}
