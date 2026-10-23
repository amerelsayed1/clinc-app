import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { verifyChain } from '../src/audit.js';
import { EICAR_TEST_STRING, LocalObjectStore, signLink } from '../src/storage.js';
import { login, makeVerifiedDoctor, reset, setupApp } from './helpers.js';

let ctx: Awaited<ReturnType<typeof setupApp>>;
const store = new LocalObjectStore('.data/test-objects');
beforeAll(async () => void (ctx = await setupApp()));
afterAll(async () => {
  await ctx.app.close();
  await ctx.pool.end();
});
beforeEach(() => reset(ctx.pool));

type Doctor = Awaited<ReturnType<typeof makeVerifiedDoctor>>;
type H = { headers: Record<string, string> };

const jpeg = (marker = 'page-1') => Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.from(`JFIF-${marker}-${'x'.repeat(200)}`)]);
const png = (marker = 'png') => Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from(`${marker}-${'y'.repeat(100)}`)]);
const pdf = (marker = 'pdf') => Buffer.from(`%PDF-1.4\n${marker}\n%%EOF`);

interface F {
  name: string;
  buf: Buffer;
  type?: string;
}
function multipart(fields: Record<string, string>, files: F[]) {
  const b = `----test${Math.random().toString(16).slice(2)}`;
  const parts: Buffer[] = [];
  for (const [k, v] of Object.entries(fields)) parts.push(Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${v}\r\n`));
  for (const f of files) {
    parts.push(Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="file"; filename="${f.name}"\r\nContent-Type: ${f.type ?? 'image/jpeg'}\r\n\r\n`), f.buf, Buffer.from('\r\n'));
  }
  parts.push(Buffer.from(`--${b}--\r\n`));
  return { payload: Buffer.concat(parts), contentType: `multipart/form-data; boundary=${b}` };
}
const upload = (s: H, url: string, fields: Record<string, string>, files: F[]) => {
  const { payload, contentType } = multipart(fields, files);
  return ctx.app.inject({ method: 'POST', url, headers: { ...s.headers, 'content-type': contentType }, payload });
};
const post = (s: H, url: string, payload: Record<string, unknown> = {}) => ctx.app.inject({ method: 'POST', url, headers: s.headers, payload });
const get = (s: H, url: string) => ctx.app.inject({ method: 'GET', url, headers: s.headers });
const del = (s: H, url: string, payload?: Record<string, unknown>) => ctx.app.inject({ method: 'DELETE', url, headers: s.headers, payload });

async function staffOf(d: Doctor, phone: string, role: 'nurse' | 'receptionist') {
  const inv = (await post(d, '/workspace/invitations', { phone, role })).json();
  const s = await login(ctx.app, phone);
  await post(s, '/invitations/accept', { code: inv.code });
  return s;
}
async function setup() {
  const d = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000001');
  const pat = (await post(d, '/patients', { phone: '+201111111111', fullName: 'Mona Hassan' })).json();
  return { d, pat };
}
const docsOf = async (s: H, patientId: string) => (await get(s, `/patients/${patientId}/documents`)).json();
const fetchFile = async (path: string) => ctx.app.inject({ method: 'GET', url: path });

