import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect, useRef, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { VITAL_KEYS, VITAL_KINDS, type VitalKind } from '@clinic/shared';
import { ApiError, api, type EncContent, type Encounter } from '../api';
import { fmtDateTime } from '../time';
import { DocumentsSection } from './DocumentsSection';
import { useSettings } from './AppointmentsPage';

const emptyRx = { medication: '', dose: '', frequency: '', duration: '', notes: '' };
const FIELD_LABEL: Record<string, string> = { chiefComplaint: 'Chief complaint', history: 'History', diagnosis: 'Diagnosis', plan: 'Plan', privateNotes: 'Private notes', prescriptions: 'Prescription' };

export function EncounterPage({ can }: { can: (p: string) => boolean }) {
  const { id } = useParams();
  const qc = useQueryClient();
  const tz = useSettings().data?.timezone ?? 'Africa/Cairo';
  const me = useQuery({ queryKey: ['me'], queryFn: () => api<{ id: string; memberships: { role: string }[] }>('/me') });
  const q = useQuery({ queryKey: ['encounter', id], queryFn: () => api<Encounter>(`/encounters/${id}`), staleTime: 0, gcTime: 0 });
  const [nonce, setNonce] = useState(0);
  const reload = () => {
    qc.invalidateQueries({ queryKey: ['encounter', id] });
    qc.invalidateQueries({ queryKey: ['encounters'] });
  };

  if (q.isLoading || !me.data) return <p>Loading…</p>;
  if (q.error || !q.data) return <p className="error">{(q.error as Error)?.message ?? 'Not found'}</p>;
  const e = q.data;
  const role = me.data.memberships[0]?.role;
  const isAuthor = e.author.id === me.data.id && can('clinical.write');

  return (
    <section className="encounter">
      <Link to={`/patients/${e.patient.id}`} className="no-print">← {e.patient.fullName}</Link>
      <div className="row">
        <h2>Encounter · {fmtDateTime(e.encounterDate, tz)}</h2>
        <span className={`pill ${e.status === 'signed' ? 'completed' : 'invited'}`}>{e.status === 'signed' ? `Signed · v${e.currentVersion}` : 'Draft'}</span>
        {e.publishedVersion && <span className="pill">Published v{e.publishedVersion}</span>}
        <span className="muted">by {e.author.fullName}</span>
      </div>

      <Vitals e={e} can={can} role={role} meId={me.data.id} onChange={reload} />

      {e.status === 'draft' ? (
        isAuthor ? (
          <DraftEditor key={`${e.id}-${nonce}`} e={e} showPrivate={role === 'doctor'} onSigned={reload} onReload={async () => {
              // Remount only after the fresh revision has arrived, otherwise the editor restarts from stale data.
              await qc.refetchQueries({ queryKey: ['encounter', id] });
              setNonce((n) => n + 1);
            }} />
        ) : (
          <ReadOnly content={e.content} />
        )
      ) : (
        <Signed e={e} isAuthor={isAuthor} canPublish={can('clinical.write')} tz={tz} onChange={reload} showPrivate={role === 'doctor'} />
      )}

      <div className="no-print"><DocumentsSection patientId={e.patient.id} encounterId={e.id} can={can} /></div>
    </section>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <label>{label}{children}</label>;
}

function ContentFields({ value, onChange, showPrivate, readOnly }: { value: EncContent; onChange: (v: EncContent) => void; showPrivate: boolean; readOnly?: boolean }) {
  const set = <K extends keyof EncContent>(k: K, v: EncContent[K]) => onChange({ ...value, [k]: v });
  const area = (k: 'chiefComplaint' | 'history' | 'diagnosis' | 'plan' | 'privateNotes', rows = 3) => (
    <textarea rows={rows} value={value[k] ?? ''} readOnly={readOnly} onChange={(e) => set(k, e.target.value)} />
  );
  const rx = value.prescriptions;
  const setRx = (i: number, k: keyof (typeof rx)[number], v: string) => set('prescriptions', rx.map((r, j) => (j === i ? { ...r, [k]: v } : r)));
  return (
    <>
      <Field label="Chief complaint">{area('chiefComplaint', 2)}</Field>
      <Field label="History">{area('history')}</Field>
      <Field label="Diagnosis">{area('diagnosis', 2)}</Field>
      <Field label="Plan">{area('plan')}</Field>
      {showPrivate && <Field label="Private notes (only you can see these; never shared or shown to patients)">{area('privateNotes', 2)}</Field>}
      <h3>Prescription</h3>
      {rx.map((r, i) => (
        <div className="rx" key={i}>
          <input placeholder="Medication" value={r.medication} readOnly={readOnly} onChange={(e) => setRx(i, 'medication', e.target.value)} />
          <input placeholder="Dose" value={r.dose} readOnly={readOnly} onChange={(e) => setRx(i, 'dose', e.target.value)} />
          <input placeholder="Frequency" value={r.frequency} readOnly={readOnly} onChange={(e) => setRx(i, 'frequency', e.target.value)} />
          <input placeholder="Duration" value={r.duration} readOnly={readOnly} onChange={(e) => setRx(i, 'duration', e.target.value)} />
          <input placeholder="Notes" value={r.notes} readOnly={readOnly} onChange={(e) => setRx(i, 'notes', e.target.value)} />
          {!readOnly && <button type="button" className="danger" onClick={() => set('prescriptions', rx.filter((_, j) => j !== i))}>×</button>}
        </div>
      ))}
      {!readOnly && <button type="button" onClick={() => set('prescriptions', [...rx, { ...emptyRx }])}>Add medication</button>}
    </>
  );
}

function ReadOnly({ content }: { content: EncContent }) {
  return <div className="card"><ContentFields value={content} onChange={() => undefined} showPrivate={content.privateNotes !== undefined} readOnly /></div>;
}

type SaveState = 'saved' | 'dirty' | 'saving' | 'conflict' | 'error';

function DraftEditor({ e, showPrivate, onSigned, onReload }: { e: Encounter; showPrivate: boolean; onSigned: () => void; onReload: () => Promise<void> | void }) {
  const [form, setForm] = useState<EncContent>({ ...e.content, privateNotes: e.content.privateNotes ?? '' });
  const [state, setState] = useState<SaveState>('saved');
  const [signError, setSignError] = useState<string>();
  const formRef = useRef(form);
  const revision = useRef(e.revision);
  const dirty = useRef(false);
  const inFlight = useRef(false);
  const timer = useRef<number>();
  formRef.current = form;

  const save = async (): Promise<boolean> => {
    if (inFlight.current) return false;
    if (!dirty.current) return true;
    inFlight.current = true;
    dirty.current = false;
    setState('saving');
    const { privateNotes, ...rest } = formRef.current;
    try {
      const r = await api<Encounter>(`/encounters/${e.id}`, { method: 'PATCH', body: { revision: revision.current, ...rest, ...(showPrivate && { privateNotes }) } });
      revision.current = r.revision;
      setState(dirty.current ? 'dirty' : 'saved');
      return true;
    } catch (err) {
      dirty.current = true;
      setState(err instanceof ApiError && err.code === 'revision_conflict' ? 'conflict' : 'error');
      return false;
    } finally {
      inFlight.current = false;
    }
  };

  const schedule = () => {
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(async () => {
      if (inFlight.current) return schedule();
      await save();
      if (dirty.current && !inFlightConflict()) schedule();
    }, 1200);
  };
  const inFlightConflict = () => stateRef.current === 'conflict' || stateRef.current === 'error';
  const stateRef = useRef(state);
  stateRef.current = state;

  const change = (v: EncContent) => {
    setForm(v);
    dirty.current = true;
    setState('dirty');
    schedule();
  };

  useEffect(() => {
    const warn = (ev: BeforeUnloadEvent) => {
      if (dirty.current) ev.preventDefault();
    };
    window.addEventListener('beforeunload', warn);
    return () => {
      window.removeEventListener('beforeunload', warn);
      window.clearTimeout(timer.current);
    };
  }, []);

  const sign = useMutation({
    mutationFn: async () => {
      window.clearTimeout(timer.current);
      while (inFlight.current) await new Promise((r) => setTimeout(r, 50));
      if (!(await save())) throw new Error('Could not save your latest changes');
      return api(`/encounters/${e.id}/sign`, { method: 'POST', body: { revision: revision.current } });
    },
    onSuccess: onSigned,
    onError: (err) => setSignError((err as Error).message),
  });
  const discard = useMutation({ mutationFn: () => api(`/encounters/${e.id}`, { method: 'DELETE' }) });
  const navigate = useNavigate();

  const label = { saved: 'All changes saved', dirty: 'Unsaved changes…', saving: 'Saving…', conflict: 'Conflict', error: 'Could not save' }[state];

  return (
    <div className="card">
      {state === 'conflict' && (
        <div className="banner error">This draft was changed in another window or tab. Your latest edits were not saved. <button type="button" className="link" style={{ display: 'inline' }} onClick={onReload}>Reload the latest version</button></div>
      )}
      <ContentFields value={form} onChange={change} showPrivate={showPrivate} />
      <div className="row" style={{ marginTop: '1rem' }}>
        <span className={`muted save-${state}`}>{label}</span>
        <span className="spacer" />
        <button type="button" className="danger" onClick={async () => confirm('Discard this draft?') && (await discard.mutateAsync(), navigate(`/patients/${e.patient.id}`))}>Discard</button>
        <button type="button" disabled={sign.isPending || state === 'conflict'} onClick={() => confirm('Sign this encounter? After signing it can only be changed by a recorded amendment.') && sign.mutate()}>Sign encounter</button>
      </div>
      {signError && <p className="error">{signError}</p>}
    </div>
  );
}

function Signed({ e, isAuthor, canPublish, tz, onChange, showPrivate }: { e: Encounter; isAuthor: boolean; canPublish: boolean; tz: string; onChange: () => void; showPrivate: boolean }) {
  const [amending, setAmending] = useState(false);
  const versions = useQuery({ queryKey: ['versions', e.id, e.currentVersion], queryFn: () => api<(Encounter['version'] & { content: EncContent })[]>(`/encounters/${e.id}/versions`) });
  const [viewing, setViewing] = useState<number>();
  const shown = versions.data?.find((v) => v.version === (viewing ?? e.currentVersion));
  const publish = useMutation({ mutationFn: () => api(`/encounters/${e.id}/publish`, { method: 'POST', body: {} }), onSuccess: onChange });
  const unpublish = useMutation({ mutationFn: () => api(`/encounters/${e.id}/unpublish`, { method: 'POST' }), onSuccess: onChange });
  const hasRx = e.content.prescriptions.length > 0;

  return (
    <>
      <div className="row no-print">
        {versions.data && versions.data.length > 1 && (
          <label className="check">Version
            <select value={viewing ?? e.currentVersion} onChange={(ev) => setViewing(Number(ev.target.value))} style={{ width: 'auto', marginLeft: 6 }}>
              {versions.data.map((v) => <option key={v.version} value={v.version}>v{v.version}{v.version === e.currentVersion ? ' (current)' : ''} · {fmtDateTime(v.createdAt, tz)}</option>)}
            </select>
          </label>
        )}
        <span className="spacer" />
        {hasRx && <Link to={`/encounters/${e.id}/prescription`}><button type="button">Print prescription</button></Link>}
        {canPublish && (e.publishedVersion === e.currentVersion ? (
          <button type="button" onClick={() => unpublish.mutate()}>Unpublish from patient</button>
        ) : (
          <button type="button" onClick={() => publish.mutate()}>{e.publishedVersion ? 'Publish latest version to patient' : 'Publish to patient'}</button>
        ))}
        {isAuthor && !amending && <button type="button" onClick={() => setAmending(true)}>Amend</button>}
      </div>
      {(publish.error || unpublish.error) && <p className="error">{((publish.error || unpublish.error) as Error).message}</p>}
      {shown && shown.version > 1 && (
        <div className="banner">v{shown.version} amended by {shown.authorName}: “{shown.amendmentReason}” — changed {shown.changedFields.map((f) => FIELD_LABEL[f] ?? f).join(', ')}.</div>
      )}
      {amending ? (
        <AmendForm e={e} showPrivate={showPrivate} onDone={() => (setAmending(false), setViewing(undefined), onChange())} onCancel={() => setAmending(false)} />
      ) : (
        shown && <div className="card"><ContentFields value={shown.content} onChange={() => undefined} showPrivate={showPrivate} readOnly /></div>
      )}
    </>
  );
}

function AmendForm({ e, showPrivate, onDone, onCancel }: { e: Encounter; showPrivate: boolean; onDone: () => void; onCancel: () => void }) {
  const [form, setForm] = useState<EncContent>({ ...e.content, privateNotes: e.content.privateNotes ?? '' });
  const [reason, setReason] = useState('');
  const m = useMutation({
    mutationFn: () => {
      // Only send fields that differ, so the recorded change list is accurate.
      const changes: Partial<EncContent> = {};
      (Object.keys(form) as (keyof EncContent)[]).forEach((k) => {
        if (k === 'privateNotes' && !showPrivate) return;
        if (JSON.stringify(form[k]) !== JSON.stringify(e.content[k] ?? (k === 'privateNotes' ? '' : undefined))) (changes as Record<string, unknown>)[k] = form[k];
      });
      return api(`/encounters/${e.id}/amend`, { method: 'POST', body: { baseVersion: e.currentVersion, reason, changes } });
    },
    onSuccess: onDone,
  });
  return (
    <form className="card" onSubmit={(ev) => (ev.preventDefault(), m.mutate())}>
      <div className="banner">Amending creates version {e.currentVersion + 1}. The original stays on record and visible in the version history.</div>
      <ContentFields value={form} onChange={setForm} showPrivate={showPrivate} />
      <Field label="Reason for amendment (required)"><input value={reason} onChange={(ev) => setReason(ev.target.value)} required minLength={3} maxLength={500} /></Field>
      <div className="row">
        <button disabled={m.isPending}>Save amendment</button>
        <button type="button" className="link" onClick={onCancel}>Cancel</button>
      </div>
      {m.error && <p className="error">{(m.error as Error).message}</p>}
    </form>
  );
}

function Vitals({ e, can, role, meId, onChange }: { e: Encounter; can: (p: string) => boolean; role?: string; meId: string; onChange: () => void }) {
  const [kind, setKind] = useState<VitalKind>('weight_kg');
  const [value, setValue] = useState('');
  const editable = e.status === 'draft' && can('vitals.write');
  const add = useMutation({ mutationFn: () => api(`/encounters/${e.id}/observations`, { method: 'POST', body: { kind, value: Number(value) } }), onSuccess: () => (setValue(''), onChange()) });
  const voidObs = useMutation({
    mutationFn: ({ id, reason }: { id: string; reason: string }) => api(`/encounters/${e.id}/observations/${id}/void`, { method: 'POST', body: { reason } }),
    onSuccess: onChange,
  });
  const active = e.observations.filter((o) => !o.voided);
  const voided = e.observations.filter((o) => o.voided);

  return (
    <div className="card no-print-border">
      <h3 style={{ marginTop: 0 }}>Vitals</h3>
      <div className="vitals">
        {active.map((o) => (
          <span className="vital" key={o.id} title={`Recorded by ${o.recordedByName ?? 'unknown'} (${o.recordedRole})`}>
            <strong>{VITAL_KINDS[o.kind as VitalKind]?.label ?? o.kind}</strong> {o.value} {o.unit}
            <small className="muted"> · {o.recordedRole}</small>
            {editable && (o.recordedBy === meId || role === 'doctor') && (
              <button type="button" className="link" style={{ display: 'inline', marginLeft: 6 }} onClick={() => { const reason = prompt('Why is this entry wrong?'); if (reason && reason.trim().length >= 3) voidObs.mutate({ id: o.id, reason: reason.trim() }); }}>void</button>
            )}
          </span>
        ))}
        {active.length === 0 && <span className="muted">No vitals recorded.</span>}
      </div>
      {voided.length > 0 && <p className="muted">{voided.length} voided {voided.length === 1 ? 'entry' : 'entries'} kept on record.</p>}
      {editable && (
        <form className="inline" onSubmit={(ev) => (ev.preventDefault(), add.mutate())}>
          <select value={kind} onChange={(ev) => setKind(ev.target.value as VitalKind)}>
            {VITAL_KEYS.map((k) => <option key={k} value={k}>{VITAL_KINDS[k].label} ({VITAL_KINDS[k].unit})</option>)}
          </select>
          <input type="number" step="any" value={value} onChange={(ev) => setValue(ev.target.value)} required style={{ width: 110 }} aria-label="Value" />
          <button disabled={add.isPending}>Add</button>
        </form>
      )}
      {(add.error || voidObs.error) && <p className="error">{((add.error || voidObs.error) as Error).message}</p>}
    </div>
  );
}

interface Rx { clinic: string | null; doctor: { fullName: string | null; licenseNumber: string | null }; patient: { fullName: string; dateOfBirth: string | null; patientNumber: number }; date: string; items: { medication: string; dose: string; frequency: string; duration: string; notes: string }[] }

export function PrescriptionPage() {
  const { id } = useParams();
  const tz = useSettings().data?.timezone ?? 'Africa/Cairo';
  const q = useQuery({ queryKey: ['rx', id], queryFn: () => api<Rx>(`/encounters/${id}/prescription`) });
  if (q.isLoading) return <p>Loading…</p>;
  if (q.error || !q.data) return <p className="error">{(q.error as Error)?.message}</p>;
  const r = q.data;
  return (
    <section className="rx-sheet">
      <div className="row no-print"><Link to={`/encounters/${id}`}>← Encounter</Link><span className="spacer" /><button onClick={() => window.print()}>Print</button></div>
      <header className="rx-head">
        <h1>{r.clinic ?? 'Clinic'}</h1>
        <div>Dr {r.doctor.fullName}{r.doctor.licenseNumber && <> · Licence {r.doctor.licenseNumber}</>}</div>
      </header>
      <p><strong>{r.patient.fullName}</strong> · P-{String(r.patient.patientNumber).padStart(5, '0')}{r.patient.dateOfBirth && <> · DOB {r.patient.dateOfBirth}</>}<br />{fmtDateTime(r.date, tz)}</p>
      <ol>
        {r.items.map((it, i) => (
          <li key={i}><strong>{it.medication}</strong> {it.dose} {it.frequency && `· ${it.frequency}`} {it.duration && `· ${it.duration}`}{it.notes && <div className="muted">{it.notes}</div>}</li>
        ))}
      </ol>
    </section>
  );
}
