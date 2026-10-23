const isProd = process.env.NODE_ENV === 'production';

function required(name: string, devDefault: string): string {
  const v = process.env[name];
  if (v) return v;
  if (isProd) throw new Error(`${name} is required in production`);
  return devDefault;
}

export const config = {
  isProd,
  port: Number(process.env.PORT ?? 3000),
  databaseUrl: required('DATABASE_URL', 'postgres://clinic:clinic@localhost:5432/clinic'),
  jwtSecret: required('JWT_SECRET', 'dev-only-secret-dev-only-secret-dev-only'),
  otpDevEcho: !isProd && process.env.OTP_DEV_ECHO === 'true',
  accessTtlSeconds: 15 * 60,
  refreshTtlSeconds: 30 * 24 * 60 * 60,
  otp: { ttlSeconds: 5 * 60, maxAttempts: 5, maxRequestsPer15Min: 5 },
  storageDir: process.env.STORAGE_DIR ?? '.data/objects',
  // 32-byte master key (base64) that wraps per-file data keys. Required in production.
  documentKey: Buffer.from(required('DOCUMENT_ENCRYPTION_KEY', Buffer.alloc(32, 7).toString('base64')), 'base64'),
  documents: { maxFileBytes: 15 * 1024 * 1024, maxPages: 20, linkTtlSeconds: 10 * 60, patientQuotaBytes: 200 * 1024 * 1024 },
  invitationTtlSeconds: 7 * 24 * 60 * 60,
};
