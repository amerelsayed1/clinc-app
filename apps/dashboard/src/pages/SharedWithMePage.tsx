import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, type AccessRequestRow, type ShareScope, type SharedDocument, type SharedEncounter, type SharedGrant, type SharedItem } from '../api';
import { fmtDateTime } from '../time';
import { useSettings } from './AppointmentsPage';

const CATEGORY: Record<string, string> = { encounters: 'Consultations', prescription: 'Prescriptions', lab_result: 'Lab results', imaging: 'Imaging', report: 'Reports', other: 'Other documents' };
const ALL_CATEGORIES = Object.keys(CATEGORY);
const SENSITIVE_MAX = 14;

export const scopeText = (s: ShareScope) =>
  s.items ? `${s.items.length} selected ${s.items.length === 1 ? 'record' : 'records'}` : `${(s.categories ?? []).map((c) => CATEGORY[c] ?? c).join(', ')}${s.from || s.to ? ` (${s.from ?? 'any'} to ${s.to ?? 'any'})` : ''}`;

/** Shown wherever patient-shared data appears: it is a time-limited copy view, not the clinic's own record. */
export function SharedBanner({ expiresAt, patientName }: { expiresAt: string; patientName?: string }) {
  const tz = useSettings().data?.timezone ?? 'Africa/Cairo';
  return (
    <div className="banner shared-banner">
      Shared by patient{patientName ? ` ${patientName}` : ''} — provenance: not authored by your clinic. Access expires {fmtDateTime(expiresAt, tz)} and every view is logged for the patient.
    </div>
  );
}

export function ProvenanceBadge({ p }: { p: string }) {
  return p === 'patient_submitted_unverified' ? <span className="pill invited">Patient-submitted · unverified</span> : <span className="pill completed">Clinician-authored</span>;
}

const STATUS: Record<string, string> = { pending: 'Waiting for patient', approved: 'Approved', denied: 'Denied', cancelled: 'Cancelled', expired: 'Expired' };

