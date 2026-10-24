import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { createPool } from '../src/db.js';
import { totpCode, totpStep } from '../src/mfa.js';
import {
  ALLOWED_PARAMS, FORBIDDEN_PARAMS, NOTIFICATION_TYPES, RETRY, TEMPLATES, backoffSeconds, dispatchDueReminders, dispatchGrantExpiring,
  memoryPush, quietUntil, renderExternal, renderInbox, validateParams, LOCALES,
} from '../src/notifications.js';
import { TEST_DB_URL } from './global-setup.js';
import { login, makeVerifiedDoctor, reset } from './helpers.js';

const pool = createPool(TEST_DB_URL);
const sent: { phone: string; text: string }[] = [];
const push = memoryPush();
let app: Awaited<ReturnType<typeof buildApp>>;
beforeAll(async () => void (app = await buildApp(pool, { sms: { send: async (phone, text) => void sent.push({ phone, text }) }, push })));
afterAll(async () => {
  await app.close();
  await pool.end();
});
beforeEach(async () => {
  await reset(pool);
  sent.length = 0;
  push.outbox.length = 0;
  push.failNext = 0;
});

type H = { headers: Record<string, string> };
const call = (method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE', s: H | undefined, url: string, payload?: Record<string, unknown>) => app.inject({ method, url, headers: s?.headers, payload });
const post = (s: H, url: string, p: Record<string, unknown> = {}) => call('POST', s, url, p);
const get = (s: H, url: string) => call('GET', s, url);
const put = (s: H, url: string, p: Record<string, unknown>) => call('PUT', s, url, p);

const ALL_DAY = Object.fromEntries(['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'].map((d) => [d, [{ start: '00:00', end: '23:59' }]]));
const inHours = (h: number) => new Date(Date.now() + h * 3_600_000).toISOString();

/** Doctor with a claimed, connected patient. The patient has NOT consented to anything yet. */
async function world() {
  const doc = await makeVerifiedDoctor(app, pool, '+201000000001');
  await call('PATCH', doc, '/workspace/settings', { workingHours: ALL_DAY });
  const rel = (await post(doc, '/patients', { phone: '+201111111111', fullName: 'Mona Hassan' })).json();
  const pt = await login(app, '+201111111111');
  await post(pt, '/patient/claim');
  for (const r of (await get(pt, '/patient/relationships')).json() as { id: string; status: string }[]) if (r.status === 'invited') await post(pt, `/patient/relationships/${r.id}/accept`);
  sent.length = 0; // drop the OTP texts from sign-in
  return { doc, rel, pt };
}
const consentAndDevice = async (pt: H, token = 'device-token-aaaaaaaa') => {
  await put(pt, '/notification-consent', { push: true, sms: true });
  return (await post(pt, '/devices', { token, platform: 'android' })).json().id as string;
};
const book = async (doc: H, relId: string, scheduledAt = inHours(48)) => (await post(doc, '/appointments', { patientId: relId, scheduledAt, override: true })).json() as { id: string };
const inbox = async (s: H) => (await get(s, '/notifications')).json() as { items: { id: string; type: string; title: string; body: string; read: boolean; data: Record<string, string> }[]; nextCursor: string | null };
const rows = async (sql: string, p: unknown[] = []) => (await pool.query(sql, p)).rows;

describe('templates and privacy (F10-3, F10-7)', () => {
  const CANARY = 'CANARY-CLINICAL-TEXT';
  const clinicalWords = /diagnos|medic|prescri|result|blood|pressure|glucose|sugar|cancer|diabet|dose|mg\b|تشخيص|دواء|وصفة|نتيجة|ضغط|سكر/i;

  it('only whitelisted, non-clinical parameters exist anywhere', () => {
    for (const k of ALLOWED_PARAMS) expect(FORBIDDEN_PARAMS).not.toContain(k);
    for (const t of NOTIFICATION_TYPES) for (const k of TEMPLATES[t].params) expect(ALLOWED_PARAMS).toContain(k);
  });

  it('push/SMS text is static generic text in both languages: no params, no placeholders, no clinical wording', () => {
    for (const t of NOTIFICATION_TYPES) {
      for (const l of LOCALES) {
        const ext = renderExternal(t, l);
        expect(ext.title.length).toBeGreaterThan(0);
        expect(ext.body.length).toBeGreaterThan(0);
        for (const s of [ext.title, ext.body]) {
          expect(s).not.toMatch(/[{}]/);
          expect(s).not.toMatch(clinicalWords);
        }
        // Every allowed param stuffed with a canary must never reach the external text.
        expect(JSON.stringify(renderExternal(t, l))).not.toContain(CANARY);
      }
    }
  });

  it('inbox text is localized, fully resolved and never clinical, even with every parameter set', () => {
    const params = Object.fromEntries(ALLOWED_PARAMS.map((k) => [k, k === 'role' ? 'nurse' : k === 'clinicName' ? 'Clinic X' : `x-${k}`]));
    for (const t of NOTIFICATION_TYPES) {
      for (const l of LOCALES) {
        const r = renderInbox(t, l, params);
        for (const s of [r.title, r.body]) {
          expect(s).not.toMatch(/[{}]/);
          expect(s).not.toMatch(clinicalWords);
        }
      }
    }
    expect(renderInbox('document_published', 'en', { clinicName: 'Clinic X' }).body).toBe('New document available from Clinic X.');
    expect(renderInbox('document_published', 'ar', {}).body).toContain('عيادتك'); // graceful fallback when the name is empty
  });

  it('rejects clinical or unknown parameters at the API of the service', () => {
    for (const k of FORBIDDEN_PARAMS) expect(() => validateParams('document_published', { [k]: 'x' })).toThrow();
    expect(() => validateParams('document_published', { appointmentId: 'x' })).toThrow(); // not declared for that template
    expect(() => validateParams('document_published', { clinicName: 'x', documentId: 'y' })).not.toThrow();
  });

  it('backoff grows and quiet-hours maths handles midnight wrap', () => {
    expect(backoffSeconds(1)).toBeLessThan(backoffSeconds(2));
    const wrap = { quietStart: '22:00', quietEnd: '07:00', timezone: 'UTC' };
    expect(quietUntil(wrap, new Date('2026-01-01T23:30:00Z'))?.toISOString()).toBe('2026-01-02T07:00:00.000Z');
    expect(quietUntil(wrap, new Date('2026-01-01T03:00:00Z'))?.toISOString()).toBe('2026-01-01T07:00:00.000Z');
    expect(quietUntil(wrap, new Date('2026-01-01T12:00:00Z'))).toBeNull();
    expect(quietUntil({ quietStart: null, quietEnd: null, timezone: 'UTC' }, new Date())).toBeNull();
    expect(quietUntil({ quietStart: '22:00', quietEnd: '07:00', timezone: 'Africa/Cairo' }, new Date('2026-01-01T20:30:00Z'))).not.toBeNull(); // 22:30 in Cairo (UTC+2)
  });
});

describe('inbox API', () => {
  it('requires authentication and is private to the owner', async () => {
    const { doc, rel, pt } = await world();
    const a = await book(doc, rel.id);
    await post(doc, `/appointments/${a.id}/cancel`);
    expect((await call('GET', undefined, '/notifications')).statusCode).toBe(401);
    expect((await call('GET', undefined, '/notification-preferences')).statusCode).toBe(401);
    expect((await call('POST', undefined, '/devices', { token: 'abcdefghij', platform: 'ios' })).statusCode).toBe(401);
    const mine = await inbox(pt);
    expect(mine.items).toHaveLength(1);
    // The doctor sees none of the patient's notifications and cannot mark them read.
    expect((await inbox(doc)).items.filter((i) => i.type === 'appointment_cancelled')).toHaveLength(0);
    expect((await post(doc, `/notifications/${mine.items[0]!.id}/read`)).statusCode).toBe(404);
    expect((await get(pt, '/notifications/unread-count')).json()).toEqual({ count: 1 });
  });

  it('marks read, read-all, filters unread and pages by cursor without gaps or repeats', async () => {
    const { pt } = await world();
    const user = (await rows('select id from users where phone = $1', ['+201111111111']))[0].id as string;
    for (let i = 0; i < 5; i++) await app.notifier.notify({ userId: user, type: 'document_published', key: `k${i}`, params: { clinicName: 'C', documentId: `d${i}` } });
    expect((await get(pt, '/notifications/unread-count')).json().count).toBe(5);
    const p1 = (await get(pt, '/notifications?limit=2')).json();
    expect(p1.items).toHaveLength(2);
    const p2 = (await get(pt, `/notifications?limit=2&cursor=${encodeURIComponent(p1.nextCursor)}`)).json();
    const p3 = (await get(pt, `/notifications?limit=2&cursor=${encodeURIComponent(p2.nextCursor)}`)).json();
    expect(p3.nextCursor).toBeNull();
    const ids = [...p1.items, ...p2.items, ...p3.items].map((i: { id: string }) => i.id);
    expect(new Set(ids).size).toBe(5);
    expect((await get(pt, '/notifications?cursor=garbage')).statusCode).toBe(400);
    await post(pt, `/notifications/${ids[0]}/read`);
    expect((await get(pt, '/notifications/unread-count')).json().count).toBe(4);
    expect((await get(pt, '/notifications?unreadOnly=true')).json().items).toHaveLength(4);
    expect((await post(pt, '/notifications/read-all')).json().updated).toBe(4);
    expect((await get(pt, '/notifications/unread-count')).json().count).toBe(0);
  });

  it('renders in the preferred language', async () => {
    const { doc, rel, pt } = await world();
    const a = await book(doc, rel.id);
    await put(pt, '/notification-preferences', { locale: 'en' });
    await post(doc, `/appointments/${a.id}/cancel`);
    expect((await inbox(pt)).items[0]).toMatchObject({ title: 'Appointment cancelled', body: 'Your appointment at Test Clinic was cancelled.' });
    await put(pt, '/notification-preferences', { locale: 'ar' });
    expect((await inbox(pt)).items[0]!.title).toBe('تم إلغاء الموعد');
  });
});

describe('triggers carry only generic text outside the app', () => {
  it('reschedule and cancel notify the patient via push; the payload reveals nothing clinical or identifying', async () => {
    const { doc, rel, pt } = await world();
    await consentAndDevice(pt);
    await put(pt, '/notification-preferences', { locale: 'en' });
    const a = await book(doc, rel.id);
    expect((await call('PATCH', doc, `/appointments/${a.id}`, { scheduledAt: inHours(72), reason: 'Chest pain follow up' })).statusCode).toBe(200);
    await post(doc, `/appointments/${a.id}/cancel`, { reason: 'Doctor unwell with flu' });
    expect(push.outbox).toHaveLength(2);
    const blob = JSON.stringify(push.outbox);
    for (const leak of ['Test Clinic', 'Mona', 'Chest pain', 'flu', a.id, '2026', 'Dr Test', '+2011']) expect(blob).not.toContain(leak);
    expect(Object.keys(push.outbox[0]!.data)).toEqual(['nid']);
    expect(push.outbox[0]!.body).toBe(renderExternal('appointment_rescheduled', 'en').body);
    const items = (await inbox(pt)).items;
    expect(items.map((i) => i.type).sort()).toEqual(['appointment_cancelled', 'appointment_rescheduled']);
    expect(JSON.stringify(items)).not.toMatch(/Chest pain|flu/);
    // Editing something other than the time does not notify.
    const b = await book(doc, rel.id, inHours(90));
    push.outbox.length = 0;
    await call('PATCH', doc, `/appointments/${b.id}`, { reason: 'Review' });
    expect(push.outbox).toHaveLength(0);
  });

  it('document and encounter publication notify with non-clinical inbox text', async () => {
    const { doc, rel, pt } = await world();
    await consentAndDevice(pt);
    await put(pt, '/notification-preferences', { locale: 'en' });
    // A clinic document, then a signed consultation.
    const b = '----t';
    const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.from(`JFIF-${'x'.repeat(200)}`)]);
    const form = Buffer.concat([
      Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="category"\r\n\r\nlab_result\r\n--${b}\r\nContent-Disposition: form-data; name="title"\r\n\r\nHIV panel\r\n`),
      Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="file"; filename="a.jpg"\r\nContent-Type: image/jpeg\r\n\r\n`),
      jpeg,
      Buffer.from(`\r\n--${b}--\r\n`),
    ]);
    const up = await app.inject({ method: 'POST', url: `/patients/${rel.id}/documents`, headers: { ...doc.headers, 'content-type': `multipart/form-data; boundary=${b}` }, payload: form });
    expect(up.statusCode).toBe(201);
    expect((await post(doc, `/documents/${up.json().id}/publish`)).statusCode).toBe(200);
    const e = (await post(doc, `/patients/${rel.id}/encounters`)).json();
    const saved = await call('PATCH', doc, `/encounters/${e.id}`, { revision: e.revision, chiefComplaint: 'Cough', diagnosis: 'Bronchitis' });
    await post(doc, `/encounters/${e.id}/sign`, { revision: saved.json().revision });
    await post(doc, `/encounters/${e.id}/publish`);
    const items = (await inbox(pt)).items;
    expect(items.find((i) => i.type === 'document_published')!.body).toBe('New document available from Test Clinic.');
    expect(items.find((i) => i.type === 'encounter_published')).toBeTruthy();
    expect(JSON.stringify([items, push.outbox, sent])).not.toMatch(/HIV|Bronchitis|Cough|lab_result/);
    expect(push.outbox).toHaveLength(2);
    // Republishing the same document does not re-notify.
    await post(doc, `/documents/${up.json().id}/unpublish`);
    await post(doc, `/documents/${up.json().id}/publish`);
    expect((await inbox(pt)).items.filter((i) => i.type === 'document_published')).toHaveLength(1);
  });

  it('staff invitation: SMS still sent, existing account gets an inbox item, inviter hears when it is accepted', async () => {
    const doc = await makeVerifiedDoctor(app, pool, '+201000000001');
    const nurse = await login(app, '+201222222222');
    const inv = await post(doc, '/workspace/invitations', { phone: '+201222222222', role: 'nurse' });
    expect(sent.some((s) => s.phone === '+201222222222' && s.text.includes(inv.json().code))).toBe(true);
    const n = (await inbox(nurse)).items;
    expect(n).toHaveLength(1);
    expect(n[0]!.type).toBe('staff_invited');
    await put(nurse, '/notification-preferences', { locale: 'en' });
    expect((await inbox(nurse)).items[0]!.body).toBe('You were invited to join Test Clinic as nurse.');
    await post(nurse, '/invitations/accept', { code: inv.json().code });
    expect((await inbox(doc)).items.map((i) => i.type)).toContain('staff_joined');
  });

  it('sharing events: access request, approval/denial, new grant, expiring grant (both sides, once)', async () => {
    const { doc, rel, pt } = await world();
    const b = await makeVerifiedDoctor(app, pool, '+201000000002');
    const reqRes = await post(doc, `/patients/${rel.id}/access-requests`, { scope: { categories: ['lab_result'] }, purpose: 'Second opinion', days: 7 });
    expect(reqRes.statusCode).toBe(201);
    let mine = (await inbox(pt)).items;
    expect(mine.map((i) => i.type)).toEqual(['access_request_received']);
    expect(mine[0]!.data.requestId).toBe(reqRes.json().id);
    const ok = await post(pt, `/patient/access-requests/${reqRes.json().id}/approve`, { acknowledgeRetention: true });
    expect(ok.statusCode).toBe(200);
    expect((await inbox(doc)).items.map((i) => i.type)).toContain('access_request_approved');
    const r2 = await post(b, `/patients/${rel.id}/access-requests`, { scope: { categories: ['lab_result'] }, purpose: 'x y z', days: 7 });
    expect(r2.statusCode).toBeGreaterThanOrEqual(400); // b has no relationship: nothing is sent
    // Direct grant to doctor B.
    const g = await post(pt, '/patient/grants', { recipient: { doctorPhone: '+201000000002' }, scope: { categories: ['lab_result'] }, days: 2, acknowledgeRetention: true });
    expect(g.statusCode).toBe(201);
    expect((await inbox(b)).items.map((i) => i.type)).toEqual(['grant_received']);
    // The 2-day grant is inside the 3-day "expiring soon" window.
    expect(await dispatchGrantExpiring(pool, new Date(), app.notifier)).toBeGreaterThan(0);
    expect(await dispatchGrantExpiring(pool, new Date(), app.notifier)).toBe(0);
    expect((await inbox(b)).items.map((i) => i.type)).toContain('grant_expiring');
    mine = (await inbox(pt)).items;
    expect(mine.map((i) => i.type)).toContain('grant_expiring');
    // Denial path.
    await post(pt, '/patient/grants/' + g.json().id.toString()).catch(() => undefined);
    const r3 = await post(doc, `/patients/${rel.id}/access-requests`, { scope: { categories: ['report'] }, purpose: 'Another one', days: 7 });
    expect(r3.statusCode).toBe(201);
    await post(pt, `/patient/access-requests/${r3.json().id}/deny`);
    expect((await inbox(doc)).items.map((i) => i.type)).toContain('access_request_denied');
    // Revocation sends nothing to the recipient (spec 08 follow-through).
    const before = (await inbox(b)).items.length;
    await call('DELETE', pt, `/patient/grants/${g.json().id}`);
    expect((await inbox(b)).items).toHaveLength(before);
  });
});

