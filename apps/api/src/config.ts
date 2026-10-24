const isProd = process.env.NODE_ENV === 'production';

function required(name: string, devDefault: string): string {
  const v = process.env[name];
  if (v) return v;
  if (isProd) throw new Error(`${name} is required in production`);
  return devDefault;
}

const DEV_JWT_SECRET = 'dev-only-secret-dev-only-secret-dev-only';
const DEV_DOCUMENT_KEY = Buffer.alloc(32, 7).toString('base64');

/** Refuses to boot a production process that still carries development defaults (F11-4). Pure so it can be tested. */
export function assertProductionConfig(env: Record<string, string | undefined>): void {
  const problems: string[] = [];
  const jwt = env.JWT_SECRET;
  if (!jwt) problems.push('JWT_SECRET is required');
  else if (jwt === DEV_JWT_SECRET || jwt.length < 32) problems.push('JWT_SECRET must be a unique random value of at least 32 characters');
  const key = env.DOCUMENT_ENCRYPTION_KEY;
  if (!key) problems.push('DOCUMENT_ENCRYPTION_KEY is required');
  else if (key === DEV_DOCUMENT_KEY || Buffer.from(key, 'base64').length !== 32) problems.push('DOCUMENT_ENCRYPTION_KEY must be a unique base64-encoded 32-byte key');
  if (!env.DATABASE_URL) problems.push('DATABASE_URL is required');
  else if (env.DATABASE_URL.includes('clinic:clinic@')) problems.push('DATABASE_URL still uses the development credentials');
  if (env.OTP_DEV_ECHO === 'true') problems.push('OTP_DEV_ECHO must not be enabled in production');
  if (problems.length) throw new Error(`Refusing to start in production: ${problems.join('; ')}`);
}
if (isProd) assertProductionConfig(process.env);

/** Parses "id:base64,id2:base64" into a key map. */
function parseKeys(raw: string | undefined): Map<string, Buffer> {
  const m = new Map<string, Buffer>();
  for (const part of (raw ?? '').split(',').map((p) => p.trim()).filter(Boolean)) {
    const [id, b64] = part.split(':');
    if (id && b64) m.set(id, Buffer.from(b64, 'base64'));
  }
  return m;
}
const currentKeyId = process.env.DOCUMENT_KEY_ID ?? 'v1';
const currentKey = Buffer.from(required('DOCUMENT_ENCRYPTION_KEY', DEV_DOCUMENT_KEY), 'base64');
// Retired keys stay available for decryption only. Wrapped keys carry the id of the key that sealed them (`id.base64`);
// anything without a prefix was sealed before key ids existed and counts as id "v1".
const keyring = new Map<string, Buffer>([...parseKeys(process.env.DOCUMENT_ENCRYPTION_KEYS_OLD), [currentKeyId, currentKey]]);

/** X-Forwarded-For is only honoured from configured proxies; trusting it blindly lets clients forge audit IPs and dodge rate limits. */
export function parseTrustProxy(raw: string | undefined): boolean | number | string[] {
  if (!raw || raw === 'false') return false;
  if (raw === 'true') return true;
  if (/^\d+$/.test(raw)) return Number(raw); // number of proxy hops in front of the API
  return raw.split(',').map((s) => s.trim()).filter(Boolean); // proxy addresses / CIDRs
}

export const config = {
  isProd,
  trustProxy: parseTrustProxy(process.env.TRUST_PROXY),
  port: Number(process.env.PORT ?? 3000),
  databaseUrl: required('DATABASE_URL', 'postgres://clinic:clinic@localhost:5432/clinic'),
  jwtSecret: required('JWT_SECRET', DEV_JWT_SECRET),
  otpDevEcho: !isProd && process.env.OTP_DEV_ECHO === 'true',
  accessTtlSeconds: 15 * 60,
  refreshTtlSeconds: 30 * 24 * 60 * 60,
  otp: { ttlSeconds: 5 * 60, maxAttempts: 5, maxRequestsPer15Min: 5 },
  storageDir: process.env.STORAGE_DIR ?? '.data/objects',
  // 32-byte master key (base64) that wraps per-file data keys. Required in production.
  documentKey: currentKey,
  documentKeyId: currentKeyId,
  documentKeyring: keyring,
  documents: { maxFileBytes: 15 * 1024 * 1024, maxPages: 20, linkTtlSeconds: 10 * 60, patientQuotaBytes: 200 * 1024 * 1024 },
  // F08-4/5: defaults and caps. Sensitive categories get a shorter cap and need explicit acknowledgement.
  sharing: { defaultDays: 30, maxDays: 90, sensitiveMaxDays: 14, requestTtlDays: 14, expiringSoonDays: 3, sensitiveCategories: ['encounters'] as readonly string[] },
  invitationTtlSeconds: 7 * 24 * 60 * 60,
  // F11-4: unauthenticated /auth/* calls per IP per minute, and data exports per user.
  rateLimit: { authPerIpPerMinute: Number(process.env.AUTH_RATE_LIMIT_PER_MIN ?? 60), exportsPerUserPerHour: Number(process.env.EXPORT_RATE_LIMIT_PER_HOUR ?? 3) },
  // F11-7 retention policy. Records are tombstoned, never erased, for `clinicalRecordYears`. A legal hold on a
  // patient record overrides every deletion path until the hold is lifted. Values are placeholders pending legal review.
  retention: { clinicalRecordYears: 10, auditLogYears: 10, patientUploadDeletionAllowed: true, legalHoldBlocksDeletion: true },
};