/** Patient detail: ask for records held elsewhere, and track this clinic's requests (F08-3). */
export function AccessRequestsSection({ patientId, patientName, canRequest, hasAccount }: { patientId: string; patientName: string; canRequest: boolean; hasAccount: boolean }) {
  const qc = useQueryClient();
  const tz = useSettings().data?.timezone ?? 'Africa/Cairo';
  const list = useQuery({ queryKey: ['access-requests'], queryFn: () => api<AccessRequestRow[]>('/access-requests') });
  const [open, setOpen] = useState(false);
  const cancel = useMutation({ mutationFn: (id: string) => api(`/access-requests/${id}`, { method: 'DELETE' }), onSuccess: () => qc.invalidateQueries({ queryKey: ['access-requests'] }) });
  const mine = list.data ?? [];
  if (!canRequest && !mine.length) return null;
  return (
    <>
      <div className="row" style={{ marginTop: '1.25rem' }}>
        <h3 style={{ margin: 0 }}>Records held elsewhere &amp; this clinic's access requests</h3>
        <span className="spacer" />
        {canRequest && <button onClick={() => setOpen((o) => !o)}>{open ? 'Close' : 'Request access to records held elsewhere'}</button>}
      </div>
      <p className="muted">
        Ask {patientName} to share records from other clinics. The patient must be registered in the CareLink app and connected to your clinic, and they decide what to share and for how long.
        {!hasAccount && ' This patient has not signed up to the app yet, so a request cannot be delivered.'}
      </p>
      {open && <RequestForm patientId={patientId} disabled={!hasAccount} onDone={() => (setOpen(false), qc.invalidateQueries({ queryKey: ['access-requests'] }))} />}
      {cancel.error && <p className="error">{(cancel.error as Error).message}</p>}
      {mine.length > 0 && (
        <table>
          <tbody>
            {mine.map((r) => (
              <tr key={r.id}>
                <td>
                  <strong>{scopeText(r.scope)}</strong> {r.sensitive && <span className="pill invited">sensitive</span>}
                  <div className="muted">{r.purpose} · {r.requestedDays} days · sent {fmtDateTime(r.createdAt, tz)} by {r.doctorName}</div>
                </td>
                <td><span className={`pill ${r.status === 'approved' ? 'in_consultation' : r.status === 'pending' ? 'invited' : 'ended'}`}>{STATUS[r.status]}</span></td>
                <td style={{ textAlign: 'right' }}>{r.status === 'pending' && canRequest && <button onClick={() => cancel.mutate(r.id)}>Cancel</button>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}

function RequestForm({ patientId, disabled, onDone }: { patientId: string; disabled: boolean; onDone: () => void }) {
  const [cats, setCats] = useState<string[]>(['lab_result', 'imaging', 'report']);
  const [f, setF] = useState({ purpose: '', days: 30, from: '', to: '' });
  const sensitive = cats.includes('encounters');
  const maxDays = sensitive ? SENSITIVE_MAX : 90;
  const m = useMutation({
    mutationFn: () =>
      api(`/patients/${patientId}/access-requests`, {
        method: 'POST',
        body: { scope: { categories: cats, ...(f.from && { from: f.from }), ...(f.to && { to: f.to }) }, purpose: f.purpose, days: Math.min(f.days, maxDays) },
      }),
    onSuccess: onDone,
  });
  const toggle = (c: string) => setCats((cur) => (cur.includes(c) ? cur.filter((x) => x !== c) : [...cur, c]));
  return (
    <form className="card" onSubmit={(e) => (e.preventDefault(), m.mutate())}>
      <div className="perms">
        {ALL_CATEGORIES.map((c) => <label key={c} className="check"><input type="checkbox" checked={cats.includes(c)} onChange={() => toggle(c)} />{CATEGORY[c]}</label>)}
      </div>
      {sensitive && <p className="muted">Consultation records are sensitive: they can be requested for at most {SENSITIVE_MAX} days and the patient confirms separately.</p>}
      <div className="grid" style={{ marginTop: '.75rem' }}>
        <label>Purpose<input value={f.purpose} minLength={3} maxLength={300} required onChange={(e) => setF({ ...f, purpose: e.target.value })} placeholder="e.g. Review prior cardiology work-up" /></label>
        <label>Days of access (max {maxDays})<input type="number" min={1} max={maxDays} value={Math.min(f.days, maxDays)} onChange={(e) => setF({ ...f, days: Number(e.target.value) })} /></label>
        <label>From (optional)<input type="date" value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} /></label>
        <label>To (optional)<input type="date" value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} /></label>
      </div>
      <button disabled={m.isPending || disabled || cats.length === 0}>{m.isPending ? 'Sending…' : 'Send request'}</button>
      {m.error && <p className="error">{(m.error as Error).message}</p>}
    </form>
  );
}

/** Nav entry "Shared with me": active grants other patients gave this clinic. */
export function SharedWithMePage() {
  const tz = useSettings().data?.timezone ?? 'Africa/Cairo';
  const q = useQuery({ queryKey: ['shared-with-me'], queryFn: () => api<SharedGrant[]>('/shared-with-me') });
  return (
    <section>
      <h2>Shared with me</h2>
      <p className="muted">Records patients have chosen to share with you for a limited time. These are the patient's copies, not part of your clinic's chart, and access ends automatically.</p>
      {q.isLoading && <p>Loading…</p>}
      {q.error && <p className="error">{(q.error as Error).message}</p>}
      <table>
        <tbody>
          {q.data?.map((g) => (
            <tr key={g.id}>
              <td>
                <strong><Link to={`/shared/${g.id}`}>{g.patientName}</Link></strong>
                <div className="muted">{scopeText(g.scope)}{g.purpose && <> · {g.purpose}</>}</div>
              </td>
              <td><span className="pill invited">Shared · expires {fmtDateTime(g.expiresAt, tz)}</span></td>
            </tr>
          ))}
          {q.data?.length === 0 && <tr><td className="muted">Nothing is currently shared with you. You can request access from a connected patient's page.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}

function useGrant(id: string) {
  const list = useQuery({ queryKey: ['shared-with-me'], queryFn: () => api<SharedGrant[]>('/shared-with-me') });
  return { grant: list.data?.find((g) => g.id === id), loading: list.isLoading };
}

export function SharedGrantPage() {
  const { id = '' } = useParams();
  const tz = useSettings().data?.timezone ?? 'Africa/Cairo';
  const { grant, loading } = useGrant(id);
  const items = useQuery({ queryKey: ['shared-items', id], queryFn: () => api<SharedItem[]>(`/shared-with-me/${id}/items`), retry: false });
  if (loading || items.isLoading) return <p>Loading…</p>;
  if (!grant || items.error) return <section><Link to="/shared">← Shared with me</Link><p className="error">This share is no longer available. It may have expired or been revoked by the patient.</p></section>;
  return (
    <section>
      <Link to="/shared">← Shared with me</Link>
      <h2>{grant.patientName}</h2>
      <SharedBanner expiresAt={grant.expiresAt} />
      <p className="muted">{scopeText(grant.scope)}{grant.purpose && <> · {grant.purpose}</>} · shared {fmtDateTime(grant.createdAt, tz)}</p>
      <table>
        <tbody>
          {items.data?.map((i) => (
            <tr key={`${i.type}${i.id}`}>
              <td>
                <strong><Link to={`/shared/${id}/${i.type === 'encounter' ? 'encounters' : 'documents'}/${i.id}`}>{i.title}</Link></strong>{' '}
                <span className="pill">{i.type === 'encounter' ? 'Consultation' : CATEGORY[i.category] ?? i.category}</span>{' '}
                <ProvenanceBadge p={i.provenance} />
                <div className="muted">{i.date}{i.clinicName && <> · {i.clinicName}</>}</div>
              </td>
            </tr>
          ))}
          {items.data?.length === 0 && <tr><td className="muted">No records match this share yet.</td></tr>}
        </tbody>
      </table>
    </section>
  );
}

export function SharedEncounterPage() {
  const { id = '', encId = '' } = useParams();
  const { grant } = useGrant(id);
  const q = useQuery({ queryKey: ['shared-enc', id, encId], queryFn: () => api<SharedEncounter>(`/shared-with-me/${id}/encounters/${encId}`), retry: false });
  const back = <Link to={`/shared/${id}`}>← Shared records</Link>;
  if (q.isLoading) return <p>Loading…</p>;
  if (q.error || !q.data) return <section>{back}<p className="error">{(q.error as Error)?.message ?? 'Not available'}</p></section>;
  const e = q.data;
  return (
    <section>
      {back}
      <div className="row"><h2>Consultation, {new Date(e.encounterDate).toLocaleDateString()}</h2><ProvenanceBadge p={e.provenance} /></div>
      {grant && <SharedBanner expiresAt={grant.expiresAt} patientName={grant.patientName} />}
      <p className="muted">Authored by {e.doctorName} at {e.clinicName} (version {e.version}). Only the published summary is shared; private notes and history are never included.</p>
      <dl>
        <dt>Chief complaint</dt><dd>{e.chiefComplaint || '—'}</dd>
        <dt>Diagnosis</dt><dd>{e.diagnosis || '—'}</dd>
        <dt>Plan</dt><dd>{e.plan || '—'}</dd>
        <dt>Prescriptions</dt>
        <dd>{e.prescriptions.length ? <ul>{e.prescriptions.map((r, i) => <li key={i}>{r.medication} {r.dose} · {r.frequency} · {r.duration}{r.notes && <> · {r.notes}</>}</li>)}</ul> : '—'}</dd>
      </dl>
      {e.vitals.length > 0 && <div className="vitals">{e.vitals.map((v, i) => <span className="vital" key={i}>{v.kind.replace('_', ' ')}: {v.value}</span>)}</div>}
    </section>
  );
}

export function SharedDocumentPage() {
  const { id = '', docId = '' } = useParams();
  const { grant } = useGrant(id);
  const [error, setError] = useState<string>();
  const q = useQuery({ queryKey: ['shared-doc', id, docId], queryFn: () => api<SharedDocument>(`/shared-with-me/${id}/documents/${docId}`), retry: false });
  const links = useQuery({
    queryKey: ['shared-doc-links', id, docId, q.data?.pages.length],
    enabled: !!q.data,
    queryFn: async () => Promise.all(q.data!.pages.map(async (p) => ({ ...p, path: (await api<{ path: string }>(`/shared-with-me/${id}/documents/${docId}/pages/${p.page}/link`)).path }))),
    staleTime: 60_000,
  });
  const navigate = useNavigate();
  const back = <a href={`/shared/${id}`} onClick={(e) => (e.preventDefault(), navigate(`/shared/${id}`))}>← Shared records</a>;
  if (q.isLoading) return <p>Loading…</p>;
  if (q.error || !q.data) return <section>{back}<p className="error">{(q.error as Error)?.message ?? 'Not available'}</p></section>;
  const d = q.data;
  return (
    <section>
      {back}
      <div className="row"><h2>{d.title || 'Untitled document'}</h2><span className="pill">{CATEGORY[d.category] ?? d.category}</span><ProvenanceBadge p={d.provenance} /></div>
      {grant && <SharedBanner expiresAt={grant.expiresAt} patientName={grant.patientName} />}
      <p className="muted">{d.documentDate ?? d.createdAt.slice(0, 10)}{d.notes && <> · {d.notes}</>}</p>
      {(error || links.error) && <p className="error">{error ?? (links.error as Error).message}</p>}
      {links.data?.map((p) =>
        p.mime.startsWith('image/') ? (
          <img key={p.page} className="shared-page" src={`/api${p.path}`} alt={`${d.title} page ${p.page}`} onError={() => setError('Could not load a page image. The link may have expired; reload the page.')} />
        ) : (
          <p key={p.page}><a href={`/api${p.path}`} target="_blank" rel="noreferrer">Open page {p.page} ({p.mime})</a></p>
        ),
      )}
    </section>
  );
}
