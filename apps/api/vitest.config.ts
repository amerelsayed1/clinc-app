import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: { env: { OTP_DEV_ECHO: 'true', STORAGE_DIR: '.data/test-objects' }, globalSetup: ['test/global-setup.ts'], fileParallelism: false, hookTimeout: 30000 },
});