describe('clinic uploads', () => {
  it('stores multi-page documents encrypted, and serves exact bytes only through a signed link', async () => {
    const { d, pat } = await setup();
    const p1 = jpeg('SECRETMARKER-1');
    const r = await upload(d, `/patients/${pat.id}/documents`, { category: 'lab_result', title: 'CBC', documentDate: '2026-01-15' }, [
      { name: 'p1.jpg', buf: p1 },
      { name: 'p2.png', buf: png('SECRETMARKER-2'), type: 'image/png' },
    ]);
    expect(r.statusCode).toBe(201);
    expect(r.json()).toMatchObject({ source: 'clinician', provenance: 'clinician_authored', category: 'lab_result', title: 'CBC', documentDate: '2026-01-15', published: false, pages: [{ page: 1, mime: 'image/jpeg' }, { page: 2, mime: 'image/png' }] });

    // At rest: the object on disk is ciphertext.
    const keys = (await ctx.pool.query('select storage_key from document_pages order by page')).rows.map((x) => x.storage_key);
    const raw = await store.get(keys[0]);
    expect(raw.includes(Buffer.from('SECRETMARKER'))).toBe(false);
    expect(raw.length).toBeGreaterThan(p1.length);

    const link = (await get(d, `/documents/${r.json().id}/pages/1/link`)).json();
    expect(link.path).toMatch(/^\/files\//);
    const file = await fetchFile(link.path);
    expect(file.statusCode).toBe(200);
    expect(file.rawPayload.equals(p1)).toBe(true);
    expect(file.headers).toMatchObject({ 'content-type': 'image/jpeg', 'x-content-type-options': 'nosniff', 'cache-control': 'private, no-store' });
    expect((await get(d, `/documents/${r.json().id}/pages/9/link`)).statusCode).toBe(404);
  });

  it('judges files by content, not by the name or type the client claims', async () => {
    const { d, pat } = await setup();
    const url = `/patients/${pat.id}/documents`;
    const exe = Buffer.from('MZ\x90\x00\x03\x00\x00\x00 malicious');
    expect((await upload(d, url, { category: 'other' }, [{ name: 'scan.jpg', buf: exe, type: 'image/jpeg' }])).json().error).toBe('unsupported_type');
    expect((await upload(d, url, { category: 'other' }, [{ name: 'a.pdf', buf: pdf() }, { name: 'b.jpg', buf: jpeg() }])).json().error).toBe('invalid_pages');
    expect((await upload(d, url, { category: 'other' }, [])).json().error).toBe('no_files');
    expect((await upload(d, url, { category: 'other' }, [{ name: 'empty.jpg', buf: Buffer.alloc(0) }])).json().error).toBe('no_files');
    expect((await upload(d, url, { category: 'other' }, Array.from({ length: 21 }, (_, i) => ({ name: `${i}.jpg`, buf: jpeg(String(i)) })))).statusCode).toBe(400);
    expect((await upload(d, url, { category: 'selfie' }, [{ name: 'a.jpg', buf: jpeg() }])).statusCode).toBe(400);
    expect((await upload(d, url, { category: 'other', documentDate: '2999-01-01' }, [{ name: 'a.jpg', buf: jpeg() }])).statusCode).toBe(400);
    expect((await upload(d, url, { category: 'other' }, [{ name: 'a.pdf', buf: pdf(), type: 'application/pdf' }])).statusCode).toBe(201);
    expect((await ctx.pool.query('select count(*)::int as n from documents')).rows[0].n).toBe(1);
  });

  it('rejects files that fail the malware scan and stores nothing', async () => {
    const { d, pat } = await setup();
    const infected = Buffer.concat([pdf(), Buffer.from(EICAR_TEST_STRING)]);
    const r = await upload(d, `/patients/${pat.id}/documents`, { category: 'report' }, [{ name: 'x.pdf', buf: infected, type: 'application/pdf' }]);
    expect(r.statusCode).toBe(422);
    expect(r.json().error).toBe('malware_detected');
    expect((await ctx.pool.query('select count(*)::int as n from documents')).rows[0].n).toBe(0);
    expect((await ctx.pool.query('select count(*)::int as n from document_pages')).rows[0].n).toBe(0);
  });

  it('enforces the per-file size limit and the clinic storage quota', async () => {
    const { d, pat } = await setup();
    const big = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(16 * 1024 * 1024)]);
    expect((await upload(d, `/patients/${pat.id}/documents`, { category: 'imaging' }, [{ name: 'big.jpg', buf: big }])).json().error).toBe('file_too_large');

    await ctx.pool.query('update workspaces set storage_quota_bytes = 500');
    expect((await upload(d, `/patients/${pat.id}/documents`, { category: 'imaging' }, [{ name: 'a.jpg', buf: jpeg() }])).statusCode).toBe(201);
    const over = await upload(d, `/patients/${pat.id}/documents`, { category: 'imaging' }, [{ name: 'b.jpg', buf: jpeg('b') }, { name: 'c.jpg', buf: jpeg('c') }]);
    expect(over.statusCode).toBe(413);
    expect(over.json().error).toBe('quota_exceeded');
    const usage = (await get(d, '/workspace/storage')).json();
    expect(usage.quotaBytes).toBe(500);
    expect(usage.usedBytes).toBeGreaterThan(0);
  });

  it('links documents to an encounter of the same patient only', async () => {
    const { d, pat } = await setup();
    const enc = (await post(d, `/patients/${pat.id}/encounters`)).json();
    const other = (await post(d, '/patients', { phone: '+201222222222', fullName: 'Omar Ali' })).json();
    const otherEnc = (await post(d, `/patients/${other.id}/encounters`)).json();
    const ok = await upload(d, `/patients/${pat.id}/documents`, { category: 'lab_result', encounterId: enc.id }, [{ name: 'a.jpg', buf: jpeg() }]);
    expect(ok.json().encounterId).toBe(enc.id);
    await upload(d, `/patients/${pat.id}/documents`, { category: 'other' }, [{ name: 'b.jpg', buf: jpeg('b') }]);
    expect((await upload(d, `/patients/${pat.id}/documents`, { category: 'other', encounterId: otherEnc.id }, [{ name: 'c.jpg', buf: jpeg('c') }])).statusCode).toBe(404);
    expect((await get(d, `/patients/${pat.id}/documents?encounterId=${enc.id}`)).json()).toHaveLength(1);
    expect(await docsOf(d, pat.id)).toHaveLength(2);
  });

  it('blocks uploads for ended relationships', async () => {
    const { d, pat } = await setup();
    await post(d, `/patients/${pat.id}/end`);
    expect((await upload(d, `/patients/${pat.id}/documents`, { category: 'other' }, [{ name: 'a.jpg', buf: jpeg() }])).json().error).toBe('relationship_ended');
  });
});

