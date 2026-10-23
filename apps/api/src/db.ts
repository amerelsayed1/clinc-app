import pg from 'pg';
import { config } from './config.js';

export type Db = Pick<pg.Pool, 'query'>;

export function createPool(url = config.databaseUrl) {
  return new pg.Pool({ connectionString: url });
}

export async function tx<T>(pool: pg.Pool, fn: (c: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('begin');
    const out = await fn(client);
    await client.query('commit');
    return out;
  } catch (e) {
    await client.query('rollback');
    throw e;
  } finally {
    client.release();
  }
}
