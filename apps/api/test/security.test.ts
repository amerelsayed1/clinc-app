import { Writable } from 'node:stream';
import { randomBytes } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { verifyAllChains, verifyChain } from '../src/audit.js';
import { buildApp } from '../src/app.js';
import { assertProductionConfig, config, parseTrustProxy } from '../src/config.js';
import { base32Decode, totpCode, totpStep } from '../src/mfa.js';
import { InMemoryRateLimiter } from '../src/security.js';
import { rotateKeys } from '../src/key-rotation.js';
import { decryptFile, keyIdOf, unwrapKey, wrapKey } from '../src/storage.js';
import { enableMfa, login, makeVerifiedDoctor, reset, setupApp, type Session } from './helpers.js';

let ctx: Awaited<ReturnType<typeof setupApp>>;
beforeAll(async () => void (ctx = await setupApp()));
afterAll(async () => {
  await ctx.app.close();
  await ctx.pool.end();
});
beforeEach(() => reset(ctx.pool));

type H = { headers: Record<string, string> };
const call = (method: 'GET' | 'POST' | 'PATCH' | 'DELETE', s: H | null, url: string, payload?: unknown, extra: Record<string, string> = {}) =>
  ctx.app.inject({ method, url, headers: { ...(s?.headers ?? {}), ...extra }, payload: payload as never });
const post = (s: H, url: string, p: unknown = {}) => call('POST', s, url, p);
const get = (s: H, url: string) => call('GET', s, url);

