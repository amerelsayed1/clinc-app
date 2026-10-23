import cors from '@fastify/cors';
import multipart from '@fastify/multipart';
import jwt from '@fastify/jwt';
import Fastify from 'fastify';
import type pg from 'pg';
import { ZodError } from 'zod';
import { consoleSms, type SmsSender } from './auth.js';
import { config } from './config.js';
import { AppError } from './errors.js';
import { LocalObjectStore, eicarScanner, type ObjectStore, type Scanner } from './storage.js';
import { adminRoutes } from './routes/admin.js';
import { authRoutes } from './routes/auth.js';
import { documentRoutes } from './routes/documents.js';
import { encounterRoutes } from './routes/encounters.js';
import { meRoutes } from './routes/me.js';
import { appointmentRoutes } from './routes/appointments.js';
import { patientRoutes } from './routes/patients.js';
import { settingsRoutes } from './routes/settings.js';
import { workspaceRoutes } from './routes/workspaces.js';

export async function buildApp(pool: pg.Pool, opts: { sms?: SmsSender; logger?: boolean; store?: ObjectStore; scanner?: Scanner } = {}) {
  // Signed file links travel as a path parameter and exceed the 100-character default.
  const app = Fastify({ logger: opts.logger ?? false, trustProxy: true, routerOptions: { maxParamLength: 600 } });
  await app.register(cors, { origin: config.isProd ? false : true, methods: ['GET', 'POST', 'PATCH', 'DELETE'] });
  await app.register(jwt, { secret: config.jwtSecret });
  await app.register(multipart, { limits: { fileSize: config.documents.maxFileBytes, files: config.documents.maxPages + 1, fields: 20, parts: 60 } });

  app.setErrorHandler((err, _req, reply) => {
    if (err instanceof ZodError) {
      return reply.code(400).send({ error: 'validation_error', message: err.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; ') });
    }
    // Framework errors (oversized upload, malformed body) carry their own 4xx status.
    const status = (err as { statusCode?: number }).statusCode;
    if (!(err instanceof AppError) && status && status >= 400 && status < 500) {
      return reply.code(status).send({ error: (err as { code?: string }).code === 'FST_REQ_FILE_TOO_LARGE' ? 'file_too_large' : 'bad_request', message: (err as Error).message });
    }
    if (err instanceof AppError) return reply.code(err.status).send({ error: err.code, message: err.message, ...(err.details !== undefined && { details: err.details }) });
    app.log.error(err);
    return reply.code(500).send({ error: 'internal_error', message: 'Something went wrong' });
  });

  const sms = opts.sms ?? consoleSms;
  app.get('/health', async () => ({ ok: true }));
  authRoutes(app, pool, sms);
  meRoutes(app, pool);
  adminRoutes(app, pool);
  workspaceRoutes(app, pool, sms);
  patientRoutes(app, pool);
  appointmentRoutes(app, pool);
  settingsRoutes(app, pool);
  encounterRoutes(app, pool);
  documentRoutes(app, pool, opts.store ?? new LocalObjectStore(config.storageDir), opts.scanner ?? eicarScanner);
  return app;
}