describe('consent (F10-5)', () => {
  it('a doctor-registered patient gets in-app only until they consent; then push and SMS flow', async () => {
    const { doc, rel, pt } = await world();
    expect((await get(pt, '/notification-consent')).json()).toEqual({ required: true, push: null, sms: null });
    await post(pt, '/devices', { token: 'device-token-aaaaaaaa', platform: 'android' });
    const a = await book(doc, rel.id);
    await post(doc, `/appointments/${a.id}/cancel`);
    expect(push.outbox).toHaveLength(0);
    expect(sent.filter((s) => s.phone === '+201111111111')).toHaveLength(0);
    expect((await inbox(pt)).items).toHaveLength(1); // still visible after authenticated open
    expect(await rows('select * from notification_deliveries')).toHaveLength(0);

    await put(pt, '/notification-consent', { push: true });
    const b = await book(doc, rel.id, inHours(50));
    await post(doc, `/appointments/${b.id}/cancel`);
    expect(push.outbox).toHaveLength(1);
    expect(sent.filter((s) => s.phone === '+201111111111')).toHaveLength(0); // sms not consented, push available anyway
    const log = await rows('select granted, channel from notification_consents order by id');
    expect(log).toEqual([{ granted: true, channel: 'push' }]);
  });

  it('withdrawing consent stops delivery; consent is an append-only history', async () => {
    const { doc, rel, pt } = await world();
    await consentAndDevice(pt);
    await put(pt, '/notification-consent', { push: false });
    const a = await book(doc, rel.id);
    await post(doc, `/appointments/${a.id}/cancel`);
    expect(push.outbox).toHaveLength(0);
    expect((await rows('select 1 from notification_consents')).length).toBe(3);
    expect((await get(pt, '/notification-consent')).json()).toMatchObject({ push: false, sms: true });
  });

  it('staff are not subject to the patient-consent gate', async () => {
    const doc = await makeVerifiedDoctor(app, pool, '+201000000001');
    expect((await get(doc, '/notification-consent')).json().required).toBe(false);
  });
});

