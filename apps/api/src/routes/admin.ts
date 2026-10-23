import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { audit } from '../audit.js';
import { authenticate } from '../auth.js';
import { forbidden, notFound } from '../errors.js';

export function adminRoutes(app: FastifyInstance, pool: pg.Pool) {
  const guard = async (req: Parameters<ReturnType<typeof authenticate>>[0]) => {
    await authenticate(pool)(req);
    const u = (await pool.query('select is_platform_admin from users where id = $1', [req.auth!.userId])).rows[0];
    if (!u?.is_platform_admin) throw forbidden('Platform admin only');
  };

  app.get('/admin/doctors', { preHandler: guard }, async (req) => {
    const { status } = z.object({ status: z.enum(['pending', 'verified', 'rejected']).default('pending') }).parse(req.query);
    const rows = (
      await pool.query(
        `select d.user_id, u.full_name, u.phone, d.license_number, d.verification_status, d.created_at
           from doctor_profiles d join users u on u.id = d.user_id where d.verification_status = $1 order by d.created_at`,
        [status],
      )
    ).rows;
    return rows.map((r) => ({ userId: r.user_id, fullName: r.full_name, phone: r.phone, licenseNumber: r.license_number, status: r.verification_status, createdAt: r.created_at }));
  });

  app.post('/admin/doctors/:userId/decision', { preHandler: guard }, async (req) => {
    const { userId } = z.object({ userId: z.string().uuid() }).parse(req.params);
    const { decision, note } = z.object({ decision: z.enum(['verified', 'rejected']), note: z.string().max(500).optional() }).parse(req.body);
    const r = await pool.query(
      `update doctor_profiles set verification_status = $2, verification_note = $3, verified_by = $4, verified_at = now() where user_id = $1`,
      [userId, decision, note ?? null, req.auth!.userId],
    );
    if (r.rowCount === 0) throw notFound('Doctor profile not found');
    await audit(pool, { actorId: req.auth!.userId, actorRole: 'platform_admin', action: `doctor.${decision}`, targetType: 'user', targetId: userId, metadata: { note }, ip: req.ip });
    return { ok: true };
  });
}
