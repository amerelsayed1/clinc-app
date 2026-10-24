import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { enableMfa, login, makeVerifiedDoctor, reset, setupApp, type Session } from './helpers.js';

/*
 * F11-5 authorization matrix. Every route registered on the app MUST appear in MATRIX with a classification;
 * a route that is not listed fails the "no unclassified routes" test, so new endpoints cannot ship unreviewed.
 *
 * Kinds
 *   public  no credentials needed (login flow, health, signed-link download)
 *   authed  any signed-in user; the data is scoped to that user (`self` owner)
 *   patient signed-in patient; `claim` = needs a claimed patient profile
 *   ws      clinic route behind a workspace permission. `allow` lists who passes the permission check:
 *             d verified doctor (owner)   u doctor without verified licence/MFA   n nurse   r receptionist
 *   admin   platform administrators; `strict` = also needs the admin's MFA
 *
 * For every route the suite proves: no credentials => 401; wrong role / missing permission / not a member => 403;
 * and, where the route takes an id, that a user from another clinic (or another patient) gets 404 (RULE-003).
 */

type Who = 'd' | 'u' | 'n' | 'r';
const ALL: Who[] = ['d', 'u', 'n', 'r'];
const CLINICAL_READ: Who[] = ['d', 'u', 'n'];
const DOCTOR_SIDE: Who[] = ['d', 'u']; // owner permissions that need no clinical.write
const D_ONLY: Who[] = ['d']; // clinical.write / followups.write need a verified doctor
const APPT_MANAGE: Who[] = ['d', 'u', 'r'];

interface Entry {
  kind: 'public' | 'authed' | 'patient' | 'ws' | 'admin';
  allow?: Who[];
  /** path parameter name -> fixture key */
  p?: Record<string, keyof Fixture>;
  body?: () => unknown;
  multipart?: boolean;
  owner?: 'A' | 'B' | 'P1' | 'self';
  claim?: boolean;
  strict?: boolean;
  /** foreign clinic answers 200 with an empty result instead of 404 (list-by-patient endpoints) */
  foreignEmpty?: boolean;
  /** skip the "allowed actors are not refused" probe (route needs special state) */
  noPositive?: boolean;
  /** a foreign actor still needs a resource id inside the body */
  bodyId?: boolean;
  publicStatus?: number[];
  query?: string;
}

let F: Fixture;
interface Fixture {
  relA: string;
  relB: string;
  enc: string;
  draftEnc: string;
  obs: string;
  appt: string;
  doc: string;
  adminDoc: string;
  patientDoc: string;
  plan: string;
  measurement: string;
  member: string;
  invite: string;
  grant: string;
  accessReq: string;
  correction: string;
  notification: string;
  device: string;
  session: string;
  userId: string;
  unknown: string;
}

const day = (o: number) => new Date(Date.now() + o * 86_400_000).toISOString().slice(0, 10);
const noBody = undefined;

