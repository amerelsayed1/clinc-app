// Re-wraps every stored data key and TOTP secret under the CURRENT master key (DOCUMENT_ENCRYPTION_KEY / DOCUMENT_KEY_ID).
// Old keys must still be listed in DOCUMENT_ENCRYPTION_KEYS_OLD while this runs. Safe to re-run. See docs/runbook.md.
import { config } from '../src/config.js';
import { createPool } from '../src/db.js';
import { rotateKeys } from '../src/key-rotation.js';

const pool = createPool();
const r = await rotateKeys(pool);
console.log(`re-wrapped ${r.pages} page keys and ${r.secrets} TOTP secrets to key "${config.documentKeyId}"`);
await pool.end();
