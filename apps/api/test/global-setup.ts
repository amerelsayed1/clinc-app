import pg from 'pg';
import { createPool } from '../src/db.js';
import { migrate } from '../src/migrate.js';

export const TEST_DB_URL = process.env.TEST_DATABASE_URL ?? 'postgres://clinic:clinic@localhost:5432/clinic_test';

export default async function setup() {
  const admin = new pg.Client({ connectionString: TEST_DB_URL.replace(/\/[^/]+$/, '/postgres') });
  await admin.connect();
  await admin.query('drop database if exists clinic_test with (force)');
  await admin.query('create database clinic_test');
  await admin.end();
  const pool = createPool(TEST_DB_URL);
  await migrate(pool);
  await pool.end();
}