describe('roles', () => {
  it('front desk uploads and sees administrative documents only; nurses can upload clinical ones', async () => {
    const { d, pat } = await setup();
    const rec = await staffOf(d, '+201000000002', 'receptionist');
    const nurse = await staffOf(d, '+201000000003', 'nurse');
    const url = `/patients/${pat.id}/documents`;
    expect((await upload(rec, url, { category: 'lab_result' }, [{ name: 'a.jpg', buf: jpeg() }])).statusCode).toBe(403);
    const admin = await upload(rec, url, { category: 'administrative', title: 'Insurance card' }, [{ name: 'card.jpg', buf: jpeg('card') }]);
    expect(admin.statusCode).toBe(201);
    expect(admin.json()).toMatchObject({ source: 'staff', uploaderRole: 'receptionist' });
    const lab = await upload(nurse, url, { category: 'lab_result' }, [{ name: 'lab.jpg', buf: jpeg('lab') }]);
    expect(lab.statusCode).toBe(201);
    const rx = await upload(d, url, { category: 'prescription' }, [{ name: 'rx.jpg', buf: jpeg('rx') }]);

    const seenByRec = await docsOf(rec, pat.id);
    expect(seenByRec.map((x: { id: string }) => x.id)).toEqual([admin.json().id]);
    expect((await get(rec, `/documents/${rx.json().id}`)).statusCode).toBe(404);
    expect((await get(rec, `/documents/${rx.json().id}/pages/1/link`)).statusCode).toBe(404);
    expect((await get(rec, `/documents/${admin.json().id}/pages/1/link`)).statusCode).toBe(200);
    expect(await docsOf(d, pat.id)).toHaveLength(3);
  });

  it('only the uploader or the doctor can delete, with a reason; deletion tombstones but keeps the bytes', async () => {
    const { d, pat } = await setup();
    const nurse = await staffOf(d, '+201000000003', 'nurse');
    const doc = (await upload(d, `/patients/${pat.id}/documents`, { category: 'imaging' }, [{ name: 'a.jpg', buf: jpeg('keep') }])).json();
    const link = (await get(d, `/documents/${doc.id}/pages/1/link`)).json();

    expect((await del(nurse, `/documents/${doc.id}`, { reason: 'not mine' })).statusCode).toBe(403);
    expect((await del(d, `/documents/${doc.id}`, {})).statusCode).toBe(400);
    expect((await del(d, `/documents/${doc.id}`, { reason: 'Uploaded to wrong patient' })).statusCode).toBe(200);

    expect(await docsOf(d, pat.id)).toHaveLength(0);
    expect((await get(d, `/documents/${doc.id}`)).statusCode).toBe(404);
    expect((await fetchFile(link.path)).statusCode).toBe(404); // a link issued earlier stops working
    const row = (await ctx.pool.query('select status, delete_reason from documents where id = $1', [doc.id])).rows[0];
    expect(row).toMatchObject({ status: 'deleted', delete_reason: 'Uploaded to wrong patient' });
    const key = (await ctx.pool.query('select storage_key from document_pages where document_id = $1', [doc.id])).rows[0].storage_key;
    await expect(store.get(key)).resolves.toBeTruthy(); // retained
  });
});

