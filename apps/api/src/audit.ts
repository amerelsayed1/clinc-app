import { createHash } from 'node:crypto';
import type pg from 'pg';
import { tx } from './db.js';

export interface AuditInput {
  workspaceId?: string | null;
  actorId?: string | null;
  actorRole?: string | null;
  action: string;
  targetType?: string;
  targetId?: string;
  metadata?: Record<string, unknown>;
  ip?: string | null;
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
}

export function rowHash(prev: string, r: HashFields): string {
  return createHash('sha256')
    .update(prev)
    .update(
      canonical([r.chain_key, r.seq, r.actor_id, r.actor_role, r.action, r.target_type, r.target_id, r.metadata, r.ip, r.created_at.toISOString()]),
    )
    .digest('hex');
}

const GENESIS = '0'.repeat(64);

/** Must run inside a transaction: the advisory lock serialises appends per chain. */
export async function writeAudit(c: pg.PoolClient, e: AuditInput): Promise<void> {
  const chainKey = e.workspaceId ?? 'global';
  await c.query('select pg_advisory_xact_lock(hashtext($1))', [chainKey]);
  const last = (await c.query('select seq, hash from audit_log where chain_key = $1 order by seq desc limit 1', [chainKey])).rows[0];
  const seq = (last?.seq ?? 0) + 1;
  const prev = last?.hash ?? GENESIS;
  const fields: HashFields = {
    chain_key: chainKey,
    seq,
    actor_id: e.actorId ?? null,
    actor_role: e.actorRole ?? null,
    action: e.action,
    target_type: e.targetType ?? null,
    target_id: e.targetId ?? null,
    metadata: e.metadata ?? {},
    ip: e.ip ?? null,
    created_at: new Date(),
  };
  await c.query(
    `insert into audit_log (chain_key, seq, workspace_id, actor_id, actor_role, action, target_type, target_id, metadata, ip, created_at, prev_hash, hash)
     values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`,
    [chainKey, seq, e.workspaceId ?? null, fields.actor_id, fields.actor_role, e.action, fields.target_type, fields.target_id, JSON.stringify(fields.metadata), fields.ip, fields.created_at, prev, rowHash(prev, fields)],
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
