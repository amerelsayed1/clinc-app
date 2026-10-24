import { buildApp } from './app.js';
import { verifyAllChains } from './audit.js';
import { config } from './config.js';
import { createPool } from './db.js';
import { migrate } from './migrate.js';

const pool = createPool();
await migrate(pool);
const app = await buildApp(pool, { logger: true });
await app.listen({ port: config.port, host: '0.0.0.0' });
setInterval(() => void app.sweepSharing().catch((e) => app.log.error(e)), 10 * 60 * 1000).unref();
// Spec 10: appointment reminders, expiring grants, queued (quiet hours) sends and delivery retries.
setInterval(() => void app.runNotificationJobs().catch((e) => app.log.error(e)), 60 * 1000).unref();
// Spec 11: verify every audit hash chain hourly. A broken chain is logged at error level so alerting can page on it.
setInterval(
  () =>
    void verifyAllChains(pool)
      .then((r) => (r.valid ? app.log.info({ chains: r.chainsChecked, entries: r.entriesChecked }, 'audit chains verified') : app.log.error({ broken: r.chains.filter((c) => !c.valid) }, 'AUDIT CHAIN BROKEN')))
      .catch((e) => app.log.error(e)),
  60 * 60 * 1000,
).unref();