describe('signed links (F06-5)', () => {
  it('reject tampered, expired and malformed tokens', async () => {
    const { d, pat } = await setup();
    const doc = (await upload(d, `/patients/${pat.id}/documents`, { category: 'imaging' }, [{ name: 'a.jpg', buf: jpeg() }])).json();
    const link = (await get(d, `/documents/${doc.id}/pages/1/link`)).json();
    expect(Date.parse(link.expiresAt) - Date.now()).toBeLessThanOrEqual(10 * 60_000);
    expect((await fetchFile(link.path.slice(0, -2) + 'xx')).statusCode).toBe(403);
    expect((await fetchFile('/files/garbage')).statusCode).toBe(403);
    expect((await fetchFile('/files/a.b')).statusCode).toBe(403);
    const expired = signLink({ d: doc.id, p: 1, u: d.user.id, w: d.workspaceId }, -5);
    expect((await fetchFile(`/files/${expired.token}`)).statusCode).toBe(403);
    expect((await fetchFile(link.path)).statusCode).toBe(200);
  });

  it('stop working the moment the staff member loses access', async () => {
    const { d, pat } = await setup();
    const nurse = await staffOf(d, '+201000000003', 'nurse');
    const doc = (await upload(d, `/patients/${pat.id}/documents`, { category: 'imaging' }, [{ name: 'a.jpg', buf: jpeg() }])).json();
    const link = (await get(nurse, `/documents/${doc.id}/pages/1/link`)).json();
    expect((await fetchFile(link.path)).statusCode).toBe(200);
    const m = (await get(d, '/workspace/members')).json().find((x: { role: string }) => x.role === 'nurse');
    await del(d, `/workspace/members/${m.id}`);
    expect((await fetchFile(link.path)).statusCode).toBe(403);
  });

  it('log every view in the access table and the audit chain without leaking titles', async () => {
    const { d, pat } = await setup();
    const doc = (await upload(d, `/patients/${pat.id}/documents`, { category: 'imaging', title: 'Confidential MRI', notes: 'Secret notes' }, [{ name: 'brain-scan.jpg', buf: jpeg() }])).json();
    const link = (await get(d, `/documents/${doc.id}/pages/1/link`)).json();
    await fetchFile(link.path);
    await fetchFile(link.path);
    const access = (await ctx.pool.query('select accessor_user_id, workspace_id, page from document_access where document_id = $1', [doc.id])).rows;
    expect(access).toHaveLength(2);
    expect(access[0]).toMatchObject({ accessor_user_id: d.user.id, workspace_id: d.workspaceId, page: 1 });
    await expect(ctx.pool.query('delete from document_access')).rejects.toThrow(/append-only/);

    const log = (await get(d, '/workspace/audit')).json();
    expect(log.filter((l: { action: string }) => l.action === 'document.viewed')).toHaveLength(2);
    const text = JSON.stringify(log);
    for (const secret of ['Confidential', 'Secret notes', 'brain-scan']) expect(text).not.toContain(secret);
    expect((await verifyChain(ctx.pool, d.workspaceId)).valid).toBe(true);
  });
});

