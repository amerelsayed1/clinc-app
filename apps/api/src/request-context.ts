import { AsyncLocalStorage } from 'node:async_hooks';

/** Per-request network context so every audit entry carries IP and device without each route passing it. */
export interface RequestContext {
  ip: string | null;
  device: string | null;
}
export const requestContext = new AsyncLocalStorage<RequestContext>();

/** Short, log-safe device description: the user agent trimmed to 200 characters. */
export const deviceOf = (ua: unknown): string | null => (typeof ua === 'string' && ua ? ua.replace(/[\u0000-\u001f]/g, '').slice(0, 200) : null);
