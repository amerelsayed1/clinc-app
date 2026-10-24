import type pg from 'pg';
import { config } from './config.js';
import { keyIdOf, unwrapKey, wrapKey } from './storage.js';

/** Re-wraps every stored data key and TOTP secret under the current master key. Idempotent; file bytes are never touched. */
export async function rotateKeys(pool: pg.Pool) {
  let pages = 0;
  let secrets = 0;
  for (const r of (await pool.query('select document_id, page, wrapped_key from document_pages')).rows) {
    if (keyIdOf(r.wrapped_key) === config.documentKeyId) continue;
    await pool.query('update document_pages set wrapped_key = $3 where document_id = $1 and page = $2', [r.document_id, r.page, wrapKey(unwrapKey(r.wrapped_key))]);
    pages++;
  }
  for (const col of ['totp_secret_enc', 'totp_pending_enc'] as const) {
    for (const r of (await pool.query(`select id, ${col} as v from users where ${col} is not null`)).rows) {
      if (keyIdOf(r.v) === config.documentKeyId) continue;
      await pool.query(`update users set ${col} = $2 where id = $1`, [r.id, wrapKey(unwrapKey(r.v))]);
      secrets++;
    }
  }
  return { pages, secrets };
}
