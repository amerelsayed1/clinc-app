import { createHash } from 'node:crypto';
import type pg from 'pg';
import { z } from 'zod';
import { tx } from './db.js';
import { requestContext } from './request-context.js';

export interface AuditInput {
  workspaceId?: string | null;
  actorId?: string | null;
  actorRole?: string | null;
  action: string;
  targetType?: string;
  targetId?: string;
  metadata?: Record<string, unknown>;
  ip?: string | null;
  /** 'denied' records an attempted but refused action (F11-1). */
  result?: 'success' | 'denied';
  device?: string | null;
}

// jsonb does not preserve key order, so hash over a canonical (sorted) form.
export function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (v && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o).sort().map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`).join(',')}}`;
  }
  return JSON.stringify(v ?? null);
}

interface HashFields {
  chain_key: string;
  seq: number;
  actor_id: string | null;
  actor_role: string | null;
  action: string;
  target_type: string | null;
  target_id: string | null;
  metadata: unknown;
  ip: string | null;
  created_at: Date;
  result?: string | null;
  device?: string | null;
}

export function rowHash(prev: string, r: HashFields): string {
  const base: unknown[] = [r.chain_key, r.seq, r.actor_id, r.actor_role, r.action, r.target_type, r.target_id, r.metadata, r.ip, r.created_at.toISOString()];
  // result and device join the hash only when they carry information, so rows written before migration 010 still verify.
  // Any later change to either field changes the hashed input and is therefore detected.
  if ((r.result ?? 'success') !== 'success' || r.device) base.push(r.result ?? 'success', r.device ?? null);
  return createHash('sha256').update(prev).update(canonical(base)).digest('hex');
}

const GENESIS = '0'.repeat(64);

/** Must run inside a transaction: the advisory lock serialises appends per chain. */
export async function writeAudit(c: pg.PoolClient, e: AuditInput): Promise<void> {
  const chainKey = e.workspaceId ?? 'global';
  await c.query('select pg_advisory_xact_lock(hashtext($1))', [chainKey]);
  const last = (await c.query('select seq, hash from audit_log where chain_key = $1 order by seq desc limit 1', [chainKey])).rows[0];
  const seq = (last?.seq ?? 0) + 1;
  const prev = last?.hash ?? GENESIS;
  const ctx = requestContext.getStore();
  const fields: HashFields = {
    chain_key: chainKey,
    seq,
    actor_id: e.actorId ?? null,
    actor_role: e.actorRole ?? null,
    action: e.action,
    target_type: e.targetType ?? null,
    target_id: e.targetId ?? null,
    // Round-trip through JSON so the hashed form equals what jsonb stores (undefined values would otherwise hash as null).
    metadata: JSON.parse(JSON.stringify(e.metadata ?? {})),
    ip: e.ip ?? ctx?.ip ?? null,
    created_at: new Date(),
    result: e.result ?? 'success',
    device: e.device ?? ctx?.device ?? null,
  };
  await c.query(
    `insert into audit_log (chain_key, seq, workspace_id, actor_id, actor_role, action, target_type, target_id, metadata, ip, created_at, prev_hash, hash, result, device)
     values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)`,
    [chainKey, seq, e.workspaceId ?? null, fields.actor_id, fields.actor_role, e.action, fields.target_type, fields.target_id, JSON.stringify(fields.metadata), fields.ip, fields.created_at, prev, rowHash(prev, fields), fields.result, fields.device],
  );
}

export function audit(pool: pg.Pool, e: AuditInput) {
  return tx(pool, (c) => writeAudit(c, e));
}

export async function verifyChain(pool: pg.Pool, chainKey: string): Promise<{ valid: boolean; checked: number; brokenAtSeq?: number }> {
  const rows = (await pool.query('select * from audit_log where chain_key = $1 order by seq', [chainKey])).rows;
  let prev = GENESIS;
  let expectedSeq = 1;
  for (const r of rows) {
    if (r.seq !== expectedSeq || r.prev_hash !== prev || rowHash(prev, r) !== r.hash) {
      return { valid: false, checked: expectedSeq - 1, brokenAtSeq: r.seq };
    }
    prev = r.hash;
    expectedSeq++;
  }
  return { valid: true, checked: rows.length };
}

export interface ChainReport {
  chainKey: string;
  valid: boolean;
  checked: number;
  brokenAtSeq?: number;
}

