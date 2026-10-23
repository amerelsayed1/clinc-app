import { buildApp } from './app.js';
import { config } from './config.js';
import { createPool } from './db.js';
import { migrate } from './migrate.js';

const pool = createPool();
await migrate(pool);
const app = await buildApp(pool, { logger: true });
await app.listen({ port: config.port, host: '0.0.0.0' });
