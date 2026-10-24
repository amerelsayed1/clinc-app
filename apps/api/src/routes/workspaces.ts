import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { PERMISSIONS, ROLE_DEFAULTS, effectivePermissions, type Role } from '@clinic/shared';
import { audit, auditFilterSchema, presentAudit, queryAudit, verifyChain, writeAudit } from '../audit.js';
import { authenticate, newInviteCode, requireWorkspace, sha256, type SmsSender } from '../auth.js';
import { config } from '../config.js';
import { tx } from '../db.js';
import { badRequest, conflict, forbidden, notFound } from '../errors.js';
import { phoneSchema } from './auth.js';

export function workspaceRoutes(app: FastifyInstance, pool: pg.Pool, sms: SmsSender) {
  const authed = { preHandler: authenticate(pool) };
  const guard = (...p: Parameters<typeof requireWorkspace> extends [unknown, ...infer R] ? R : never) => ({
    preHandler: [authenticate(pool), requireWorkspace(pool, ...(p as never[]))],
  });

  // F02-1: creating a workspace makes the doctor its owner. One per doctor in the MVP.
  app.post('/workspaces', authed, async (req, reply) => {
    const { name } = z.object({ name: z.string().trim().min(2).max(120).optional() }).parse(req.body ?? {});
    const userId = req.auth!.userId;
    const doctor = (await pool.query('select 1 from doctor_profiles where user_id = $1', [userId])).rows[0];
    if (!doctor) throw forbidden('Register as a doctor first');
    const out = await tx(pool, async (c) => {
      const dup = await c.query('select 1 from workspaces where owner_id = $1', [userId]);
      if (dup.rowCount) throw conflict('workspace_exists', 'You already own a workspace');
      const w = (await c.query('insert into workspaces (name, owner_id) values ($1,$2) returning id', [name ?? null, userId])).rows[0];
      await c.query(`insert into memberships (workspace_id, user_id, role) values ($1,$2,'doctor')`, [w.id, userId]);
      await writeAudit(c, { workspaceId: w.id, actorId: userId, actorRole: 'doctor', action: 'workspace.created', targetType: 'workspace', targetId: w.id, ip: req.ip });
      return w.id as string;
    });
    reply.code(201);
    return { id: out };
  });

  app.get('/workspace', guard(), async (req) => {
    const ws = req.workspace!;
    const w = (await pool.query('select id, name, owner_id, created_at from workspaces where id = $1', [ws.workspaceId])).rows[0];
    return { id: w.id, name: w.name, ownerId: w.owner_id, createdAt: w.created_at, myRole: ws.role, myPermissions: ws.permissions };
  });

  app.get('/workspace/members', guard(), async (req) => {
    const rows = (
      await pool.query(
        `select m.id, m.user_id, m.role, m.status, m.denied_permissions, m.created_at, u.full_name, u.phone,
                coalesce(d.verification_status = 'verified' and u.mfa_enabled_at is not null, false) as doctor_verified
           from memberships m join users u on u.id = m.user_id left join doctor_profiles d on d.user_id = m.user_id
          where m.workspace_id = $1 and m.status <> 'removed' order by m.created_at`,
        [req.workspace!.workspaceId],
      )
    ).rows;
    return rows.map((m) => ({
      id: m.id,
      userId: m.user_id,
      fullName: m.full_name,
      phone: m.phone,
      role: m.role,
      status: m.status,
      deniedPermissions: m.denied_permissions,
      permissions: effectivePermissions({ role: m.role, denied: m.denied_permissions, doctorVerified: m.doctor_verified }),
      createdAt: m.created_at,
    }));
  });

  // F02-2: invitations are phone-bound, single-use and expiring. The code is returned once to the inviter.
  app.post('/workspace/invitations', guard('staff.manage'), async (req, reply) => {
    const body = z.object({ phone: phoneSchema, role: z.enum(['nurse', 'receptionist']) }).parse(req.body);
    const ws = req.workspace!;
    const code = newInviteCode();
    const inv = (
      await tx(pool, async (c) => {
        const r = await c.query(
          `insert into invitations (workspace_id, phone, role, code_hash, invited_by, expires_at)
           values ($1,$2,$3,$4,$5, now() + make_interval(secs => $6)) returning id, expires_at`,
          [ws.workspaceId, body.phone, body.role, sha256(code), req.auth!.userId, config.invitationTtlSeconds],
        );
        await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: 'invitation.sent', targetType: 'invitation', targetId: r.rows[0].id, metadata: { phone: body.phone, role: body.role }, ip: req.ip });
        return r;
      })
    ).rows[0];
    await sms.send(body.phone, `You were invited to a clinic workspace. Sign in and enter code ${code}`);
    // In-app notice for invitees who already have an account (the SMS above carries the code).
    const invitee = (await pool.query('select id from users where phone = $1', [body.phone])).rows[0];
    if (invitee) {
      const w = (await pool.query('select name from workspaces where id = $1', [ws.workspaceId])).rows[0];
      await app.notifier.notify({ userId: invitee.id, type: 'staff_invited', key: `staff-invited:${inv.id}`, params: { clinicName: w?.name ?? '', role: body.role, invitationId: inv.id } });
    }
    reply.code(201);
    return { id: inv.id, code, expiresAt: inv.expires_at };
  });

  app.get('/workspace/invitations', guard('staff.manage'), async (req) => {
    const rows = (
      await pool.query(
        `select id, phone, role, expires_at, created_at from invitations
          where workspace_id = $1 and accepted_at is null and revoked_at is null and expires_at > now() order by created_at desc`,
        [req.workspace!.workspaceId],
      )
    ).rows;
    return rows.map((r) => ({ id: r.id, phone: r.phone, role: r.role, expiresAt: r.expires_at, createdAt: r.created_at }));
  });

  app.delete('/workspace/invitations/:id', guard('staff.manage'), async (req, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const ws = req.workspace!;
    const r = await pool.query('update invitations set revoked_at = now() where id = $1 and workspace_id = $2 and accepted_at is null and revoked_at is null', [id, ws.workspaceId]);
    if (r.rowCount === 0) throw notFound('Invitation not found');
    await audit(pool, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: 'invitation.revoked', targetType: 'invitation', targetId: id, ip: req.ip });
    reply.code(204);
  });

  app.post('/invitations/accept', authed, async (req) => {
    const { code } = z.object({ code: z.string().trim().toUpperCase().min(6).max(20) }).parse(req.body);
    const userId = req.auth!.userId;
    const out = await tx(pool, async (c) => {
      const inv = (await c.query('select * from invitations where code_hash = $1 for update', [sha256(code)])).rows[0];
      const user = (await c.query('select phone from users where id = $1', [userId])).rows[0];
      // Same error for every failure so codes cannot be probed.
      const bad = () => badRequest('invalid_invitation', 'Invitation is invalid, expired, or not for this phone number');
      if (!inv || inv.accepted_at || inv.revoked_at || inv.expires_at < new Date() || inv.phone !== user.phone) throw bad();
      await c.query('update invitations set accepted_at = now() where id = $1', [inv.id]);
      const m = (
        await c.query(
          `insert into memberships (workspace_id, user_id, role) values ($1,$2,$3)
           on conflict (workspace_id, user_id) do update set role = excluded.role, status = 'active', denied_permissions = '{}' returning id`,
          [inv.workspace_id, userId, inv.role],
        )
      ).rows[0];
      await writeAudit(c, { workspaceId: inv.workspace_id, actorId: userId, actorRole: inv.role, action: 'invitation.accepted', targetType: 'membership', targetId: m.id, ip: req.ip });
      return { workspaceId: inv.workspace_id, role: inv.role as Role, invitationId: inv.id as string, invitedBy: inv.invited_by as string };
    });
    await app.notifier.notify({ userId: out.invitedBy, type: 'staff_joined', key: `staff-joined:${out.invitationId}`, params: { role: out.role, invitationId: out.invitationId } });
    return { workspaceId: out.workspaceId, role: out.role };
  });

  // F02-3/4: per-staff permission denials, suspension, removal. Access ends on the very next request.
  app.patch('/workspace/members/:id', guard('staff.manage'), async (req) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const body = z
      .object({ deniedPermissions: z.array(z.enum(PERMISSIONS)).optional(), status: z.enum(['active', 'suspended']).optional() })
      .refine((b) => b.deniedPermissions !== undefined || b.status !== undefined, 'Nothing to update')
      .parse(req.body);
    const ws = req.workspace!;
    const m = (await pool.query(`select * from memberships where id = $1 and workspace_id = $2 and status <> 'removed'`, [id, ws.workspaceId])).rows[0];
    if (!m) throw notFound('Member not found');
    if (m.role === 'doctor') throw forbidden('The workspace owner cannot be modified');
    const allowed = new Set(ROLE_DEFAULTS[m.role as Role]);
    const denied = body.deniedPermissions?.filter((p) => allowed.has(p)) ?? m.denied_permissions;
    const status = body.status ?? m.status;
    await tx(pool, async (c) => {
      await c.query('update memberships set denied_permissions = $2, status = $3 where id = $1', [id, denied, status]);
      await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: 'member.updated', targetType: 'membership', targetId: id, metadata: { deniedPermissions: denied, status }, ip: req.ip });
    });
    return { ok: true };
  });

  app.delete('/workspace/members/:id', guard('staff.manage'), async (req, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const ws = req.workspace!;
    const m = (await pool.query(`select role from memberships where id = $1 and workspace_id = $2 and status <> 'removed'`, [id, ws.workspaceId])).rows[0];
    if (!m) throw notFound('Member not found');
    if (m.role === 'doctor') throw forbidden('The workspace owner cannot be removed');
    await tx(pool, async (c) => {
      await c.query(`update memberships set status = 'removed' where id = $1`, [id]);
      await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: 'member.removed', targetType: 'membership', targetId: id, ip: req.ip });
    });
    reply.code(204);
  });

  // F11-3: filterable view of the workspace's own chain. Reading it is not itself audited (it would drown the log).
  app.get('/workspace/audit', guard('audit.read'), async (req) => {
    const q = auditFilterSchema.parse(req.query);
    return (await queryAudit(pool, req.workspace!.workspaceId, q)).map(presentAudit);
  });

  // JSON export for external review. The export is itself an audited event and carries the chain verification result.
  app.get('/workspace/audit/export', guard('audit.read'), async (req, reply) => {
    const q = auditFilterSchema.parse(req.query);
    const ws = req.workspace!;
    const rows = await queryAudit(pool, ws.workspaceId, q, 5000);
    await tx(pool, (c) =>
      writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: 'audit.exported', targetType: 'workspace', targetId: ws.workspaceId, metadata: { filters: { ...q, limit: undefined }, rows: rows.length }, ip: req.ip }),
    );
    reply.header('content-disposition', `attachment; filename="audit-${ws.workspaceId}.json"`);
    return {
      exportedAt: new Date().toISOString(),
      workspaceId: ws.workspaceId,
      filters: q,
      chain: await verifyChain(pool, ws.workspaceId),
      entries: rows.map((r) => ({ ...presentAudit(r), prevHash: r.prev_hash, hash: r.hash })),
    };
  });

  app.get('/workspace/audit/verify', guard('audit.read'), async (req) => verifyChain(pool, req.workspace!.workspaceId));
}
