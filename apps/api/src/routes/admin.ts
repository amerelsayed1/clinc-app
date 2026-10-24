import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { audit, auditFilterSchema, presentAudit, queryAudit, verifyAllChains, verifyChain, writeAudit } from '../audit.js';
import { tx } from '../db.js';
import { authenticate } from '../auth.js';
import { AppError, forbidden, notFound } from '../errors.js';

export function adminRoutes(app: FastifyInstance, pool: pg.Pool) {
  const guard = async (req: Parameters<ReturnType<typeof authenticate>>[0]) => {
    await authenticate(pool)(req);
    const u = (await pool.query('select is_platform_admin from users where id = $1', [req.auth!.userId])).rows[0];
    if (!u?.is_platform_admin) {
      await audit(pool, { actorId: req.auth!.userId, action: 'admin.denied', result: 'denied', metadata: { method: req.method, route: req.routeOptions?.url } }).catch(() => undefined);
      throw forbidden('Platform admin only');
    }
  };

  // Break-glass, chain verification and workspace listing additionally require the admin's second factor (F11-3).
  const strictGuard = async (req: Parameters<typeof guard>[0]) => {
    await guard(req);
    const u = (await pool.query('select mfa_enabled_at from users where id = $1', [req.auth!.userId])).rows[0];
    if (!u?.mfa_enabled_at) throw new AppError(403, 'mfa_required', 'Enable multi-factor authentication to use this function');
  };
  const strict = { preHandler: strictGuard };

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

  // ---------- F11-3: break-glass access to a workspace's audit log ----------

  // Names only: enough to pick a clinic, no clinical or patient data.
  app.get('/admin/workspaces', strict, async () => {
    const rows = (await pool.query(`select w.id, w.name, w.created_at, u.full_name as owner_name from workspaces w join users u on u.id = w.owner_id order by w.created_at desc limit 500`)).rows;
    return rows.map((r) => ({ id: r.id, name: r.name, ownerName: r.owner_name, createdAt: r.created_at }));
  });

  app.post('/admin/break-glass', strict, async (req, reply) => {
    const body = z
      .object({ workspaceId: z.string().uuid(), justification: z.string().trim().min(15).max(1000), minutes: z.number().int().min(1).max(60).default(30) })
      .parse(req.body);
    const adminId = req.auth!.userId;
    const out = await tx(pool, async (c) => {
      if (!(await c.query('select 1 from workspaces where id = $1', [body.workspaceId])).rowCount) throw notFound('Workspace not found');
      const g = (
        await c.query(
          `insert into break_glass_access (admin_id, workspace_id, justification, expires_at) values ($1,$2,$3, now() + make_interval(mins => $4)) returning id, expires_at`,
          [adminId, body.workspaceId, body.justification, body.minutes],
        )
      ).rows[0];
      // Written to the workspace's own chain so its owner sees it (F11-3).
      await writeAudit(c, { workspaceId: body.workspaceId, actorId: adminId, actorRole: 'platform_admin', action: 'breakglass.granted', targetType: 'break_glass', targetId: g.id, metadata: { justification: body.justification, minutes: body.minutes, expiresAt: g.expires_at }, ip: req.ip });
      return g;
    });
    reply.code(201);
    return { id: out.id, workspaceId: body.workspaceId, expiresAt: out.expires_at };
  });

  app.get('/admin/break-glass', strict, async (req) => {
    const rows = (
      await pool.query(
        `select b.id, b.workspace_id, b.justification, b.expires_at, b.revoked_at, b.created_at, w.name as workspace_name
           from break_glass_access b join workspaces w on w.id = b.workspace_id where b.admin_id = $1 order by b.created_at desc limit 50`,
        [req.auth!.userId],
      )
    ).rows;
    return rows.map((r) => ({ id: r.id, workspaceId: r.workspace_id, workspaceName: r.workspace_name, justification: r.justification, createdAt: r.created_at, expiresAt: r.expires_at, active: !r.revoked_at && r.expires_at > new Date() }));
  });

  app.delete('/admin/break-glass/:id', strict, async (req, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    await tx(pool, async (c) => {
      const r = await c.query(`update break_glass_access set revoked_at = now() where id = $1 and admin_id = $2 and revoked_at is null returning workspace_id`, [id, req.auth!.userId]);
      if (!r.rowCount) throw notFound('Access record not found');
      await writeAudit(c, { workspaceId: r.rows[0].workspace_id, actorId: req.auth!.userId, actorRole: 'platform_admin', action: 'breakglass.revoked', targetType: 'break_glass', targetId: id, ip: req.ip });
    });
    reply.code(204);
  });

  app.get('/admin/workspaces/:id/audit', strict, async (req) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const q = auditFilterSchema.parse(req.query);
    const adminId = req.auth!.userId;
    if (!(await pool.query('select 1 from workspaces where id = $1', [id])).rowCount) throw notFound('Workspace not found');
    const grant = (
      await pool.query(`select id, expires_at from break_glass_access where admin_id = $1 and workspace_id = $2 and revoked_at is null and expires_at > now() order by expires_at desc limit 1`, [adminId, id])
    ).rows[0];
    if (!grant) {
      await audit(pool, { workspaceId: id, actorId: adminId, actorRole: 'platform_admin', action: 'breakglass.denied', result: 'denied', targetType: 'workspace', targetId: id, ip: req.ip });
      throw new AppError(403, 'break_glass_required', 'Break-glass access with a justification is required to read this clinic\'s audit log');
    }
    const rows = await queryAudit(pool, id, q);
    await audit(pool, { workspaceId: id, actorId: adminId, actorRole: 'platform_admin', action: 'breakglass.audit_read', targetType: 'break_glass', targetId: grant.id, metadata: { rows: rows.length }, ip: req.ip });
    return { accessId: grant.id, accessExpiresAt: grant.expires_at, chain: await verifyChain(pool, id), entries: rows.map(presentAudit) };
  });

  // ---------- F11-1: chain verification across every chain ----------

  app.get('/admin/audit/verify', strict, async (req) => {
    const run = await verifyAllChains(pool, req.auth!.userId);
    await audit(pool, { actorId: req.auth!.userId, actorRole: 'platform_admin', action: 'audit.chain_verified', targetType: 'audit_verification', targetId: run.id, metadata: { valid: run.valid, chains: run.chainsChecked }, ip: req.ip });
    return run;
  });

  app.get('/admin/audit/verifications', strict, async () => {
    const rows = (await pool.query('select * from audit_verifications order by ran_at desc limit 30')).rows;
    return rows.map((r) => ({ id: r.id, ranAt: r.ran_at, triggeredBy: r.triggered_by === 'job' ? 'job' : 'admin', chainsChecked: r.chains_checked, entriesChecked: r.entries_checked, valid: r.valid, broken: r.broken }));
  });
}