describe('isolation between clinics (RULE-003)', () => {
  it('another clinic cannot list, read, link, review, publish or delete these documents', async () => {
    const { d, pat } = await setup();
    const doc = (await upload(d, `/patients/${pat.id}/documents`, { category: 'imaging' }, [{ name: 'a.jpg', buf: jpeg() }])).json();
    const other = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000009');
    expect(await docsOf(other, pat.id)).toEqual([]);
    expect((await get(other, `/documents/${doc.id}`)).statusCode).toBe(404);
    expect((await get(other, `/documents/${doc.id}/pages/1/link`)).statusCode).toBe(404);
    expect((await post(other, `/documents/${doc.id}/publish`)).statusCode).toBe(404);
    expect((await post(other, `/documents/${doc.id}/review`)).statusCode).toBe(404);
    expect((await del(other, `/documents/${doc.id}`, { reason: 'nope nope' })).statusCode).toBe(404);
    expect((await upload(other, `/patients/${pat.id}/documents`, { category: 'other' }, [{ name: 'a.jpg', buf: jpeg() }])).statusCode).toBe(404);
  });
});

describe('patient uploads and sending to a clinic (RULE-009, F06-4)', () => {
  async function patientWithClinic() {
    const { d, pat } = await setup();
    const pt = await login(ctx.app, '+201111111111');
    await post(pt, '/patient/claim');
    return { d, pat, pt };
  }

  it('requires a claimed patient profile', async () => {
    const s = await login(ctx.app, '+201777777777');
    expect((await upload(s, '/patient/documents', { category: 'other' }, [{ name: 'a.jpg', buf: jpeg() }])).statusCode).toBe(403);
    expect((await get(s, '/patient/documents')).statusCode).toBe(403);
  });

  it('uploads stay private to the patient until sent; the clinic sees them labelled unverified', async () => {
    const { d, pat, pt } = await patientWithClinic();
    const up = await upload(pt, '/patient/documents', { category: 'lab_result', title: 'Old blood test' }, [{ name: 'old.jpg', buf: jpeg('old') }]);
    expect(up.statusCode).toBe(201);
    expect(up.json()).toMatchObject({ source: 'patient', provenance: 'patient_submitted_unverified', uploaderRole: 'patient' });
    expect(await docsOf(d, pat.id)).toHaveLength(0);

    const link = (await get(pt, `/patient/documents/${up.json().id}/pages/1/link`)).json();
    expect((await fetchFile(link.path)).rawPayload.equals(jpeg('old'))).toBe(true);
    const stranger = await login(ctx.app, '+201888888888');
    await post(stranger, '/patient/claim');
    expect((await get(stranger, `/patient/documents/${up.json().id}/pages/1/link`)).statusCode).toBe(404);
    expect((await fetchFile(link.path)).statusCode).toBe(200); // the link is bound to its owner, not to whoever holds the session
    expect((await get(stranger, '/patient/documents')).json()).toHaveLength(0);

    expect((await post(pt, `/patient/documents/${up.json().id}/send`, { relationshipId: pat.id })).statusCode).toBe(200);
    const seen = await docsOf(d, pat.id);
    expect(seen).toHaveLength(1);
    expect(seen[0]).toMatchObject({ provenance: 'patient_submitted_unverified', reviewed: false });
    expect((await get(pt, '/patient/documents')).json()[0].sharedWith).toMatchObject([{ relationshipId: pat.id, clinicName: 'Test Clinic' }]);
    const cl = (await get(d, `/documents/${up.json().id}/pages/1/link`)).json();
    expect((await fetchFile(cl.path)).statusCode).toBe(200);
    expect((await ctx.pool.query('select count(*)::int as n from document_access where workspace_id is not null')).rows[0].n).toBe(1);
  });

  it('the doctor can mark a patient document reviewed without altering it; nurses and repeats are refused', async () => {
    const { d, pat, pt } = await patientWithClinic();
    const nurse = await staffOf(d, '+201000000003', 'nurse');
    const up = (await upload(pt, '/patient/documents', { category: 'report', title: 'Discharge summary' }, [{ name: 'a.pdf', buf: pdf(), type: 'application/pdf' }])).json();
    await post(pt, `/patient/documents/${up.id}/send`, { relationshipId: pat.id });

    expect((await post(nurse, `/documents/${up.id}/review`, { note: 'ok' })).statusCode).toBe(403);
    expect((await post(d, `/documents/${up.id}/review`, { note: 'Matches records' })).statusCode).toBe(200);
    expect((await post(d, `/documents/${up.id}/review`)).json().error).toBe('already_reviewed');
    const after = (await get(d, `/documents/${up.id}`)).json();
    expect(after).toMatchObject({ reviewed: true, review: { note: 'Matches records' }, source: 'patient', provenance: 'patient_submitted_unverified', title: 'Discharge summary' });
    const own = (await upload(d, `/patients/${pat.id}/documents`, { category: 'other' }, [{ name: 'a.jpg', buf: jpeg() }])).json();
    expect((await post(d, `/documents/${own.id}/review`)).json().error).toBe('invalid_state');
  });

  it('revoking stops the clinic immediately, including links already issued', async () => {
    const { d, pat, pt } = await patientWithClinic();
    const up = (await upload(pt, '/patient/documents', { category: 'imaging' }, [{ name: 'a.jpg', buf: jpeg() }])).json();
    await post(pt, `/patient/documents/${up.id}/send`, { relationshipId: pat.id });
    const cl = (await get(d, `/documents/${up.id}/pages/1/link`)).json();
    expect((await fetchFile(cl.path)).statusCode).toBe(200);
    expect((await del(pt, `/patient/documents/${up.id}/send/${pat.id}`)).statusCode).toBe(200);
    expect(await docsOf(d, pat.id)).toHaveLength(0);
    expect((await get(d, `/documents/${up.id}`)).statusCode).toBe(404);
    expect((await fetchFile(cl.path)).statusCode).toBe(403);
    expect((await del(pt, `/patient/documents/${up.id}/send/${pat.id}`)).statusCode).toBe(404);
    expect((await post(pt, `/patient/documents/${up.id}/send`, { relationshipId: pat.id })).statusCode).toBe(200); // can be re-sent
    expect(await docsOf(d, pat.id)).toHaveLength(1);
  });

  it('can only be sent to a clinic the patient is actively connected to; ending the connection hides it', async () => {
    const { d, pat, pt } = await patientWithClinic();
    const up = (await upload(pt, '/patient/documents', { category: 'imaging' }, [{ name: 'a.jpg', buf: jpeg() }])).json();
    const d2 = await makeVerifiedDoctor(ctx.app, ctx.pool, '+201000000009');
    const theirs = (await post(d2, '/patients', { phone: '+201333333333', fullName: 'Someone Else' })).json();
    expect((await post(pt, `/patient/documents/${up.id}/send`, { relationshipId: theirs.id })).statusCode).toBe(404);
    await post(pt, `/patient/documents/${up.id}/send`, { relationshipId: pat.id });
    await post(d, `/patients/${pat.id}/end`);
    const rel = (await post(pt, `/patient/documents/${up.id}/send`, { relationshipId: pat.id })).json();
    expect(rel.error).toBe('invalid_state');
    const d3 = (await ctx.app.inject({ method: 'GET', url: `/documents/${up.id}`, headers: d.headers })).statusCode;
    expect(d3).toBe(404);
  });

  it('deleting is erasure unless a clinic has been given the document', async () => {
    const { d, pat, pt } = await patientWithClinic();
    const a = (await upload(pt, '/patient/documents', { category: 'other' }, [{ name: 'a.jpg', buf: jpeg('a') }])).json();
    const b = (await upload(pt, '/patient/documents', { category: 'other' }, [{ name: 'b.jpg', buf: jpeg('b') }])).json();
    const keyA = (await ctx.pool.query('select storage_key from document_pages where document_id = $1', [a.id])).rows[0].storage_key;
    await post(pt, `/patient/documents/${b.id}/send`, { relationshipId: pat.id });

    expect((await del(pt, `/patient/documents/${a.id}`)).statusCode).toBe(200);
    await expect(store.get(keyA)).rejects.toThrow(); // bytes gone
    expect((await get(pt, '/patient/documents')).json().map((x: { id: string }) => x.id)).toEqual([b.id]);

    const refuse = await del(pt, `/patient/documents/${b.id}`);
    expect(refuse.statusCode).toBe(409);
    expect(refuse.json().error).toBe('already_shared');
    await del(pt, `/patient/documents/${b.id}/send/${pat.id}`);
    expect((await del(pt, `/patient/documents/${b.id}`)).statusCode).toBe(409); // still refused: the clinic already received it once
    expect(d).toBeTruthy();
  });

  it("rejects administrative as a patient category and non-image content", async () => {
    const { pt } = await patientWithClinic();
    expect((await upload(pt, '/patient/documents', { category: 'administrative' }, [{ name: 'a.jpg', buf: jpeg() }])).statusCode).toBe(400);
    expect((await upload(pt, '/patient/documents', { category: 'other' }, [{ name: 'bad.jpg', buf: Buffer.from('not an image') }])).json().error).toBe('unsupported_type');
  });
});

