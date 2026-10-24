import { createHmac, randomBytes, randomInt } from 'node:crypto';
import { unwrapKey, wrapKey } from './storage.js';

const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function base32Encode(buf: Buffer): string {
  let bits = 0;
  let value = 0;
  let out = '';
  for (const byte of buf) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

export function base32Decode(s: string): Buffer {
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const ch of s.replace(/=+$/, '').toUpperCase()) {
    const i = B32.indexOf(ch);
    if (i < 0) throw new Error('invalid base32');
    value = (value << 5) | i;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

export const newTotpSecret = () => base32Encode(randomBytes(20));

const STEP = 30;
export const totpStep = (at = Date.now()) => Math.floor(at / 1000 / STEP);

/** RFC 6238 (SHA-1, 6 digits, 30 s). */
export function totpCode(secret: string, step: number): string {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(step));
  const h = createHmac('sha1', base32Decode(secret)).update(counter).digest();
  const b = (i: number) => h[i] ?? 0;
  const off = b(h.length - 1) & 15;
  const n = ((b(off) & 0x7f) << 24) | (b(off + 1) << 16) | (b(off + 2) << 8) | b(off + 3);
  return String(n % 1_000_000).padStart(6, '0');
}

/** Returns the matched step (±1 step of clock drift) or null. Callers reject steps <= the last used one (replay). */
export function verifyTotp(secret: string, code: string, at = Date.now()): number | null {
  if (!/^\d{6}$/.test(code)) return null;
  const now = totpStep(at);
  for (const step of [now, now - 1, now + 1]) if (totpCode(secret, step) === code) return step;
  return null;
}

export const otpauthUrl = (secret: string, account: string) =>
  `otpauth://totp/CareLink:${encodeURIComponent(account)}?secret=${secret}&issuer=CareLink&digits=6&period=30`;

// The TOTP secret is sealed with the current master key (AES-256-GCM); the key id prefix lets keys be rotated.
export function sealSecret(plain: string): string {
  return wrapKey(Buffer.from(plain, 'utf8'));
}
export function openSecret(sealed: string): string {
  return unwrapKey(sealed).toString('utf8');
}

export function newRecoveryCodes(n = 8): string[] {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return Array.from({ length: n }, () => Array.from({ length: 10 }, () => alphabet[randomInt(alphabet.length)]).join(''));
}
