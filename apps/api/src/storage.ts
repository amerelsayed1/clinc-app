import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve, sep } from 'node:path';
import { config } from './config.js';

// ---------- object storage ----------

/** Swap for S3/GCS in production: the rest of the app only sees this interface. */
export interface ObjectStore {
  put(key: string, data: Buffer): Promise<void>;
  get(key: string): Promise<Buffer>;
  delete(key: string): Promise<void>;
}

export class LocalObjectStore implements ObjectStore {
  private root: string;
  constructor(dir: string) {
    this.root = resolve(dir);
  }
  private path(key: string) {
    const p = resolve(join(this.root, key));
    if (!p.startsWith(this.root + sep)) throw new Error('Invalid storage key');
    return p;
  }
  async put(key: string, data: Buffer) {
    const p = this.path(key);
    await mkdir(dirname(p), { recursive: true });
    await writeFile(p, data, { mode: 0o600 });
  }
  get(key: string) {
    return readFile(this.path(key));
  }
  async delete(key: string) {
    await rm(this.path(key), { force: true });
  }
}

// ---------- encryption at rest (envelope: per-file data key wrapped by a master key) ----------

const seal = (key: Buffer, plain: Buffer) => {
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', key, iv);
  const ct = Buffer.concat([c.update(plain), c.final()]);
  return Buffer.concat([iv, c.getAuthTag(), ct]);
};
const unseal = (key: Buffer, blob: Buffer) => {
  const d = createDecipheriv('aes-256-gcm', key, blob.subarray(0, 12));
  d.setAuthTag(blob.subarray(12, 28));
  return Buffer.concat([d.update(blob.subarray(28)), d.final()]);
};

/** Wraps `dataKey` with the current master key; the result is `<keyId>.<base64>` so retired keys can still unwrap old files. */
export function wrapKey(dataKey: Buffer, keyId = config.documentKeyId, masterKey = config.documentKeyring.get(keyId) ?? config.documentKey): string {
  return `${keyId}.${seal(masterKey, dataKey).toString('base64')}`;
}
export function unwrapKey(wrapped: string): Buffer {
  const dot = wrapped.indexOf('.');
  const keyId = dot > 0 ? wrapped.slice(0, dot) : 'v1';
  const key = config.documentKeyring.get(keyId) ?? (keyId === 'v1' ? config.documentKey : undefined);
  if (!key) throw new Error(`Unknown encryption key id "${keyId}"`);
  return unseal(key, Buffer.from(dot > 0 ? wrapped.slice(dot + 1) : wrapped, 'base64'));
}
export const keyIdOf = (wrapped: string) => (wrapped.includes('.') ? wrapped.slice(0, wrapped.indexOf('.')) : 'v1');

export function encryptFile(plain: Buffer) {
  const dataKey = randomBytes(32);
  return { blob: seal(dataKey, plain), wrappedKey: wrapKey(dataKey) };
}
export function decryptFile(blob: Buffer, wrappedKey: string) {
  return unseal(unwrapKey(wrappedKey), blob);
}

// ---------- content sniffing: trust the bytes, not the client's content-type ----------

export type AllowedMime = 'image/jpeg' | 'image/png' | 'image/webp' | 'application/pdf';
export function sniffMime(b: Buffer): AllowedMime | null {
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg';
  if (b.length >= 8 && b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  if (b.length >= 12 && b.subarray(0, 4).toString('latin1') === 'RIFF' && b.subarray(8, 12).toString('latin1') === 'WEBP') return 'image/webp';
  if (b.length >= 5 && b.subarray(0, 5).toString('latin1') === '%PDF-') return 'application/pdf';
  return null;
}

export const sha256Hex = (b: Buffer) => createHash('sha256').update(b).digest('hex');

// ---------- malware scanning hook ----------

export interface Scanner {
  scan(data: Buffer): Promise<'clean' | 'infected'>;
}
const EICAR = 'X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*';
/** Placeholder: only recognises the EICAR test string. Replace with a ClamAV/cloud scanner before real data. */
export const eicarScanner: Scanner = {
  async scan(data) {
    return data.includes(EICAR) ? 'infected' : 'clean';
  },
};
export const EICAR_TEST_STRING = EICAR;

// ---------- short-lived signed file links (F06-5) ----------

export interface LinkClaims {
  d: string; // document id
  p: number; // page
  u: string; // user the link was issued to
  w: string | null; // workspace the viewer acts for (null = patient viewing their own record)
  g?: string; // sharing grant the viewer relies on (spec 08); re-checked when the file is served
  e: number; // expiry, unix seconds
}
const linkKey = () => createHmac('sha256', config.jwtSecret).update('file-link-v1').digest();
const sign = (payload: string) => createHmac('sha256', linkKey()).update(payload).digest('base64url');

export function signLink(c: Omit<LinkClaims, 'e'>, ttl = config.documents.linkTtlSeconds): { token: string; expiresAt: Date } {
  const e = Math.floor(Date.now() / 1000) + ttl;
  const payload = Buffer.from(JSON.stringify({ ...c, e })).toString('base64url');
  return { token: `${payload}.${sign(payload)}`, expiresAt: new Date(e * 1000) };
}

export function verifyLink(token: string): LinkClaims | null {
  const [payload, sig] = token.split('.');
  if (!payload || !sig) return null;
  const expected = sign(payload);
  if (sig.length !== expected.length || !timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) return null;
  try {
    const c = JSON.parse(Buffer.from(payload, 'base64url').toString()) as LinkClaims;
    return c.e > Math.floor(Date.now() / 1000) ? c : null;
  } catch {
    return null;
  }
}