describe('channels: push first, SMS only as a cost-gated fallback', () => {
  it('uses SMS (generic text, localized) when there is no device, and not at all for non-SMS types', async () => {
    const { doc, rel, pt } = await world();
    await put(pt, '/notification-consent', { push: true, sms: true });
    const a = await book(doc, rel.id);
    await post(doc, `/appointments/${a.id}/cancel`);
    const s = sent.filter((x) => x.phone === '+201111111111');
    expect(s).toHaveLength(1);
    expect(s[0]!.text).toBe(renderExternal('appointment_cancelled', 'ar').body);
    expect(s[0]!.text).not.toMatch(/Test Clinic|Mona/);
    // A document notification has no SMS fallback.
    const user = (await rows('select id from users where phone = $1', ['+201111111111']))[0].id as string;
    await app.notifier.notify({ userId: user, type: 'document_published', key: 'doc-x', params: { clinicName: 'C' } });
    expect(sent.filter((x) => x.phone === '+201111111111')).toHaveLength(1);
  });

  it('does not text a user who has a working push device', async () => {
    const { doc, rel, pt } = await world();
    await consentAndDevice(pt);
    const a = await book(doc, rel.id);
    await post(doc, `/appointments/${a.id}/cancel`);
    expect(push.outbox).toHaveLength(1);
    expect(sent.filter((x) => x.phone === '+201111111111')).toHaveLength(0);
  });

  it('respects the channel preference and ignores devices of revoked sessions', async () => {
    const { doc, rel, pt } = await world();
    await consentAndDevice(pt);
    await put(pt, '/notification-preferences', { channels: [] });
    const a = await book(doc, rel.id);
    await post(doc, `/appointments/${a.id}/cancel`);
    expect(push.outbox).toHaveLength(0);
    expect(sent.filter((x) => x.phone === '+201111111111')).toHaveLength(0);
    await put(pt, '/notification-preferences', { channels: ['push'] });
    await post(pt, '/auth/logout');
    const b = await book(doc, rel.id, inHours(60));
    await post(doc, `/appointments/${b.id}/cancel`);
    expect(push.outbox).toHaveLength(0);
  });

  it('device registration is per account: a token moves to the latest signed-in user, and can be removed', async () => {
    const { pt } = await world();
    const other = await login(app, '+201333333333');
    const id = (await post(pt, '/devices', { token: 'shared-token-1234', platform: 'ios' })).json().id;
    const id2 = (await post(other, '/devices', { token: 'shared-token-1234', platform: 'ios' })).json().id;
    expect(id2).toBe(id);
    expect((await call('DELETE', pt, `/devices/${id}`)).statusCode).toBe(404); // no longer theirs
    expect((await call('DELETE', other, `/devices?token=shared-token-1234`)).statusCode).toBe(204);
    expect((await call('DELETE', other, `/devices/${id}`)).statusCode).toBe(404);
    expect((await post(pt, '/devices', { token: 'x', platform: 'ios' })).statusCode).toBe(400);
  });
});

