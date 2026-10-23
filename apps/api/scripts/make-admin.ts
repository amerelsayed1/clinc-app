// Usage: npm run make-admin -w @clinic/api -- +201001234567
import { createPool } from '../src/db.js';

const phone = process.argv[2];
if (!phone) throw new Error('Usage: make-admin <phone>');
const pool = createPool();
const r = await pool.query('update users set is_platform_admin = true where phone = $1', [phone]);
console.log(r.rowCount ? `${phone} is now a platform admin` : 'No user with that phone (sign in once first)');
await pool.end();