const MATRIX: Record<string, Entry> = {
  // ----- public -----
  'GET /health': { kind: 'public', publicStatus: [200] },
  'POST /auth/otp/request': { kind: 'public', publicStatus: [400] },
  'POST /auth/otp/verify': { kind: 'public', publicStatus: [400] },
  'POST /auth/mfa/verify': { kind: 'public', publicStatus: [400] },
  'POST /auth/refresh': { kind: 'public', publicStatus: [400] },
  'GET /files/:token': { kind: 'public', p: { token: 'unknown' }, publicStatus: [403] }, // bearer capability, verified by signature

  // ----- any signed-in user (own data only) -----
  'GET /me': { kind: 'authed' },
  'PATCH /me': { kind: 'authed', body: () => ({ fullName: 'Someone Else' }) },
  'POST /doctors/register': { kind: 'authed', noPositive: true },
  'POST /workspaces': { kind: 'authed', noPositive: true },
  'POST /invitations/accept': { kind: 'authed', noPositive: true },
  'POST /auth/logout': { kind: 'authed', noPositive: true },
  'POST /auth/mfa/enroll': { kind: 'authed', noPositive: true },
  'POST /auth/mfa/activate': { kind: 'authed', noPositive: true },
  'POST /auth/mfa/disable': { kind: 'authed', noPositive: true },
  'POST /auth/phone-change/request': { kind: 'authed', noPositive: true },
  'POST /auth/phone-change/confirm': { kind: 'authed', noPositive: true },
  'GET /sessions': { kind: 'authed' },
  'DELETE /sessions/:id': { kind: 'authed', p: { id: 'session' }, owner: 'P1' },
  'POST /sessions/revoke-others': { kind: 'authed', noPositive: true },
  'GET /notifications': { kind: 'authed' },
  'GET /notifications/unread-count': { kind: 'authed' },
  'POST /notifications/read-all': { kind: 'authed', noPositive: true },
  'POST /notifications/:id/read': { kind: 'authed', p: { id: 'notification' }, owner: 'P1' },
  'GET /notification-preferences': { kind: 'authed' },
  'PUT /notification-preferences': { kind: 'authed', noPositive: true },
  'GET /notification-consent': { kind: 'authed' },
  'PUT /notification-consent': { kind: 'authed', noPositive: true },
  'POST /devices': { kind: 'authed', noPositive: true },
  'DELETE /devices/:id': { kind: 'authed', p: { id: 'device' }, owner: 'P1' },
  'DELETE /devices': { kind: 'authed', noPositive: true },

  // ----- platform admin -----
  'GET /admin/doctors': { kind: 'admin' },
  'POST /admin/doctors/:userId/decision': { kind: 'admin', p: { userId: 'userId' }, body: () => ({ decision: 'verified' }), noPositive: true },
  'GET /admin/workspaces': { kind: 'admin', strict: true },
  'POST /admin/break-glass': { kind: 'admin', strict: true, noPositive: true, body: () => ({ workspaceId: F.userId, justification: 'x'.repeat(20) }) },
  'GET /admin/break-glass': { kind: 'admin', strict: true },
  'DELETE /admin/break-glass/:id': { kind: 'admin', strict: true, p: { id: 'unknown' }, noPositive: true },
  'GET /admin/workspaces/:id/audit': { kind: 'admin', strict: true, p: { id: 'unknown' }, noPositive: true },
  'GET /admin/audit/verify': { kind: 'admin', strict: true },
  'GET /admin/audit/verifications': { kind: 'admin', strict: true },

  // ----- patient app -----
  'POST /patient/claim': { kind: 'patient', claim: false, noPositive: true },
  'GET /patient/relationships': { kind: 'patient', claim: false },
  'POST /patient/relationships/:id/accept': { kind: 'patient', claim: false, owner: 'P1', p: { id: 'relA' }, noPositive: true },
  'POST /patient/relationships/:id/decline': { kind: 'patient', claim: false, owner: 'P1', p: { id: 'relA' }, noPositive: true },
  'POST /patient/relationships/:id/end': { kind: 'patient', claim: false, owner: 'P1', p: { id: 'relA' }, noPositive: true },
  'GET /patient/encounters': { kind: 'patient', claim: false },
  'GET /patient/encounters/:id': { kind: 'patient', claim: false, owner: 'P1', p: { id: 'enc' } },
  'GET /patient/documents': { kind: 'patient', claim: true },
  'POST /patient/documents': { kind: 'patient', claim: true, multipart: true, noPositive: true },
  'DELETE /patient/documents/:id': { kind: 'patient', claim: true, owner: 'P1', p: { id: 'patientDoc' }, noPositive: true },
  'GET /patient/documents/:id/pages/:page/link': { kind: 'patient', claim: true, owner: 'P1', p: { id: 'patientDoc', page: 'one' as never } },
  'POST /patient/documents/:id/send': { kind: 'patient', claim: true, owner: 'P1', p: { id: 'patientDoc' }, body: () => ({ relationshipId: F.relA }), noPositive: true },
  'DELETE /patient/documents/:id/send/:relationshipId': { kind: 'patient', claim: true, owner: 'P1', p: { id: 'patientDoc', relationshipId: 'relA' }, noPositive: true },
  'GET /patient/shareable': { kind: 'patient', claim: true },
  'GET /patient/grants': { kind: 'patient', claim: true },
  'POST /patient/grants': { kind: 'patient', claim: true, noPositive: true, body: () => ({ recipient: { doctorPhone: '+201000000002' }, scope: { categories: ['report'] }, acknowledgeRetention: true }) },
  'DELETE /patient/grants/:id': { kind: 'patient', claim: true, owner: 'P1', p: { id: 'grant' }, noPositive: true },
  'GET /patient/access-log': { kind: 'patient', claim: true },
  'GET /patient/access-requests': { kind: 'patient', claim: true },
  'POST /patient/access-requests/:id/approve': { kind: 'patient', claim: true, owner: 'P1', p: { id: 'accessReq' }, body: () => ({ acknowledgeRetention: true }), noPositive: true },
  'POST /patient/access-requests/:id/deny': { kind: 'patient', claim: true, owner: 'P1', p: { id: 'accessReq' }, noPositive: true },
  'GET /patient/followups': { kind: 'patient', claim: true },
  'GET /patient/followups/due': { kind: 'patient', claim: true },
  'POST /patient/followups/:id/submissions': { kind: 'patient', claim: true, owner: 'P1', p: { id: 'plan' }, body: () => ({ measurementId: F.measurement, value: 70, measuredAt: new Date().toISOString() }), noPositive: true },
  'GET /patient/followups/:id/submissions': { kind: 'patient', claim: true, owner: 'P1', p: { id: 'plan' } },
  'GET /patient/timeline': { kind: 'patient', claim: false },
  'POST /patient/export': { kind: 'patient', claim: true, noPositive: true },
  'GET /patient/correction-requests': { kind: 'patient', claim: true },
  'POST /patient/correction-requests': { kind: 'patient', claim: true, noPositive: true, body: () => ({ targetType: 'encounter', targetId: F.enc, description: 'Please check this' }) },

  // ----- clinic: workspace and staff -----
  'GET /workspace': { kind: 'ws', allow: ALL },
  'GET /workspace/members': { kind: 'ws', allow: ALL },
  'GET /workspace/settings': { kind: 'ws', allow: ALL },
  'PATCH /workspace/settings': { kind: 'ws', allow: DOCTOR_SIDE, noPositive: true, body: () => ({ slotMinutes: 20 }) },
  'GET /workspace/storage': { kind: 'ws', allow: ALL },
  'GET /workspace/invitations': { kind: 'ws', allow: DOCTOR_SIDE },
  'POST /workspace/invitations': { kind: 'ws', allow: DOCTOR_SIDE, noPositive: true, body: () => ({ phone: '+201999999999', role: 'nurse' }) },
  'DELETE /workspace/invitations/:id': { kind: 'ws', allow: DOCTOR_SIDE, p: { id: 'invite' }, noPositive: true },
  'PATCH /workspace/members/:id': { kind: 'ws', allow: DOCTOR_SIDE, p: { id: 'member' }, body: () => ({ status: 'suspended' }), noPositive: true },
  'DELETE /workspace/members/:id': { kind: 'ws', allow: DOCTOR_SIDE, p: { id: 'member' }, noPositive: true },
  'GET /workspace/audit': { kind: 'ws', allow: DOCTOR_SIDE },
  'GET /workspace/audit/export': { kind: 'ws', allow: DOCTOR_SIDE },
  'GET /workspace/audit/verify': { kind: 'ws', allow: DOCTOR_SIDE },
  'GET /workspace/retention': { kind: 'ws', allow: DOCTOR_SIDE },
  'PATCH /patients/:id/legal-hold': { kind: 'ws', allow: DOCTOR_SIDE, p: { id: 'relA' }, body: () => ({ hold: false }), noPositive: true },

  // ----- clinic: patients and appointments -----
  'GET /patients': { kind: 'ws', allow: ALL },
  'POST /patients': { kind: 'ws', allow: ALL, noPositive: true, body: () => ({ phone: '+201888888888', fullName: 'Probe Person' }) },
  'GET /patients/:id': { kind: 'ws', allow: ALL, p: { id: 'relA' } },
  'PATCH /patients/:id': { kind: 'ws', allow: ALL, p: { id: 'relA' }, body: () => ({ fullName: 'Hacked Name' }), noPositive: true },
  'POST /patients/:id/end': { kind: 'ws', allow: DOCTOR_SIDE, p: { id: 'relA' }, noPositive: true },
  'GET /appointments': { kind: 'ws', allow: ALL },
  'POST /appointments': { kind: 'ws', allow: APPT_MANAGE, bodyId: true, noPositive: true, body: () => ({ patientId: F.relA, scheduledAt: new Date(Date.now() + 5 * 86_400_000).toISOString(), override: true }) },
  'POST /appointments/walk-in': { kind: 'ws', allow: APPT_MANAGE, bodyId: true, noPositive: true, body: () => ({ patientId: F.relA }) },
  'GET /appointments/:id': { kind: 'ws', allow: ALL, p: { id: 'appt' } },
  'PATCH /appointments/:id': { kind: 'ws', allow: APPT_MANAGE, p: { id: 'appt' }, body: () => ({ reason: 'probe' }), noPositive: true },
  'POST /appointments/:id/check-in': { kind: 'ws', allow: APPT_MANAGE, p: { id: 'appt' }, noPositive: true },
  'POST /appointments/:id/cancel': { kind: 'ws', allow: APPT_MANAGE, p: { id: 'appt' }, noPositive: true },
  'POST /appointments/:id/no-show': { kind: 'ws', allow: APPT_MANAGE, p: { id: 'appt' }, noPositive: true },
  'POST /appointments/:id/start': { kind: 'ws', allow: D_ONLY, p: { id: 'appt' }, noPositive: true },
  'POST /appointments/:id/complete': { kind: 'ws', allow: D_ONLY, p: { id: 'appt' }, noPositive: true },

  // ----- clinic: encounters (clinical.read / clinical.write / vitals.write) -----
  'GET /patients/:id/encounters': { kind: 'ws', allow: CLINICAL_READ, p: { id: 'relA' } },
  'POST /patients/:id/encounters': { kind: 'ws', allow: D_ONLY, p: { id: 'relA' }, noPositive: true },
  'GET /patients/:id/observations': { kind: 'ws', allow: CLINICAL_READ, p: { id: 'relA' }, query: '?kind=heart_rate' },
  'GET /encounters/:id': { kind: 'ws', allow: CLINICAL_READ, p: { id: 'enc' } },
  'GET /encounters/:id/versions': { kind: 'ws', allow: CLINICAL_READ, p: { id: 'enc' } },
  'GET /encounters/:id/prescription': { kind: 'ws', allow: CLINICAL_READ, p: { id: 'enc' } },
  'PATCH /encounters/:id': { kind: 'ws', allow: D_ONLY, p: { id: 'draftEnc' }, body: () => ({ revision: 1, chiefComplaint: 'probe' }), noPositive: true },
  'DELETE /encounters/:id': { kind: 'ws', allow: D_ONLY, p: { id: 'draftEnc' }, noPositive: true },
  'POST /encounters/:id/sign': { kind: 'ws', allow: D_ONLY, p: { id: 'draftEnc' }, body: () => ({ revision: 1 }), noPositive: true },
  'POST /encounters/:id/amend': { kind: 'ws', allow: D_ONLY, p: { id: 'enc' }, body: () => ({ baseVersion: 1, reason: 'probe amend', changes: { plan: 'probe' } }), noPositive: true },
  'POST /encounters/:id/observations': { kind: 'ws', allow: CLINICAL_READ, p: { id: 'draftEnc' }, body: () => ({ kind: 'heart_rate', value: 70 }), noPositive: true },
  'POST /encounters/:id/observations/:oid/void': { kind: 'ws', allow: CLINICAL_READ, p: { id: 'draftEnc', oid: 'obs' }, body: () => ({ reason: 'probe void' }), noPositive: true },
  'POST /encounters/:id/publish': { kind: 'ws', allow: D_ONLY, p: { id: 'enc' }, noPositive: true },
  'POST /encounters/:id/unpublish': { kind: 'ws', allow: D_ONLY, p: { id: 'enc' }, noPositive: true },
  'GET /patients/:relationshipId/timeline': { kind: 'ws', allow: CLINICAL_READ, p: { relationshipId: 'relA' } },

  // ----- clinic: documents -----
  'GET /patients/:id/documents': { kind: 'ws', allow: ALL, p: { id: 'relA' } },
  'POST /patients/:id/documents': { kind: 'ws', allow: ALL, p: { id: 'relA' }, multipart: true, noPositive: true },
  'GET /documents/:id': { kind: 'ws', allow: ALL, p: { id: 'adminDoc' } },
  'GET /documents/:id/pages/:page/link': { kind: 'ws', allow: ALL, p: { id: 'adminDoc', page: 'one' as never } },
  'POST /documents/:id/review': { kind: 'ws', allow: D_ONLY, p: { id: 'patientDoc' }, noPositive: true },
  'POST /documents/:id/publish': { kind: 'ws', allow: D_ONLY, p: { id: 'doc' }, noPositive: true },
  'POST /documents/:id/unpublish': { kind: 'ws', allow: D_ONLY, p: { id: 'doc' }, noPositive: true },
  'DELETE /documents/:id': { kind: 'ws', allow: ALL, p: { id: 'doc' }, body: () => ({ reason: 'probe delete' }), noPositive: true },

  // ----- clinic: sharing (spec 08) -----
  'POST /patients/:id/access-requests': { kind: 'ws', allow: D_ONLY, p: { id: 'relA' }, body: () => ({ scope: { categories: ['report'] }, purpose: 'probe request', days: 7 }), noPositive: true },
  'GET /access-requests': { kind: 'ws', allow: CLINICAL_READ },
  'DELETE /access-requests/:id': { kind: 'ws', allow: D_ONLY, p: { id: 'accessReq' }, noPositive: true },
  'GET /shared-with-me': { kind: 'ws', allow: CLINICAL_READ },
  'GET /shared-with-me/:id/items': { kind: 'ws', allow: CLINICAL_READ, owner: 'B', p: { id: 'grant' } },
  'GET /shared-with-me/:id/encounters/:encId': { kind: 'ws', allow: CLINICAL_READ, owner: 'B', p: { id: 'grant', encId: 'enc' }, noPositive: true },
  'GET /shared-with-me/:id/documents/:docId': { kind: 'ws', allow: CLINICAL_READ, owner: 'B', p: { id: 'grant', docId: 'doc' }, noPositive: true },
  'GET /shared-with-me/:id/documents/:docId/pages/:page/link': { kind: 'ws', allow: CLINICAL_READ, owner: 'B', p: { id: 'grant', docId: 'doc', page: 'one' as never }, noPositive: true },

  // ----- clinic: follow-up plans (spec 09) -----
  'POST /patients/:id/followups': { kind: 'ws', allow: D_ONLY, p: { id: 'relA' }, noPositive: true, body: () => ({ instructions: 'probe', nextVisitDate: day(10), endDate: day(10), measurements: [{ kind: 'heart_rate', frequency: 'daily' }] }) },
  'GET /patients/:id/followups': { kind: 'ws', allow: CLINICAL_READ, p: { id: 'relA' } },
  'GET /followups/attention': { kind: 'ws', allow: CLINICAL_READ },
  'GET /followups/:id': { kind: 'ws', allow: CLINICAL_READ, p: { id: 'plan' } },
  'PATCH /followups/:id': { kind: 'ws', allow: D_ONLY, p: { id: 'plan' }, body: () => ({ instructions: 'probe edit' }), noPositive: true },
  'POST /followups/:id/close': { kind: 'ws', allow: D_ONLY, p: { id: 'plan' }, noPositive: true },
  'GET /followups/:id/history': { kind: 'ws', allow: CLINICAL_READ, p: { id: 'plan' } },
  'GET /followups/:id/measurements/:mid/trend': { kind: 'ws', allow: CLINICAL_READ, p: { id: 'plan', mid: 'measurement' } },

  // ----- clinic: data requests (F11-7) -----
  'GET /correction-requests': { kind: 'ws', allow: CLINICAL_READ },
  'POST /correction-requests/:id/resolve': { kind: 'ws', allow: D_ONLY, p: { id: 'correction' }, body: () => ({ note: 'probe note' }), noPositive: true },
  'POST /correction-requests/:id/reject': { kind: 'ws', allow: D_ONLY, p: { id: 'correction' }, body: () => ({ note: 'probe note' }), noPositive: true },
};

