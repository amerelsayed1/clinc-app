import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { effectivePermissions } from '@clinic/shared';
import { audit } from '../audit.js';
import { authenticate } from '../auth.js';
import { conflict } from '../errors.js';

export function meRoutes(app: FastifyInstance, pool: pg.Pool) {
  const authed = { preHandler: authenticate(pool) };

  app.get('/me', authed, async (req) => {
    const userId = req.auth!.userId;
    const user = (await pool.query('select id, phone, full_name, is_platform_admin, mfa_enabled_at from users where id = $1', [userId])).rows[0];
    const doctor = (await pool.query('select license_number, verification_status, verification_note from doctor_profiles where user_id = $1', [userId])).rows[0];
    const memberships = (
      await pool.query(
        `select m.id, m.workspace_id, m.role, m.denied_permissions, w.name as workspace_name
           from memberships m join workspaces w on w.id = m.workspace_id
          where m.user_id = $1 and m.status = 'active' order by m.created_at`,
        [userId],
      )
    ).rows;
    const mfaEnabled = !!user.mfa_enabled_at;
    const verified = doctor?.verification_status === 'verified' && mfaEnabled; // F01-3: clinical actions need a verified licence and MFA
    return {
      id: user.id,
      phone: user.phone,
      fullName: user.full_name,
      isPlatformAdmin: user.is_platform_admin,
      mfaEnabled,
      mfaRequired: !!doctor || user.is_platform_admin,
      doctorProfile: doctor ? { licenseNumber: doctor.license_number, verificationStatus: doctor.verification_status, verificationNote: doctor.verification_note } : null,
      memberships: memberships.map((m) => ({
        id: m.id,
        workspaceId: m.workspace_id,
        workspaceName: m.workspace_name,
        role: m.role,
        permissions: effectivePermissions({ role: m.role, denied: m.denied_permissions, doctorVerified: verified }),
      })),
    };
  });

  app.patch('/me', authed, async (req) => {
    const { fullName } = z.object({ fullName: z.string().trim().min(2).max(120) }).parse(req.body);
    await pool.query('update users set full_name = $2 where id = $1', [req.auth!.userId, fullName]);
    return { ok: true };
  });

  // Becoming a doctor: allowed immediately, but clinical actions stay disabled until an admin verifies the licence.
  app.post('/doctors/register', authed, async (req, reply) => {
    const body = z.object({ fullName: z.string().trim().min(2).max(120), licenseNumber: z.string().trim().min(3).max(50) }).parse(req.body);
    const userId = req.auth!.userId;
    const existing = await pool.query('select 1 from doctor_profiles where user_id = $1', [userId]);
    if (existing.rowCount) throw conflict('already_registered', 'Doctor profile already exists');
    await pool.query('update users set full_name = $2 where id = $1', [userId, body.fullName]);
    await pool.query('insert into doctor_profiles (user_id, license_number) values ($1,$2)', [userId, body.licenseNumber]);
    await audit(pool, { actorId: userId, action: 'doctor.registered', targetType: 'user', targetId: userId, ip: req.ip });
    reply.code(201);
    return { verificationStatus: 'pending' };
  });
}