/** Verifies every chain in the log (one per workspace plus 'global'). Records the run so history is reviewable. */
export async function verifyAllChains(pool: pg.Pool, triggeredBy = 'job') {
  const keys = (await pool.query('select distinct chain_key from audit_log order by chain_key')).rows.map((r) => r.chain_key as string);
  const chains: ChainReport[] = [];
  for (const k of keys) chains.push({ chainKey: k, ...(await verifyChain(pool, k)) });
  const broken = chains.filter((c) => !c.valid);
  const entries = chains.reduce((n, c) => n + c.checked, 0);
  const run = (
    await pool.query(
      `insert into audit_verifications (triggered_by, chains_checked, entries_checked, valid, broken) values ($1,$2,$3,$4,$5) returning id, ran_at`,
      [triggeredBy, chains.length, entries, broken.length === 0, JSON.stringify(broken)],
    )
  ).rows[0];
  return { id: run.id as string, ranAt: run.ran_at as Date, valid: broken.length === 0, chainsChecked: chains.length, entriesChecked: entries, chains };
}

/**
 * Auth events belong to the global chain, and are mirrored into the chain of every workspace the user
 * actively belongs to so a clinic owner can see staff sign-ins, MFA and session changes (F11-2/F11-3).
 */
export async function writeAuthAudit(c: pg.PoolClient, e: Omit<AuditInput, 'workspaceId'>): Promise<void> {
  await writeAudit(c, e);
  if (!e.actorId) return;
  const ws = (await c.query(`select m.workspace_id, m.role from memberships m where m.user_id = $1 and m.status = 'active'`, [e.actorId])).rows;
  for (const w of ws) await writeAudit(c, { ...e, workspaceId: w.workspace_id, actorRole: e.actorRole ?? w.role });
}
export const auditAuth = (pool: pg.Pool, e: Omit<AuditInput, 'workspaceId'>) => tx(pool, (c) => writeAuthAudit(c, e));

// ---------- reading the log (F11-3) ----------

export const auditFilterSchema = z.object({
  limit: z.coerce.number().int().min(1).max(200).default(50),
  before: z.coerce.number().int().optional(),
  action: z.string().trim().max(80).optional(), // exact, or a prefix when it ends with '.' or '*'
  actor: z.string().uuid().optional(),
  targetType: z.string().trim().max(40).optional(),
  targetId: z.string().trim().max(80).optional(),
  result: z.enum(['success', 'denied']).optional(),
  from: z.string().datetime({ offset: true }).or(z.string().regex(/^\d{4}-\d{2}-\d{2}$/)).optional(),
  to: z.string().datetime({ offset: true }).or(z.string().regex(/^\d{4}-\d{2}-\d{2}$/)).optional(),
});
export type AuditFilter = z.infer<typeof auditFilterSchema>;

export const presentAudit = (r: Record<string, any>) => ({
  seq: r.seq as number,
  action: r.action as string,
  actorId: r.actor_id as string | null,
  actorName: (r.actor_name ?? null) as string | null,
  actorRole: r.actor_role as string | null,
  targetType: r.target_type as string | null,
  targetId: r.target_id as string | null,
  metadata: r.metadata,
  result: r.result as string,
  ip: r.ip as string | null,
  device: r.device as string | null,
  breakGlass: typeof r.action === 'string' && r.action.startsWith('breakglass.'),
  createdAt: r.created_at as Date,
});

export async function queryAudit(pool: pg.Pool, chainKey: string, f: AuditFilter, max = f.limit) {
  const params: unknown[] = [chainKey];
  const where = ['a.chain_key = $1'];
  const add = (sql: string, v: unknown) => {
    params.push(v);
    where.push(sql.replace('?', `$${params.length}`));
  };
  if (f.before !== undefined) add('a.seq < ?', f.before);
  if (f.action) {
    if (/[.*]$/.test(f.action)) add(`a.action like ? escape '!'`, `${f.action.replace(/\*$/, '').replace(/[!%_]/g, '!$&')}%`);
    else add('a.action = ?', f.action);
  }
  if (f.actor) add('a.actor_id = ?', f.actor);
  if (f.targetType) add('a.target_type = ?', f.targetType);
  if (f.targetId) add('a.target_id = ?', f.targetId);
  if (f.result) add('a.result = ?', f.result);
  if (f.from) add('a.created_at >= ?::timestamptz', f.from);
  if (f.to) add(/^\d{4}-\d{2}-\d{2}$/.test(f.to) ? `a.created_at < (?::date + 1)::timestamptz` : 'a.created_at <= ?::timestamptz', f.to);
  params.push(max);
  const rows = (
    await pool.query(
      `select a.*, u.full_name as actor_name from audit_log a left join users u on u.id = a.actor_id
        where ${where.join(' and ')} order by a.seq desc limit $${params.length}`,
      params,
    )
  ).rows;
  return rows;
}