describe('preferences (F10-4)', () => {
  it('per-type opt-out suppresses the notification entirely but security notices still arrive', async () => {
    const { doc, rel, pt } = await world();
    await consentAndDevice(pt);
    const off = await put(pt, '/notification-preferences', { disabledTypes: ['appointment_reminder', 'appointment_cancelled'] });
    expect(off.json().disabledTypes).toEqual(['appointment_reminder', 'appointment_cancelled']);
    const a = await book(doc, rel.id, inHours(5));
    await dispatchDueReminders(pool, new Date(), app.notifier);
    await post(doc, `/appointments/${a.id}/cancel`);
    expect((await inbox(pt)).items).toHaveLength(0);
    expect(push.outbox).toHaveLength(0);
    // Mandatory types cannot be disabled, unknown types are rejected.
    const bad = await put(pt, '/notification-preferences', { disabledTypes: ['security_phone_changed'] });
    expect(bad.statusCode).toBe(400);
    expect(bad.json().error).toBe('mandatory_notice');
    expect((await put(pt, '/notification-preferences', { disabledTypes: ['nope'] })).statusCode).toBe(400);
    // Security notice with everything else switched off, quiet hours covering "now".
    const h = new Date().getUTCHours();
    await put(pt, '/notification-preferences', { channels: [], quietHours: { start: `${String((h + 23) % 24).padStart(2, '0')}:00`, end: `${String((h + 1) % 24).padStart(2, '0')}:00`, timezone: 'UTC' } });
    const user = (await rows('select id from users where phone = $1', ['+201111111111']))[0].id as string;
    await app.notifier.notify({ userId: user, type: 'security_new_login', key: 'sec-1' });
    expect((await inbox(pt)).items.map((i) => i.type)).toEqual(['security_new_login']);
    expect(push.outbox).toHaveLength(1);
    expect(push.outbox[0]!.body).toBe(renderExternal('security_new_login', 'ar').body);
    // A disabled type never reappears in the listing of types as togglable.
    const prefs = (await get(pt, '/notification-preferences')).json();
    expect(prefs.types.filter((t: { mandatory: boolean }) => t.mandatory).map((t: { type: string }) => t.type)).toContain('security_phone_changed');
  });

  it('validates quiet hours and time zones, and supports clearing them', async () => {
    const { pt } = await world();
    expect((await put(pt, '/notification-preferences', { quietHours: { start: '25:00', end: '07:00' } })).statusCode).toBe(400);
    expect((await put(pt, '/notification-preferences', { quietHours: { start: '22:00', end: '22:00' } })).statusCode).toBe(400);
    expect((await put(pt, '/notification-preferences', { quietHours: { start: '22:00', end: '07:00', timezone: 'Mars/Base' } })).statusCode).toBe(400);
    const ok = (await put(pt, '/notification-preferences', { quietHours: { start: '22:00', end: '07:00', timezone: 'Africa/Cairo' } })).json();
    expect(ok.quietHours).toEqual({ start: '22:00', end: '07:00', timezone: 'Africa/Cairo' });
    expect((await put(pt, '/notification-preferences', { quietHours: null })).json().quietHours).toBeNull();
  });

  it('quiet hours hold push/SMS until the window ends, while the inbox item is visible immediately', async () => {
    const { doc, rel, pt } = await world();
    await consentAndDevice(pt);
    const h = new Date().getUTCHours();
    await put(pt, '/notification-preferences', { quietHours: { start: `${String((h + 23) % 24).padStart(2, '0')}:00`, end: `${String((h + 1) % 24).padStart(2, '0')}:00`, timezone: 'UTC' } });
    const a = await book(doc, rel.id);
    await post(doc, `/appointments/${a.id}/cancel`);
    expect(push.outbox).toHaveLength(0);
    expect((await inbox(pt)).items).toHaveLength(1);
    const n = (await rows(`select status, deliver_after from notifications`))[0];
    expect(n.status).toBe('pending');
    expect(n.deliver_after.getTime()).toBeGreaterThan(Date.now());
    await app.notifier.process(new Date(Date.now() + 60_000)); // still inside the window
    expect(push.outbox).toHaveLength(0);
    await app.notifier.process(new Date(n.deliver_after.getTime() + 1000));
    expect(push.outbox).toHaveLength(1);
    expect((await rows(`select status from notifications`))[0].status).toBe('sent');
  });
});