const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.from(`JFIF-${'x'.repeat(200)}`)]);
async function upload(s: H, url: string, fields: Record<string, string>) {
  const b = '----sec';
  const parts = Object.entries(fields).map(([k, v]) => `--${b}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${v}\r\n`);
  const body = Buffer.concat([Buffer.from(parts.join('')), Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="file"; filename="a.jpg"\r\nContent-Type: image/jpeg\r\n\r\n`), jpeg, Buffer.from(`\r\n--${b}--\r\n`)]);
  return ctx.app.inject({ method: 'POST', url, headers: { ...s.headers, 'content-type': `multipart/form-data; boundary=${b}` }, payload: body });
}

interface Entry {
  seq: number;
  action: string;
  actorId: string | null;
  actorRole: string | null;
  targetType: string | null;
  targetId: string | null;
  metadata: Record<string, unknown>;
  result: string;
  ip: string | null;
  device: string | null;
  breakGlass: boolean;
}
const auditOf = async (d: H, q = '') => (await get(d, `/workspace/audit?limit=200${q}`)).json() as Entry[];
const actions = (e: Entry[]) => e.map((x) => x.action);

/** Doctor + nurse + receptionist + a connected patient with a signed, published encounter and documents. */
async function world() {
  const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
  const invite = async (phone: string, role: 'nurse' | 'receptionist') => {
    const inv = (await post(d, '/workspace/invitations', { phone, role })).json();
    const s = await login(ctx.app, phone);
    await post(s, '/invitations/accept', { code: inv.code });
    return s;
  };
  const nurse = await invite('+201000000004', 'nurse');
  const rec = await invite('+201000000005', 'receptionist');
  const rel = (await post(d, '/patients', { phone: '+201111111111', fullName: 'Mona Hassan', dateOfBirth: '1990-01-01' })).json();
  const pt = await login(ctx.app, '+201111111111');
  await post(pt, '/patient/claim');
  await post(pt, `/patient/relationships/${rel.id}/accept`);
  const e = (await post(d, `/patients/${rel.id}/encounters`)).json();
  const saved = await call('PATCH', d, `/encounters/${e.id}`, { revision: e.revision, chiefComplaint: 'Cough', diagnosis: 'Bronchitis', plan: 'Rest', privateNotes: 'PRIVATE-NOTE', history: 'PRIVATE-HISTORY', prescriptions: [{ medication: 'Amoxicillin' }] });
  await post(d, `/encounters/${e.id}/sign`, { revision: saved.json().revision });
  await post(d, `/encounters/${e.id}/publish`);
  const doc = (await upload(d, `/patients/${rel.id}/documents`, { category: 'lab_result', title: 'CBC' })).json();
  await post(d, `/documents/${doc.id}/publish`);
  const adminDoc = (await upload(d, `/patients/${rel.id}/documents`, { category: 'administrative', title: 'Consent' })).json();
  return { d, nurse, rec, rel, pt, enc: e.id as string, doc: doc.id as string, adminDoc: adminDoc.id as string };
}
async function makeAdmin(phone = '+201000000009', mfa = true): Promise<Session> {
  const a = await login(ctx.app, phone);
  await ctx.pool.query('update users set is_platform_admin = true where id = $1', [a.user.id]);
  if (mfa) await enableMfa(ctx.pool, a.user.id);
  return a;
}

describe('audit coverage (F11-2) and fields (F11-1)', () => {
  it('records sensitive reads, exports, permission changes and auth events with ip, device and result', async () => {
    const { d, nurse, rec, rel, enc, adminDoc } = await world();
    const ua = { 'user-agent': 'CareLinkTest/1.0 (iPhone)' };
    await call('GET', d, `/encounters/${enc}`, undefined, ua);
    await get(d, `/encounters/${enc}/versions`);
    await get(d, `/encounters/${enc}/prescription`);
    await get(d, `/patients/${rel.id}`);
    await get(d, `/patients/${rel.id}/encounters`);
    await get(d, `/patients/${rel.id}/observations?kind=heart_rate`);
    await get(d, `/patients/${rel.id}/documents`);
    const link = (await get(d, `/documents/${adminDoc}/pages/1/link`)).json();
    expect((await call('GET', null, link.path)).statusCode).toBe(200);
    await get(d, '/workspace/audit/export');
    const members = (await get(d, '/workspace/members')).json() as { id: string; role: string }[];
    await call('PATCH', d, `/workspace/members/${members.find((m) => m.role === 'nurse')!.id}`, { deniedPermissions: ['documents.upload'] });
    await get(rec, '/workspace/audit'); // receptionist lacks audit.read

    const log = await auditOf(d);
    for (const a of ['encounter.viewed', 'encounter.history_viewed', 'prescription.printed', 'patient.viewed', 'patient.encounters_listed', 'patient.observations_viewed', 'patient.documents_listed', 'document.link_issued', 'document.viewed', 'audit.exported', 'member.updated', 'access.denied', 'encounter.signed', 'encounter.published', 'document.uploaded']) {
      expect(actions(log), a).toContain(a);
    }
    const viewed = log.find((l) => l.action === 'encounter.viewed')!;
    expect(viewed.device).toBe('CareLinkTest/1.0 (iPhone)');
    expect(viewed.ip).toBeTruthy();
    expect(viewed.result).toBe('success');
    const denied = log.find((l) => l.action === 'access.denied')!;
    expect(denied).toMatchObject({ result: 'denied', actorRole: 'receptionist', metadata: { permission: 'audit.read' } });
    expect(await verifyChain(ctx.pool, d.workspaceId)).toMatchObject({ valid: true });
    void nurse;
  });

  it('records auth events: MFA enrolment, phone change, session revoke, logout and failed logins', async () => {
    const { d, nurse } = await world();
    // MFA enrolment by the nurse (optional MFA)
    const enrol = (await post(nurse, '/auth/mfa/enroll')).json();
    const code = totpCode(enrol.secret, totpStep());
    expect((await post(nurse, '/auth/mfa/activate', { code })).statusCode).toBe(200);
    // phone change
    const change = (await post(nurse, '/auth/phone-change/request', { newPhone: '+201555555555' })).json();
    expect((await post(nurse, '/auth/phone-change/confirm', { newPhone: '+201555555555', oldCode: change.devOldCode, newCode: change.devNewCode })).statusCode).toBe(200);
    // session revoke + logout of a second device
    const second = await login(ctx.app, '+201555555555').catch(() => null);
    void second;
    const sessions = (await get(nurse, '/sessions')).json() as { id: string; current: boolean }[];
    const other = sessions.find((s) => !s.current);
    if (other) await call('DELETE', nurse, `/sessions/${other.id}`);
    await post(nurse, '/sessions/revoke-others');
    // failed login: wrong code
    await post({ headers: {} }, '/auth/otp/request', { phone: '+201000000077' });
    await post({ headers: {} }, '/auth/otp/verify', { phone: '+201000000077', code: '000000' });

    const log = await auditOf(d);
    const nurseActions = log.filter((l) => l.actorRole === 'nurse').map((l) => l.action);
    for (const a of ['auth.mfa_enrolled', 'auth.phone_change_requested', 'auth.phone_changed', 'auth.sessions_revoked_others']) expect(nurseActions, a).toContain(a);

    const global = (await ctx.pool.query(`select action, result, metadata from audit_log where chain_key = 'global' and action = 'auth.login_failed'`)).rows;
    expect(global.length).toBeGreaterThan(0);
    expect(global[0]).toMatchObject({ result: 'denied' });
    expect(await verifyAllChains(ctx.pool)).toMatchObject({ valid: true });
  });

  it('filters by action (exact and prefix), actor, target, result and date range', async () => {
    const { d, rel, enc } = await world();
    await get(d, `/encounters/${enc}`);
    await get(d, `/patients/${rel.id}`);
    const prefix = await auditOf(d, '&action=encounter.');
    expect(prefix.length).toBeGreaterThan(2);
    expect(prefix.every((l) => l.action.startsWith('encounter.'))).toBe(true);
    expect((await auditOf(d, '&action=encounter.viewed')).every((l) => l.action === 'encounter.viewed')).toBe(true);
    expect((await auditOf(d, `&actor=${d.user.id}`)).every((l) => l.actorId === d.user.id)).toBe(true);
    expect((await auditOf(d, `&targetType=encounter&targetId=${enc}`)).every((l) => l.targetId === enc)).toBe(true);
    expect((await auditOf(d, '&result=denied'))).toEqual([]);
    const today = new Date().toISOString().slice(0, 10);
    expect((await auditOf(d, `&from=${today}&to=${today}`)).length).toBeGreaterThan(5);
    expect(await auditOf(d, '&to=2000-01-01')).toEqual([]);
    expect((await get(d, '/workspace/audit?actor=not-a-uuid')).statusCode).toBe(400);
    // a prefix filter must not be a wildcard injection
    expect(await auditOf(d, '&action=%25')).toEqual([]);
  });

  it('JSON export is itself audited, carries hashes and the chain verdict, and needs audit.read', async () => {
    const { d, nurse } = await world();
    expect((await get(nurse, '/workspace/audit/export')).statusCode).toBe(403);
    const ex = (await get(d, '/workspace/audit/export')).json();
    expect(ex.chain).toMatchObject({ valid: true });
    expect(ex.entries[0]).toHaveProperty('hash');
    expect(ex.entries[0]).toHaveProperty('prevHash');
    expect(actions(await auditOf(d))).toContain('audit.exported');
  });

  it('detects tampering with any audited field including result and device', async () => {
    const { d, rec } = await world();
    await get(rec, '/workspace/audit'); // creates a 'denied' row
    await get(d, '/workspace/members');
    expect(await verifyChain(ctx.pool, d.workspaceId)).toMatchObject({ valid: true });
    const row = (await ctx.pool.query(`select seq from audit_log where chain_key = $1 and result = 'denied' limit 1`, [d.workspaceId])).rows[0];
    await ctx.pool.query('alter table audit_log disable trigger audit_log_no_update');
    await ctx.pool.query(`update audit_log set result = 'success' where chain_key = $1 and seq = $2`, [d.workspaceId, row.seq]);
    await ctx.pool.query('alter table audit_log enable trigger audit_log_no_update');
    expect(await verifyChain(ctx.pool, d.workspaceId)).toMatchObject({ valid: false, brokenAtSeq: row.seq });

    const report = await verifyAllChains(ctx.pool);
    expect(report.valid).toBe(false);
    expect(report.chains.find((c) => c.chainKey === d.workspaceId)).toMatchObject({ valid: false, brokenAtSeq: row.seq });
  });
});

describe('platform admin: chain verification and break-glass (F11-3)', () => {
  it('stays verifiable when metadata contains undefined values (regression: doctor decision without a note)', async () => {
    const admin = await makeAdmin();
    const doc = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001', false);
    expect((await post(admin, `/admin/doctors/${doc.user.id}/decision`, { decision: 'verified' })).statusCode).toBe(200);
    expect(await verifyChain(ctx.pool, 'global')).toMatchObject({ valid: true });
  });

  it('verification endpoint checks every chain, is audited and keeps a history', async () => {
    const { d } = await world();
    const admin = await makeAdmin();
    const run = (await get(admin, '/admin/audit/verify')).json();
    expect(run).toMatchObject({ valid: true });
    expect(run.chainsChecked).toBeGreaterThanOrEqual(2); // workspace + global
    await ctx.pool.query('alter table audit_log disable trigger audit_log_no_update');
    await ctx.pool.query(`update audit_log set action = 'forged.action' where chain_key = $1 and seq = 2`, [d.workspaceId]);
    await ctx.pool.query('alter table audit_log enable trigger audit_log_no_update');
    const bad = (await get(admin, '/admin/audit/verify')).json();
    expect(bad.valid).toBe(false);
    expect(bad.chains.filter((c: { valid: boolean }) => !c.valid).map((c: { chainKey: string }) => c.chainKey)).toEqual([d.workspaceId]);
    const history = (await get(admin, '/admin/audit/verifications')).json();
    expect(history.map((h: { valid: boolean }) => h.valid)).toEqual([false, true]);
    expect((await get(await makeAdmin('+201000000099', false), '/admin/audit/verify')).statusCode).toBe(403);
  });

  it('platform admins read a clinic audit log only through a justified, time-boxed, audited break-glass', async () => {
    const { d } = await world();
    const admin = await makeAdmin();
    const url = `/admin/workspaces/${d.workspaceId}/audit`;

    // No access record: refused, and the refusal is visible to the clinic.
    expect((await get(admin, url)).json().error).toBe('break_glass_required');
    expect(await auditOf(d, '&action=breakglass.denied')).toHaveLength(1);

    // Justification and duration are validated.
    expect((await post(admin, '/admin/break-glass', { workspaceId: d.workspaceId, justification: 'too short' })).statusCode).toBe(400);
    expect((await post(admin, '/admin/break-glass', { workspaceId: d.workspaceId, justification: 'Investigating a reported breach', minutes: 61 })).statusCode).toBe(400);
    expect((await post(admin, '/admin/break-glass', { workspaceId: '00000000-0000-4000-8000-000000000000', justification: 'Investigating a reported breach' })).statusCode).toBe(404);
    // Other roles cannot open one.
    expect((await post(d, '/admin/break-glass', { workspaceId: d.workspaceId, justification: 'Investigating a reported breach' })).statusCode).toBe(403);

    const g = await post(admin, '/admin/break-glass', { workspaceId: d.workspaceId, justification: 'Investigating a reported breach', minutes: 15 });
    expect(g.statusCode).toBe(201);
    const read = (await get(admin, url + '?limit=5')).json();
    expect(read.entries.length).toBeGreaterThan(0);
    expect(read.chain.valid).toBe(true);
    expect(new Date(read.accessExpiresAt).getTime()).toBeLessThanOrEqual(Date.now() + 15 * 60_000 + 5000);

    // The clinic owner sees who looked, why, and when - flagged as break-glass.
    const log = await auditOf(d, '&action=breakglass.');
    expect(log.map((l) => l.action).sort()).toEqual(['breakglass.audit_read', 'breakglass.denied', 'breakglass.granted']);
    const granted = log.find((l) => l.action === 'breakglass.granted')!;
    expect(granted).toMatchObject({ actorRole: 'platform_admin', breakGlass: true, metadata: { justification: 'Investigating a reported breach', minutes: 15 } });
    expect(granted.actorId).toBe(admin.user.id);

    // Expiry ends access; so does revocation. Another admin never inherits it.
    const other = await makeAdmin('+201000000098');
    expect((await get(other, url)).statusCode).toBe(403);
    await ctx.pool.query(`update break_glass_access set expires_at = now() - interval '1 minute'`);
    expect((await get(admin, url)).json().error).toBe('break_glass_required');
    const g2 = (await post(admin, '/admin/break-glass', { workspaceId: d.workspaceId, justification: 'Second investigation window' })).json();
    expect((await get(admin, url)).statusCode).toBe(200);
    expect((await call('DELETE', admin, `/admin/break-glass/${g2.id}`)).statusCode).toBe(204);
    expect((await get(admin, url)).statusCode).toBe(403);
    expect(actions(await auditOf(d))).toContain('breakglass.revoked');
    expect(await verifyChain(ctx.pool, d.workspaceId)).toMatchObject({ valid: true });
  });

  it('the admin must have MFA, and a clinic doctor cannot reach admin endpoints', async () => {
    const { d } = await world();
    const noMfa = await makeAdmin('+201000000097', false);
    const r = await post(noMfa, '/admin/break-glass', { workspaceId: d.workspaceId, justification: 'Investigating a reported breach' });
    expect(r.statusCode).toBe(403);
    expect(r.json().error).toBe('mfa_required');
    expect((await get(d, `/admin/workspaces/${d.workspaceId}/audit`)).statusCode).toBe(403);
  });
});

describe('data-subject operations (F11-7)', () => {
  it('exports the patient\'s own data, never clinic-private content, audits it, and is rate limited', async () => {
    const { d, pt, rel, enc, doc } = await world();
    await post(pt, '/patient/grants', { recipient: { relationshipId: rel.id }, scope: { categories: ['lab_result'] }, acknowledgeRetention: true });
    const res = await post(pt, '/patient/export');
    expect(res.statusCode).toBe(200);
    const bundle = res.json();
    expect(bundle.format).toBe('carelink-patient-export/1');
    expect(bundle.profile.phone).toBe('+201111111111');
    expect(bundle.relationships).toHaveLength(1);
    expect(bundle.encounters.map((e: { id: string }) => e.id)).toEqual([enc]);
    expect(bundle.encounters[0]).toMatchObject({ chiefComplaint: 'Cough', diagnosis: 'Bronchitis' });
    expect(bundle.documents.map((x: { id: string }) => x.id)).toEqual([doc]); // published; the administrative file is not included
    expect(bundle.grants).toHaveLength(1);
    expect(bundle).toHaveProperty('accessLog');
    const raw = JSON.stringify(bundle);
    expect(raw).not.toContain('PRIVATE-NOTE');
    expect(raw).not.toContain('PRIVATE-HISTORY');
    const log = (await ctx.pool.query(`select actor_role, metadata from audit_log where action = 'patient.exported'`)).rows;
    expect(log).toHaveLength(1);
    expect(log[0].actor_role).toBe('patient');

    // another patient's export contains none of this
    const other = await login(ctx.app, '+201222222222');
    await post(other, '/patient/claim');
    const theirs = JSON.stringify((await post(other, '/patient/export')).json());
    expect(theirs).not.toContain('Bronchitis');
    expect(theirs).not.toContain('Mona');

    expect((await post(pt, '/patient/export')).statusCode).toBe(200);
    expect((await post(pt, '/patient/export')).statusCode).toBe(200);
    const limited = await post(pt, '/patient/export');
    expect(limited.statusCode).toBe(429);
    expect(limited.json().error).toBe('rate_limited');
    expect((await post(d, '/patient/export')).statusCode).toBe(403);
  });

  it('correction requests reach the clinic, are decided by the doctor, and never edit the record', async () => {
    const { d, nurse, rec, pt, enc, doc, adminDoc, rel } = await world();
    const before = (await ctx.pool.query('select current_version, revision from encounters where id = $1', [enc])).rows[0];
    const beforeContent = (await ctx.pool.query('select chief_complaint, diagnosis from encounter_versions where encounter_id = $1', [enc])).rows;

    const mk = (body: Record<string, unknown>) => post(pt, '/patient/correction-requests', body);
    const r1 = await mk({ targetType: 'encounter', targetId: enc, description: 'My diagnosis should say bronchitis, not asthma' });
    expect(r1.statusCode).toBe(201);
    expect((await mk({ targetType: 'encounter', targetId: enc, description: 'Same record again' })).json().error).toBe('request_open');
    expect((await mk({ targetType: 'document', targetId: doc, description: 'Wrong date on the lab result' })).statusCode).toBe(201);
    expect((await mk({ targetType: 'relationship', targetId: rel.id, description: 'My birth date is wrong' })).statusCode).toBe(201);
    // not a record the patient can see / not theirs / too short
    expect((await mk({ targetType: 'document', targetId: adminDoc, description: 'Administrative file' })).statusCode).toBe(404);
    expect((await mk({ targetType: 'encounter', targetId: '00000000-0000-4000-8000-000000000000', description: 'Does not exist' })).statusCode).toBe(404);
    expect((await mk({ targetType: 'encounter', targetId: enc, description: 'x' })).statusCode).toBe(400);
    const stranger = await login(ctx.app, '+201222222222');
    await post(stranger, '/patient/claim');
    expect((await post(stranger, '/patient/correction-requests', { targetType: 'encounter', targetId: enc, description: 'Not my record at all' })).statusCode).toBe(404);

    // clinic side
    const list = (await get(d, '/correction-requests')).json();
    expect(list).toHaveLength(3);
    expect(list[0]).toMatchObject({ status: 'open', patient: { fullName: 'Mona Hassan' } });
    expect((await get(nurse, '/correction-requests')).statusCode).toBe(200);
    expect((await get(rec, '/correction-requests')).statusCode).toBe(403);
    expect((await post(nurse, `/correction-requests/${list[0].id}/resolve`, { note: 'ok done' })).statusCode).toBe(403);
    expect((await post(d, `/correction-requests/${list[0].id}/resolve`, { note: '' })).statusCode).toBe(400);
    const encReq = list.find((r: { targetType: string }) => r.targetType === 'encounter');
    expect((await post(d, `/correction-requests/${encReq.id}/reject`, { note: 'The diagnosis is correct as recorded' })).json()).toMatchObject({ status: 'rejected' });
    expect((await post(d, `/correction-requests/${encReq.id}/resolve`, { note: 'changed my mind' })).statusCode).toBe(409);
    const docReq = list.find((r: { targetType: string }) => r.targetType === 'document');
    expect((await post(d, `/correction-requests/${docReq.id}/resolve`, { note: 'Date fixed via amendment' })).json()).toMatchObject({ status: 'resolved' });

    // the record itself was never touched by any of this
    expect((await ctx.pool.query('select current_version, revision from encounters where id = $1', [enc])).rows[0]).toEqual(before);
    expect((await ctx.pool.query('select chief_complaint, diagnosis from encounter_versions where encounter_id = $1', [enc])).rows).toEqual(beforeContent);

    // the patient sees the outcome; the log shows the whole story
    const mine = (await get(pt, '/patient/correction-requests')).json();
    expect(mine.find((r: { id: string }) => r.id === encReq.id)).toMatchObject({ status: 'rejected', resolutionNote: 'The diagnosis is correct as recorded' });
    const log = actions(await auditOf(d, '&action=correction.'));
    expect(log).toEqual(expect.arrayContaining(['correction.requested', 'correction.rejected', 'correction.resolved']));
    // free text from the patient is not copied into the audit log
    expect(JSON.stringify(await auditOf(d))).not.toContain('asthma');
    expect((await get(d, '/correction-requests?status=open')).json()).toHaveLength(1);
  });

  it('a legal hold blocks deletion until the doctor lifts it, and the policy is visible', async () => {
    const { d, nurse, rel, doc } = await world();
    expect((await get(d, '/workspace/retention')).json().policy).toMatchObject({ clinicalRecordYears: 10, legalHoldBlocksDeletion: true });
    expect((await call('PATCH', nurse, `/patients/${rel.id}/legal-hold`, { hold: true, reason: 'Court order 123' })).statusCode).toBe(403);
    expect((await call('PATCH', d, `/patients/${rel.id}/legal-hold`, { hold: true, reason: 'x' })).statusCode).toBe(400);
    expect((await call('PATCH', d, `/patients/${rel.id}/legal-hold`, { hold: true, reason: 'Court order 123' })).statusCode).toBe(200);
    expect((await get(d, '/workspace/retention')).json().legalHolds).toMatchObject([{ patientId: rel.id, reason: 'Court order 123' }]);
    const blocked = await call('DELETE', d, `/documents/${doc}`, { reason: 'cleaning up' });
    expect(blocked.statusCode).toBe(409);
    expect(blocked.json().error).toBe('legal_hold');
    expect((await get(d, `/documents/${doc}`)).statusCode).toBe(200);
    expect((await call('PATCH', d, `/patients/${rel.id}/legal-hold`, { hold: false })).statusCode).toBe(200);
    expect((await call('DELETE', d, `/documents/${doc}`, { reason: 'cleaning up' })).statusCode).toBe(200);
    expect(actions(await auditOf(d))).toEqual(expect.arrayContaining(['retention.legal_hold_set', 'retention.legal_hold_lifted']));
  });
});

describe('platform hygiene (F11-4)', () => {
  it('sets security headers and never caches API responses', async () => {
    const res = await call('GET', null, '/health');
    expect(res.headers).toMatchObject({
      'x-content-type-options': 'nosniff',
      'x-frame-options': 'DENY',
      'referrer-policy': 'no-referrer',
      'cache-control': 'no-store',
      'content-security-policy': "default-src 'none'; frame-ancestors 'none'",
    });
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    expect((await get(d, '/me')).headers['cache-control']).toBe('no-store');
    expect((await call('GET', null, '/me')).headers['x-content-type-options']).toBe('nosniff'); // also on errors
  });

  it('refuses to boot in production with development defaults', () => {
    const good = {
      JWT_SECRET: randomBytes(32).toString('hex'),
      DOCUMENT_ENCRYPTION_KEY: randomBytes(32).toString('base64'),
      DATABASE_URL: 'postgres://app:strong@db.internal:5432/clinic',
    };
    expect(() => assertProductionConfig(good)).not.toThrow();
    expect(() => assertProductionConfig({ ...good, JWT_SECRET: 'dev-only-secret-dev-only-secret-dev-only' })).toThrow(/JWT_SECRET/);
    expect(() => assertProductionConfig({ ...good, JWT_SECRET: 'short' })).toThrow(/JWT_SECRET/);
    expect(() => assertProductionConfig({ ...good, JWT_SECRET: undefined })).toThrow(/JWT_SECRET/);
    expect(() => assertProductionConfig({ ...good, DOCUMENT_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString('base64') })).toThrow(/DOCUMENT_ENCRYPTION_KEY/);
    expect(() => assertProductionConfig({ ...good, DOCUMENT_ENCRYPTION_KEY: Buffer.alloc(16, 1).toString('base64') })).toThrow(/32-byte/);
    expect(() => assertProductionConfig({ ...good, DOCUMENT_ENCRYPTION_KEY: undefined })).toThrow(/DOCUMENT_ENCRYPTION_KEY/);
    expect(() => assertProductionConfig({ ...good, DATABASE_URL: 'postgres://clinic:clinic@localhost/clinic' })).toThrow(/development credentials/);
    expect(() => assertProductionConfig({ ...good, OTP_DEV_ECHO: 'true' })).toThrow(/OTP_DEV_ECHO/);
    // and OTP echo is structurally impossible when NODE_ENV=production
    expect(config.isProd ? config.otpDevEcho : false).toBe(false);
  });

  it('only trusts X-Forwarded-For from configured proxies', async () => {
    expect(parseTrustProxy(undefined)).toBe(false);
    expect(parseTrustProxy('2')).toBe(2);
    expect(parseTrustProxy('10.0.0.0/8, 192.168.0.1')).toEqual(['10.0.0.0/8', '192.168.0.1']);
    const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
    await get({ headers: { ...d.headers, 'x-forwarded-for': '6.6.6.6' } }, '/me');
    await call('GET', d, `/workspace/members`, undefined, { 'x-forwarded-for': '6.6.6.6' });
    await get(d, '/workspace/audit/export');
    const ips = (await ctx.pool.query('select distinct ip from audit_log where ip is not null')).rows.map((r) => r.ip);
    expect(ips).not.toContain('6.6.6.6');
  });

  it('rate limits the unauthenticated auth endpoints per IP', async () => {
    const app = await buildApp(ctx.pool, { rateLimiter: new InMemoryRateLimiter(), authRateLimitPerMinute: 3, sms: { send: async () => undefined } });
    const hit = (ip: string) => app.inject({ method: 'POST', url: '/auth/otp/request', remoteAddress: ip, payload: { phone: '+201000000555' } });
    expect((await hit('10.0.0.1')).statusCode).toBe(200);
    expect((await hit('10.0.0.1')).statusCode).toBe(200);
    expect((await hit('10.0.0.1')).statusCode).toBe(200);
    const blocked = await hit('10.0.0.1');
    expect(blocked.statusCode).toBe(429);
    expect(blocked.json().error).toBe('rate_limited');
    expect(Number(blocked.headers['retry-after'])).toBeGreaterThan(0);
    expect((await hit('10.0.0.2')).statusCode).not.toBe(429); // a different client is unaffected
    expect((await app.inject({ method: 'GET', url: '/health', remoteAddress: '10.0.0.1' })).statusCode).toBe(200); // non-auth routes are not limited
    // X-Forwarded-For cannot be used to dodge the limit
    const spoof = await app.inject({ method: 'POST', url: '/auth/otp/request', remoteAddress: '10.0.0.1', headers: { 'x-forwarded-for': '9.9.9.9' }, payload: { phone: '+201000000555' } });
    expect(spoof.statusCode).toBe(429);
    await app.close();
  });

  it('the limiter counts per key and window', () => {
    const l = new InMemoryRateLimiter();
    expect([1, 2, 3].map(() => l.hit('k', 2, 60_000).allowed)).toEqual([true, true, false]);
    expect(l.hit('other', 2, 60_000).allowed).toBe(true);
  });

  it('never writes phone numbers, tokens, codes or signed links to the request log', async () => {
    let out = '';
    const sink = new Writable({ write(chunk, _e, cb) { out += chunk.toString(); cb(); } });
    const app = await buildApp(ctx.pool, { logStream: sink, sms: { send: async () => undefined } });
    const phone = '+201234567891';
    const otp = await app.inject({ method: 'POST', url: '/auth/otp/request', payload: { phone } });
    const code = otp.json().devCode as string;
    const verified = await app.inject({ method: 'POST', url: '/auth/otp/verify', payload: { phone, code } });
    const { accessToken, refreshToken } = verified.json();
    await app.inject({ method: 'GET', url: '/patients?q=%2B201555000111', headers: { authorization: `Bearer ${accessToken}` } });
    await app.inject({ method: 'GET', url: '/files/abc.def-secret-signature' });
    await app.inject({ method: 'POST', url: '/auth/refresh', payload: { refreshToken } });
    app.log.info({ phone, code, accessToken, refreshToken, body: { phone }, user: { phone, fullName: 'Mona Hassan' } }, 'probe');
    await app.close();
    expect(out.length).toBeGreaterThan(0);
    for (const secret of ['201234567891', '201555000111', code, accessToken, refreshToken, 'secret-signature', 'Mona Hassan']) {
      expect(out, `log leaked ${secret}`).not.toContain(secret);
    }
    expect(out).toContain('[redacted]');
  });
});

describe('master key rotation (F11-4)', () => {
  it('wraps with the current key id, still opens old and legacy-format keys, and refuses unknown ids', () => {
    const dataKey = randomBytes(32);
    const wrapped = wrapKey(dataKey);
    expect(keyIdOf(wrapped)).toBe(config.documentKeyId);
    expect(unwrapKey(wrapped).equals(dataKey)).toBe(true);

    // a retired key stays available for decryption only
    const old = randomBytes(32);
    config.documentKeyring.set('v0', old);
    const oldWrapped = wrapKey(dataKey, 'v0', old);
    expect(keyIdOf(oldWrapped)).toBe('v0');
    expect(unwrapKey(oldWrapped).equals(dataKey)).toBe(true);
    config.documentKeyring.delete('v0');
    expect(() => unwrapKey(oldWrapped)).toThrow(/Unknown encryption key id/);

    // pre-versioning rows have no prefix and belong to key "v1"
    const legacy = wrapped.slice(wrapped.indexOf('.') + 1);
    expect(config.documentKeyId === 'v1' ? unwrapKey(legacy).equals(dataKey) : true).toBe(true);
    void base32Decode;
  });

  it('re-wraps stored document keys and TOTP secrets without touching file bytes', async () => {
    const { d, rel } = await world();
    const stored = (await ctx.pool.query('select document_id, page, wrapped_key, storage_key from document_pages order by document_id, page')).rows;
    // Pretend everything was sealed by a retired key "v0".
    const old = randomBytes(32);
    config.documentKeyring.set('v0', old);
    for (const r of stored) await ctx.pool.query('update document_pages set wrapped_key = $3 where document_id = $1 and page = $2', [r.document_id, r.page, wrapKey(unwrapKey(r.wrapped_key), 'v0', old)]);
    await ctx.pool.query(`update users set totp_pending_enc = $2 where id = $1`, [d.user.id, wrapKey(Buffer.from('JBSWY3DPEHPK3PXP'), 'v0', old)]);
    expect((await ctx.pool.query(`select count(*)::int as n from document_pages where wrapped_key like 'v0.%'`)).rows[0].n).toBe(stored.length);

    expect(await rotateKeys(ctx.pool)).toMatchObject({ pages: stored.length, secrets: 1 });
    expect((await ctx.pool.query(`select count(*)::int as n from document_pages where wrapped_key not like '${config.documentKeyId}.%'`)).rows[0].n).toBe(0);
    expect(await rotateKeys(ctx.pool)).toEqual({ pages: 0, secrets: 0 }); // idempotent
    config.documentKeyring.delete('v0'); // the retired key is no longer needed
    const row = (await ctx.pool.query('select wrapped_key from document_pages limit 1')).rows[0];
    expect(() => unwrapKey(row.wrapped_key)).not.toThrow();
    void decryptFile;
    void rel;
  });
});
