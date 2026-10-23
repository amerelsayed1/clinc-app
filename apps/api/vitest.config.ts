import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: { env: { OTP_DEV_ECHO: 'true' }, globalSetup: ['test/global-setup.ts'], fileParallelism: false, hookTimeout: 30000 },
});