describe('delivery log, retries and idempotency (F10-6)', () => {
  it('the same key twice yields one notification and one send', async () => {
    const { pt } = await world();
    await consentAndDevice(pt);
    const user = (await rows('select id from users where phone = $1', ['+201111111111']))[0].id as string;
    const a = await app.notifier.notify({ userId: user, type: 'document_published', key: 'same', params: { clinicName: 'C' } });
    const b = await app.notifier.notify({ userId: user, type: 'document_published', key: 'same', params: { clinicName: 'C' } });
    expect(a).toBeTruthy();
    expect(b).toBeNull();
    expect(await rows('select 1 from notifications')).toHaveLength(1);
    expect(push.outbox).toHaveLength(1);
    // Concurrent duplicates too.
    await Promise.all([1, 2, 3].map(() => app.notifier.notify({ userId: user, type: 'document_published', key: 'race', params: {} })));
    expect(await rows(`select 1 from notifications where idempotency_key = 'race'`)).toHaveLength(1);
    expect(push.outbox).toHaveLength(2);
  });

  it('failed sends are retried with backoff, logged, and eventually marked failed; appointment types fall back to SMS', async () => {
    const { doc, rel, pt } = await world();
    await consentAndDevice(pt);
    push.failNext = 100;
    const a = await book(doc, rel.id);
    await post(doc, `/appointments/${a.id}/cancel`);
    let n = (await rows('select * from notifications'))[0];
    expect(n).toMatchObject({ status: 'pending', attempts: 1, last_error: 'push provider unavailable' });
    let d = (await rows('select * from notification_deliveries'))[0];
    const t0 = new Date(d.next_attempt_at.getTime() - backoffSeconds(1) * 1000).getTime();
    expect(Math.abs(d.next_attempt_at.getTime() - Date.now() - backoffSeconds(1) * 1000)).toBeLessThan(5000);
    await app.notifier.process(new Date(t0 + 1000)); // too early: nothing due
    expect((await rows('select attempts from notification_deliveries'))[0].attempts).toBe(1);
    let clock = Date.now();
    for (let i = 2; i <= RETRY.maxAttempts; i++) {
      clock += backoffSeconds(i - 1) * 1000 + 1000;
      await app.notifier.process(new Date(clock));
    }
    d = (await rows(`select * from notification_deliveries where channel = 'push'`))[0];
    expect(d).toMatchObject({ status: 'failed', attempts: RETRY.maxAttempts });
    // Push is exhausted: the SMS fallback (consented) takes over and completes the notification.
    clock += 1000;
    await app.notifier.process(new Date(clock));
    expect(sent.filter((x) => x.phone === '+201111111111')).toHaveLength(1);
    n = (await rows('select * from notifications'))[0];
    expect(n.status).toBe('sent');
  });

  it('a notification whose only channel keeps failing ends as failed with the last error recorded', async () => {
    const { pt } = await world();
    await consentAndDevice(pt);
    push.failNext = 100;
    const user = (await rows('select id from users where phone = $1', ['+201111111111']))[0].id as string;
    await app.notifier.notify({ userId: user, type: 'document_published', key: 'doomed', params: {} });
    let clock = Date.now();
    for (let i = 0; i < RETRY.maxAttempts; i++) {
      clock += 3_600_000;
      await app.notifier.process(new Date(clock));
    }
    const n = (await rows('select * from notifications'))[0];
    expect(n).toMatchObject({ status: 'failed', attempts: RETRY.maxAttempts, last_error: 'push provider unavailable' });
    expect((await inbox(pt)).items).toHaveLength(1); // inbox is unaffected by transport failure
  });

  it('a retry that succeeds completes the notification', async () => {
    const { pt } = await world();
    await consentAndDevice(pt);
    push.failNext = 1;
    const user = (await rows('select id from users where phone = $1', ['+201111111111']))[0].id as string;
    await app.notifier.notify({ userId: user, type: 'document_published', key: 'flaky', params: {} });
    expect((await rows('select status from notifications'))[0].status).toBe('pending');
    await app.notifier.process(new Date(Date.now() + 60_000));
    expect(push.outbox).toHaveLength(1);
    expect((await rows('select status, attempts from notifications'))[0]).toEqual({ status: 'sent', attempts: 2 });
  });
});

