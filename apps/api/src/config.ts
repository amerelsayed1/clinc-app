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
  invitationTtlSeconds: 7 * 24 * 60 * 60,
};