describe('publishing clinic documents to the patient', () => {
  it('shows a clinic document to the patient only after the doctor publishes it', async () => {
    const { d, pat } = await setup();
    const pt = await login(ctx.app, '+201111111111');
    await post(pt, '/patient/claim');
    const doc = (await upload(d, `/patients/${pat.id}/documents`, { category: 'lab_result', title: 'CBC' }, [{ name: 'a.jpg', buf: jpeg('lab') }])).json();
    expect((await get(pt, '/patient/documents')).json()).toHaveLength(0);
    expect((await get(pt, `/patient/documents/${doc.id}/pages/1/link`)).statusCode).toBe(404);

    expect((await post(d, `/documents/${doc.id}/publish`)).statusCode).toBe(200);
    const list = (await get(pt, '/patient/documents')).json();
    expect(list).toHaveLength(1);
    expect(list[0]).toMatchObject({ provenance: 'clinician_authored', title: 'CBC' });
    const link = (await get(pt, `/patient/documents/${doc.id}/pages/1/link`)).json();
    expect((await fetchFile(link.path)).statusCode).toBe(200);
    expect((await del(pt, `/patient/documents/${doc.id}`)).statusCode).toBe(404); // patients cannot erase clinic records

    expect((await post(d, `/documents/${doc.id}/unpublish`)).statusCode).toBe(200);
    expect((await get(pt, '/patient/documents')).json()).toHaveLength(0);
    expect((await fetchFile(link.path)).statusCode).toBe(403);
  });

  it('administrative documents are never published', async () => {
    const { d, pat } = await setup();
    const doc = (await upload(d, `/patients/${pat.id}/documents`, { category: 'administrative' }, [{ name: 'a.jpg', buf: jpeg() }])).json();
    expect((await post(d, `/documents/${doc.id}/publish`)).json().error).toBe('invalid_state');
  });
});