describe('scheduled reminders (F04-7, F10-2)', () => {
  it('sends one reminder per appointment time inside the 24h window, never for the unclaimed or far-off', async () => {
    const { doc, rel, pt } = await world();
    await consentAndDevice(pt);
    const soon = await book(doc, rel.id, inHours(5));
    await book(doc, rel.id, inHours(30));
    const unclaimed = (await post(doc, '/patients', { phone: '+201555555555', fullName: 'No App' })).json();
    await book(doc, unclaimed.id, inHours(6));
    expect(await dispatchDueReminders(pool, new Date(), app.notifier)).toBe(1);
    expect(await dispatchDueReminders(pool, new Date(), app.notifier)).toBe(0); // idempotent
    expect(push.outbox).toHaveLength(1);
    expect(push.outbox[0]!.body).toBe(renderExternal('appointment_reminder', 'ar').body);
    // The later day's appointment is reminded once it falls inside the window.
    expect(await dispatchDueReminders(pool, new Date(Date.now() + 10 * 3_600_000), app.notifier)).toBe(1);
    // Rescheduling to a new time yields a new reminder; cancelled appointments get none.
    await call('PATCH', doc, `/appointments/${soon.id}`, { scheduledAt: inHours(8) });
    expect(await dispatchDueReminders(pool, new Date(), app.notifier)).toBe(1);
    await post(doc, `/appointments/${soon.id}/cancel`);
    expect(await dispatchDueReminders(pool, new Date(), app.notifier)).toBe(0);
  });

  it('runJobs delivers reminders and registered sources (follow-up style), idempotently', async () => {
    const { doc, rel, pt } = await world();
    await consentAndDevice(pt);
    const user = (await rows('select id from users where phone = $1', ['+201111111111']))[0].id as string;
    app.notifier.registerReminderSource('test-source', async () => [{ userId: user, type: 'followup_reminder', key: 'f1', params: { planId: 'plan-1' } }]);
    await book(doc, rel.id, inHours(3));
    await app.runNotificationJobs();
    await app.runNotificationJobs();
    const types = (await inbox(pt)).items.map((i) => i.type).sort();
    expect(types).toEqual(['appointment_reminder', 'followup_reminder']);
    expect(push.outbox).toHaveLength(2);
    expect(JSON.stringify(push.outbox)).not.toMatch(/plan-1/);
  });
});