// ---------- fixtures ----------

let ctx: Awaited<ReturnType<typeof setupApp>>;
type Actor = Session & { workspaceId?: string };
let A: { d: Actor; n: Actor; r: Actor };
let B: Actor;
let U: Actor; // doctor whose licence/MFA is not verified (own workspace)
let P1: Session;
let P2: Session;
let ADMIN: Session;
let ADMIN_NO_MFA: Session;
let PLAIN: Session;

const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.from(`JFIF-${'x'.repeat(200)}`)]);
function multipart(fields: Record<string, string>) {
  const b = '----perm';
  const parts = Object.entries(fields).map(([k, v]) => `--${b}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${v}\r\n`);
  const body = Buffer.concat([Buffer.from(parts.join('')), Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="file"; filename="a.jpg"\r\nContent-Type: image/jpeg\r\n\r\n`), jpeg, Buffer.from(`\r\n--${b}--\r\n`)]);
  return { payload: body, type: `multipart/form-data; boundary=${b}` };
}
type H = { headers: Record<string, string> };
const req = (method: string, s: H | null, url: string, payload?: unknown, extra: Record<string, string> = {}) =>
  ctx.app.inject({ method: method as 'GET', url, headers: { ...(s?.headers ?? {}), ...extra }, payload: payload as never });
const send = (method: string, s: H | null, url: string, payload?: unknown) => req(method, s, url, payload);
const uploadDoc = async (s: H, url: string, fields: Record<string, string>) => {
  const m = multipart(fields);
  return req('POST', s, url, m.payload, { 'content-type': m.type });
};

async function build() {
  await reset(ctx.pool);
  const a = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
  const b = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000002');
  U = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000003', false);
  const invite = async (phone: string, role: 'nurse' | 'receptionist') => {
    const inv = (await send('POST', a, '/workspace/invitations', { phone, role })).json();
    const s = await login(ctx.app, phone);
    await send('POST', s, '/invitations/accept', { code: inv.code });
    return s;
  };
  const nurse = await invite('+201000000004', 'nurse');
  const rec = await invite('+201000000005', 'receptionist');
  A = { d: a, n: nurse, r: rec };
  B = b;

  P1 = await login(ctx.app, '+201111111111');
  P2 = await login(ctx.app, '+201222222222');
  PLAIN = await login(ctx.app, '+201000000010');
  ADMIN = await login(ctx.app, '+201000000009');
  await ctx.pool.query('update users set is_platform_admin = true where id = $1', [ADMIN.user.id]);
  await enableMfa(ctx.pool, ADMIN.user.id);
  ADMIN_NO_MFA = await login(ctx.app, '+201000000011');
  await ctx.pool.query('update users set is_platform_admin = true where id = $1', [ADMIN_NO_MFA.user.id]);

  const relA = (await send('POST', a, '/patients', { phone: '+201111111111', fullName: 'Mona Hassan' })).json().id as string;
  const relB = (await send('POST', b, '/patients', { phone: '+201222222222', fullName: 'Omar Ali' })).json().id as string;
  await send('POST', P1, '/patient/claim');
  await send('POST', P2, '/patient/claim');
  await send('POST', P1, `/patient/relationships/${relA}/accept`);
  await send('POST', P2, `/patient/relationships/${relB}/accept`);

  const e = (await send('POST', a, `/patients/${relA}/encounters`)).json();
  const saved = (await send('PATCH', a, `/encounters/${e.id}`, { revision: e.revision, chiefComplaint: 'Cough', diagnosis: 'Bronchitis', plan: 'Rest', privateNotes: 'SECRET NOTE', history: 'SECRET HISTORY', prescriptions: [{ medication: 'Amoxicillin' }] })).json();
  await send('POST', a, `/encounters/${e.id}/sign`, { revision: saved.revision });
  await send('POST', a, `/encounters/${e.id}/publish`);
  const draft = (await send('POST', a, `/patients/${relA}/encounters`)).json();
  const obs = (await send('POST', a, `/encounters/${draft.id}/observations`, { kind: 'heart_rate', value: 70 })).json();

  const appt = (await send('POST', a, '/appointments', { patientId: relA, scheduledAt: new Date(Date.now() + 3 * 86_400_000).toISOString(), override: true })).json();
  const doc = (await uploadDoc(a, `/patients/${relA}/documents`, { category: 'lab_result', title: 'CBC' })).json();
  await send('POST', a, `/documents/${doc.id}/publish`);
  const adminDoc = (await uploadDoc(a, `/patients/${relA}/documents`, { category: 'administrative', title: 'Consent form' })).json();
  const patientDoc = (await uploadDoc(P1, '/patient/documents', { category: 'other', title: 'My photo' })).json();
  await send('POST', P1, `/patient/documents/${patientDoc.id}/send`, { relationshipId: relA });

  const plan = (await send('POST', a, `/patients/${relA}/followups`, { instructions: 'Measure', nextVisitDate: day(14), endDate: day(14), measurements: [{ kind: 'heart_rate', frequency: 'daily', normalMin: 50, normalMax: 100 }] })).json();
  const members = (await send('GET', a, '/workspace/members')).json() as { id: string; role: string }[];
  const pendingInvite = (await send('POST', a, '/workspace/invitations', { phone: '+201777777777', role: 'nurse' })).json();
  const grant = (await send('POST', P1, '/patient/grants', { recipient: { doctorPhone: '+201000000002' }, scope: { categories: ['lab_result'] }, days: 7, acknowledgeRetention: true })).json();
  const accessReq = (await send('POST', a, `/patients/${relA}/access-requests`, { scope: { categories: ['report'] }, purpose: 'Second look', days: 7 })).json();
  const correction = (await send('POST', P1, '/patient/correction-requests', { targetType: 'encounter', targetId: e.id, description: 'The diagnosis looks wrong' })).json();
  const notification = (
    await ctx.pool.query(`insert into notifications (user_id, type, template_key, idempotency_key) values ($1,'followup_reminder','followup_reminder',$2) returning id`, [P1.user.id, randomUUID()])
  ).rows[0].id as string;
  const device = (await send('POST', P1, '/devices', { token: 'probe-device-token-1', platform: 'android' })).json();
  const sessions = (await send('GET', P1, '/sessions')).json() as { id: string }[];

  F = {
    relA,
    relB,
    enc: e.id,
    draftEnc: draft.id,
    obs: obs.id,
    appt: appt.id,
    doc: doc.id,
    adminDoc: adminDoc.id,
    patientDoc: patientDoc.id,
    plan: plan.id,
    measurement: plan.measurements[0].id,
    member: members.find((m) => m.role === 'nurse')!.id,
    invite: pendingInvite.id,
    grant: grant.id,
    accessReq: accessReq.id,
    correction: correction.id,
    notification,
    device: device.id,
    session: sessions[0]!.id,
    userId: P1.user.id,
    unknown: randomUUID(),
  };
  for (const [k, v] of Object.entries(F)) expect(v, `fixture ${k}`).toBeTruthy();
}

beforeAll(async () => {
  ctx = await setupApp();
  await build();
}, 120_000);
afterAll(async () => {
  await ctx.app.close();
  await ctx.pool.end();
});

const urlFor = (key: string, e: Entry) => {
  const [, path] = key.split(' ') as [string, string];
  return path.replace(/:(\w+)/g, (_m, name: string) => {
    const k = e.p?.[name];
    if (name === 'page') return '1';
    return k ? (F[k] as string) : F.unknown;
  }) + (e.query ?? '');
};
const methodOf = (key: string) => key.split(' ')[0]!;
const bodyFor = (e: Entry) => e.body?.();
async function call(key: string, e: Entry, who: H | null, bodyOverride?: unknown) {
  const url = urlFor(key, e);
  if (e.multipart) {
    const m = multipart({ category: 'lab_result', title: 'probe' });
    return req(methodOf(key), who, url, m.payload, { 'content-type': m.type });
  }
  return req(methodOf(key), who, url, bodyOverride ?? bodyFor(e));
}
const refused = (n: number) => n === 401 || n === 403;
const hasIds = (e: Entry) => !!e.p || !!e.bodyId;

describe('route inventory', () => {
  it('every registered route is classified in the matrix (fail closed for new routes)', () => {
    const registered = ctx.app.routeTable.map((r) => `${r.method} ${r.url}`);
    const unclassified = registered.filter((r) => !MATRIX[r]);
    expect(unclassified, `Unclassified routes: add them to MATRIX in test/permissions.test.ts:\n${unclassified.join('\n')}`).toEqual([]);
    const stale = Object.keys(MATRIX).filter((k) => !registered.includes(k));
    expect(stale, `Matrix entries without a route:\n${stale.join('\n')}`).toEqual([]);
  });

  it('is large enough to be real', () => {
    expect(ctx.app.routeTable.length).toBeGreaterThan(100);
  });
});

describe('unauthenticated requests are refused on every protected route', () => {
  it.each(Object.entries(MATRIX).filter(([, e]) => e.kind !== 'public'))('%s => 401', async (key, e) => {
    const res = await call(key, e, null);
    expect(res.statusCode, res.body).toBe(401);
    const bad = await call(key, e, { headers: { authorization: 'Bearer not.a.token' } });
    expect(bad.statusCode, bad.body).toBe(401);
  });
});

describe('public routes need no credentials but give nothing away', () => {
  it.each(Object.entries(MATRIX).filter(([, e]) => e.kind === 'public'))('%s', async (key, e) => {
    const res = await call(key, e, null);
    expect(e.publicStatus, `${key} -> ${res.statusCode} ${res.body}`).toContain(res.statusCode);
  });
});

describe('workspace routes: role and permission matrix', () => {
  const ws = Object.entries(MATRIX).filter(([, e]) => e.kind === 'ws');
  const members = (): [Who, Actor][] => [['d', A.d], ['n', A.n], ['r', A.r]];

  it.each(ws)('%s', async (key, e) => {
    const allow = e.allow!;
    const owner = e.owner ?? 'A';

    // Not a member of any workspace, patients and platform admins: always 403.
    for (const [name, s] of [['plain user', PLAIN], ['patient', P1], ['platform admin', ADMIN]] as const) {
      const res = await call(key, e, s);
      expect(res.statusCode, `${name} on ${key}: ${res.body}`).toBe(403);
    }

    // Unverified doctor: permissions of the doctor role minus those that need a verified licence + MFA.
    const u = !allow.includes('u') || hasIds(e) || methodOf(key) === 'GET' ? await call(key, e, U) : null;
    if (!allow.includes('u')) expect(u!.statusCode, `unverified doctor on ${key}: ${u!.body}`).toBe(403);
    else if (hasIds(e) && !e.foreignEmpty) expect(u!.statusCode, `RULE-003: other-clinic unverified doctor on ${key}: ${u!.body}`).toBe(404);
    else if (u && !hasIds(e)) expect(refused(u.statusCode) || u.statusCode >= 500, `unverified doctor on ${key}: ${u.body}`).toBe(false);

    // Doctor of the other clinic.
    const b = allow.includes('d') && !hasIds(e) && methodOf(key) !== 'GET' ? null : await call(key, e, B);
    if (!b) {
      // allowed, state-changing and without a foreign id: nothing to prove here beyond the permission check
    } else if (owner === 'B') {
      if (e.noPositive !== true) expect(refused(b.statusCode) || b.statusCode >= 500, `owner doctor B on ${key}: ${b.body}`).toBe(false);
    } else if (!allow.includes('d')) {
      expect(b.statusCode, `doctor B on ${key}: ${b.body}`).toBe(403);
    } else if (hasIds(e)) {
      if (e.foreignEmpty) {
        expect(b.statusCode, b.body).toBe(200);
        const j = b.json();
        expect(Array.isArray(j) ? j : j.points, `doctor B must see nothing on ${key}`).toEqual([]);
      } else {
        expect(b.statusCode, `RULE-003: doctor B on ${key}: ${b.body}`).toBe(404);
      }
    } else {
      expect(refused(b.statusCode) || b.statusCode >= 500, `doctor B on ${key}: ${b.body}`).toBe(false);
    }
    // Members of clinic A.
    for (const [who, s] of members()) {
      // Never fire state-changing calls as an authorised member: those are covered by the feature suites.
      if (owner === 'A' && allow.includes(who) && (methodOf(key) !== 'GET' || e.noPositive)) continue;
      const res = await call(key, e, s);
      if (owner === 'B') {
        // Clinic A is not the recipient of grant G: authorised role or not, the record must not exist for them.
        if (hasIds(e) && allow.includes(who)) expect(res.statusCode, `RULE-003: clinic A ${who} on ${key}: ${res.body}`).toBe(404);
        else expect(res.statusCode, `${who} on ${key}: ${res.body}`).toBe(allow.includes(who) ? res.statusCode : 403);
        continue;
      }
      if (!allow.includes(who)) {
        expect(res.statusCode, `${who} must be refused on ${key}: ${res.body}`).toBe(403);
      } else if (e.noPositive !== true && methodOf(key) === 'GET') {
        expect(refused(res.statusCode) || res.statusCode >= 500, `${who} must not be refused on ${key}: ${res.statusCode} ${res.body}`).toBe(false);
      }
    }
  });
});

describe('authed routes: own data only', () => {
  const rows = Object.entries(MATRIX).filter(([, e]) => e.kind === 'authed');
  it.each(rows)('%s', async (key, e) => {
    if (e.p) {
      // The id belongs to patient P1: everyone else (clinic doctor, other patient, admin) sees "not found".
      for (const s of [A.d, B, P2, PLAIN, ADMIN]) {
        const res = await call(key, e, s);
        expect(res.statusCode, `foreign user on ${key}: ${res.body}`).toBe(404);
      }
    } else if (e.noPositive !== true && methodOf(key) === 'GET') {
      const res = await call(key, e, PLAIN);
      expect(res.statusCode, res.body).toBeLessThan(300);
    }
  });
});

describe('patient routes: claimed patients and their own records only', () => {
  const rows = Object.entries(MATRIX).filter(([, e]) => e.kind === 'patient');
  it.each(rows)('%s', async (key, e) => {
    if (e.claim) {
      for (const [name, s] of [['clinic doctor', A.d], ['other clinic doctor', B], ['unclaimed user', PLAIN], ['admin', ADMIN]] as const) {
        const res = await call(key, e, s);
        expect(res.statusCode, `${name} on ${key}: ${res.body}`).toBe(403);
      }
    }
    if (e.p) {
      // Another patient (P2) presenting P1's ids.
      const res = await call(key, e, P2);
      expect(res.statusCode, `patient P2 on ${key}: ${res.body}`).toBe(404);
      for (const s of [A.d, B]) {
        const r2 = await call(key, e, s);
        expect([403, 404], `clinic user on patient route ${key}: ${r2.body}`).toContain(r2.statusCode);
      }
    }
    if (e.noPositive !== true && methodOf(key) === 'GET') {
      const res = await call(key, e, P1);
      expect(refused(res.statusCode) || res.statusCode >= 500, `P1 on ${key}: ${res.statusCode} ${res.body}`).toBe(false);
    }
  });
});

describe('admin routes', () => {
  const rows = Object.entries(MATRIX).filter(([, e]) => e.kind === 'admin');
  it.each(rows)('%s', async (key, e) => {
    for (const [name, s] of [['doctor', A.d], ['nurse', A.n], ['receptionist', A.r], ['patient', P1], ['plain user', PLAIN]] as const) {
      const res = await call(key, e, s);
      expect(res.statusCode, `${name} on ${key}: ${res.body}`).toBe(403);
    }
    if (e.strict) {
      const res = await call(key, e, ADMIN_NO_MFA);
      expect(res.statusCode, `admin without MFA on ${key}: ${res.body}`).toBe(403);
      expect(res.json().error).toBe('mfa_required');
    }
    if (e.noPositive !== true && methodOf(key) === 'GET') {
      const res = await call(key, e, ADMIN);
      expect(res.statusCode, res.body).toBe(200);
    }
  });
});

describe('RULE-003: clinics are sealed from each other', () => {
  it('doctor B cannot see any trace of clinic A in lists, searches or timelines', async () => {
    const pts = (await send('GET', B, '/patients?q=Mona')).json();
    expect(pts).toEqual([]);
    expect(JSON.stringify((await send('GET', B, '/patients')).json())).not.toContain('Mona');
    expect((await send('GET', B, '/appointments?patientId=' + F.relA)).json()).toEqual([]);
    expect((await send('GET', B, `/patients/${F.relA}/encounters`)).statusCode).toBe(404);
    expect((await send('GET', B, `/patients/${F.relA}/documents`)).statusCode).toBe(404);
    expect((await send('GET', B, `/patients/${F.relA}/followups`)).statusCode).toBe(404);
    expect((await send('GET', B, '/followups/attention')).json()).toEqual([]);
    // Clinic A's grants/requests never show up in B's inbox (the lab_result grant to B is B's own).
    expect((await send('GET', B, '/access-requests')).json()).toEqual([]);
    const audit = (await send('GET', B, '/workspace/audit?limit=200')).json() as { targetId: string }[];
    expect(audit.some((x) => x.targetId === F.enc || x.targetId === F.relA)).toBe(false);
  });

  it('a membership header cannot be used to act inside a clinic you do not belong to', async () => {
    const res = await req('GET', B, '/patients', undefined, { 'x-workspace-id': A.d.workspaceId! });
    expect(res.statusCode).toBe(403);
    const bad = await req('GET', B, '/patients', undefined, { 'x-workspace-id': 'not-a-uuid' });
    expect(bad.statusCode).toBe(400);
  });

  it('a revoked session loses access immediately', async () => {
    const s = await login(ctx.app, '+201000000012');
    expect((await send('GET', s, '/me')).statusCode).toBe(200);
    expect((await send('POST', s, '/auth/logout')).statusCode).toBe(204);
    expect((await send('GET', s, '/me')).statusCode).toBe(401);
  });

  it('patient P2 and clinic B cannot read P1 content through the patient endpoints', async () => {
    expect(JSON.stringify((await send('GET', P2, '/patient/encounters')).json())).not.toContain('Bronchitis');
    expect((await send('GET', P2, '/patient/documents')).json()).toEqual([]);
    expect((await send('GET', P2, '/patient/timeline')).json().items ?? []).toHaveLength(0);
    for (const s of [A.d, B]) expect((await send('GET', s, '/patient/encounters')).json()).toEqual([]);
  });
});

describe('RULE-005: front-desk (receptionist) limits', () => {
  it('cannot read any clinical content', async () => {
    for (const url of [`/patients/${F.relA}/encounters`, `/encounters/${F.enc}`, `/encounters/${F.enc}/versions`, `/encounters/${F.enc}/prescription`, `/patients/${F.relA}/observations?kind=heart_rate`, `/patients/${F.relA}/timeline`, `/patients/${F.relA}/followups`, `/followups/${F.plan}`, '/shared-with-me', '/access-requests', '/correction-requests', '/workspace/audit', '/workspace/members/x']) {
      const res = await send('GET', A.r, url);
      expect([403, 404], `${url}: ${res.body}`).toContain(res.statusCode);
      expect(res.body).not.toContain('Bronchitis');
    }
  });

  it('sees only administrative documents; clinical and patient-submitted files are invisible and unreachable', async () => {
    const list = (await send('GET', A.r, `/patients/${F.relA}/documents`)).json() as { id: string; category: string }[];
    expect(list.map((d) => d.id)).toEqual([F.adminDoc]);
    expect((await send('GET', A.r, `/documents/${F.doc}`)).statusCode).toBe(404);
    expect((await send('GET', A.r, `/documents/${F.patientDoc}`)).statusCode).toBe(404);
    expect((await send('GET', A.r, `/documents/${F.doc}/pages/1/link`)).statusCode).toBe(404);
    expect((await send('GET', A.r, `/documents/${F.patientDoc}/pages/1/link`)).statusCode).toBe(404);
    expect((await send('GET', A.r, `/documents/${F.adminDoc}/pages/1/link`)).statusCode).toBe(200);
  });

  it('cannot upload clinical documents, run consultations, publish or review', async () => {
    expect((await uploadDoc(A.r, `/patients/${F.relA}/documents`, { category: 'lab_result' })).statusCode).toBe(403);
    expect((await uploadDoc(A.r, `/patients/${F.relA}/documents`, { category: 'administrative' })).statusCode).toBe(201);
    for (const [m, u] of [['POST', `/appointments/${F.appt}/start`], ['POST', `/appointments/${F.appt}/complete`], ['POST', `/documents/${F.doc}/publish`], ['POST', `/documents/${F.patientDoc}/review`], ['POST', `/encounters/${F.enc}/publish`], ['POST', `/patients/${F.relA}/encounters`]] as const) {
      expect((await send(m, A.r, u, {})).statusCode, u).toBe(403);
    }
  });

  it("cannot delete someone else's clinical document or touch staff and audit settings", async () => {
    expect((await send('DELETE', A.r, `/documents/${F.doc}`, { reason: 'cleanup please' })).statusCode).toBe(403);
    const stillThere = (await send('GET', A.d, `/documents/${F.doc}`)).json();
    expect(stillThere.id).toBe(F.doc);
    for (const [m, u] of [['PATCH', `/workspace/members/${F.member}`], ['DELETE', `/workspace/members/${F.member}`], ['POST', '/workspace/invitations'], ['PATCH', '/workspace/settings'], ['GET', '/workspace/audit/export']] as const) {
      expect((await send(m, A.r, u, { status: 'suspended' })).statusCode, u).toBe(403);
    }
  });

  it('a nurse never sees the private notes', async () => {
    const res = (await send('GET', A.n, `/encounters/${F.enc}`)).json();
    expect(res.content.chiefComplaint).toBe('Cough');
    expect(res.content.privateNotes).toBeUndefined();
    expect(JSON.stringify(res)).not.toContain('SECRET NOTE');
    expect(JSON.stringify((await send('GET', A.n, `/encounters/${F.enc}/versions`)).json())).not.toContain('SECRET NOTE');
  });

  it('suspending a staff member ends their access on the next request', async () => {
    const m = (await send('GET', A.d, '/workspace/members')).json() as { id: string; role: string }[];
    const rec = m.find((x) => x.role === 'receptionist')!;
    expect((await send('GET', A.r, '/patients')).statusCode).toBe(200);
    expect((await send('PATCH', A.d, `/workspace/members/${rec.id}`, { status: 'suspended' })).statusCode).toBe(200);
    expect((await send('GET', A.r, '/patients')).statusCode).toBe(403);
    await send('PATCH', A.d, `/workspace/members/${rec.id}`, { status: 'active' });
    expect((await send('GET', A.r, '/patients')).statusCode).toBe(200);
  });

  it('permission denials are written to the clinic audit log with result=denied', async () => {
    await send('GET', A.r, '/workspace/audit');
    const log = (await send('GET', A.d, '/workspace/audit?result=denied')).json() as { action: string; result: string; actorRole: string }[];
    expect(log.some((l) => l.action === 'access.denied' && l.result === 'denied' && l.actorRole === 'receptionist')).toBe(true);
  });
});
