import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: { env: { OTP_DEV_ECHO: 'true', AUTH_RATE_LIMIT_PER_MIN: '100000', STORAGE_DIR: '.data/test-objects' }, globalSetup: ['test/global-setup.ts'], fileParallelism: false, hookTimeout: 30000 },
});