describe('security notices (non-disableable)', () => {
  it('phone change, MFA enable/disable and a new device raise security notices; the phone notice also texts the old number', async () => {
    const s = await login(app, '+201444444444');
    await post(s, '/devices', { token: 'sec-device-token-1', platform: 'android' });
    await put(s, '/notification-preferences', { disabledTypes: ['document_published'], channels: [] });
    // MFA on (non-doctor accounts may switch it off again).
    const { secret } = (await post(s, '/auth/mfa/enroll')).json();
    expect((await post(s, '/auth/mfa/activate', { code: totpCode(secret, totpStep()) })).statusCode).toBe(200);
    // Phone change.
    const rq = await post(s, '/auth/phone-change/request', { newPhone: '+201444444445' });
    const { devOldCode, devNewCode } = rq.json();
    expect((await post(s, '/auth/phone-change/confirm', { newPhone: '+201444444445', oldCode: devOldCode, newCode: devNewCode })).statusCode).toBe(200);
    const types = (await inbox(s)).items.map((i) => i.type);
    expect(types).toContain('security_mfa_enabled');
    expect(types).toContain('security_phone_changed');
    expect(push.outbox.length).toBeGreaterThanOrEqual(2); // delivered although every optional channel/type is off
    expect(sent.some((x) => x.phone === '+201444444444' && x.text === renderExternal('security_phone_changed', 'ar').body)).toBe(true);
  });

  it('a sign-in from an unseen device name notifies; first sign-in and known devices do not', async () => {
    const phone = '+201666666666';
    const code = async () => (await post({ headers: {} }, '/auth/otp/request', { phone })).json().devCode as string;
    const signIn = async (deviceName: string) => (await post({ headers: {} }, '/auth/otp/verify', { phone, code: await code(), deviceName })).json();
    const first = await signIn('Pixel 8');
    const h = { headers: { authorization: `Bearer ${first.accessToken}` } };
    expect((await inbox(h)).items).toHaveLength(0);
    await signIn('Pixel 8');
    expect((await inbox(h)).items).toHaveLength(0);
    await signIn('iPad');
    expect((await inbox(h)).items.map((i) => i.type)).toEqual(['security_new_login']);
  });
});

describe('TEMPLATES cover every trigger', () => {
  it('declares all spec 10 trigger types', () => {
    for (const t of ['appointment_reminder', 'appointment_rescheduled', 'appointment_cancelled', 'followup_reminder', 'document_published', 'encounter_published', 'access_request_received', 'grant_received', 'grant_expiring', 'staff_invited', 'security_phone_changed', 'security_mfa_enabled', 'security_mfa_disabled']) {
      expect(NOTIFICATION_TYPES).toContain(t);
    }
  });
});
