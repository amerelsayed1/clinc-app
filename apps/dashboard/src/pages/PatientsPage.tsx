import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { VITAL_KEYS, VITAL_KINDS, type VitalKind } from '@clinic/shared';
import { ApiError, api, type Appointment, type EncounterSummary, type Patient } from '../api';
import { fmtDateTime } from '../time';
import { AccessRequestsSection } from './SharedWithMePage';
import { DocumentsSection } from './DocumentsSection';
import { FollowupSection } from './FollowupSection';
import { TimelineSection } from './TimelineSection';
import { useSettings } from './AppointmentsPage';

const STATUS_LABEL = { active: 'Active', invited: 'Awaiting patient confirmation', ended: 'Ended' } as const;
const num = (n: number) => `P-${String(n).padStart(5, '0')}`;

function useDebounced<T>(value: T, ms = 300) {
  const [v, setV] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
}

export function PatientsPage({ can }: { can: (p: string) => boolean }) {
  const [q, setQ] = useState('');
  const [status, setStatus] = useState<'open' | 'ended'>('open');
  const [adding, setAdding] = useState(false);
  const dq = useDebounced(q.trim());
  const list = useQuery({
    queryKey: ['patients', dq, status],
    queryFn: () => api<Patient[]>(`/patients?status=${status}&limit=50${dq ? `&q=${encodeURIComponent(dq)}` : ''}`),
  });

  return (
    <section>
      <div className="row">
        <h2>Patients</h2>
        <span className="spacer" />
        {can('patients.write') && <button onClick={() => setAdding((a) => !a)}>{adding ? 'Close' : 'Register patient'}</button>}
      </div>
      {adding && <RegisterForm onDone={() => setAdding(false)} />}
      <div className="row">
        <input className="grow" placeholder="Search by name, patient number (#12) or exact phone (+20…)" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search patients" />
        <select value={status} onChange={(e) => setStatus(e.target.value as 'open' | 'ended')} style={{ width: 'auto' }}>
          <option value="open">Current</option>
          <option value="ended">Ended</option>
        </select>
      </div>
      {list.error && <p className="error">{(list.error as Error).message}</p>}
      <table>
        <thead>
          <tr><th>No.</th><th>Name</th><th>Phone</th><th>Date of birth</th><th>Status</th></tr>
        </thead>
        <tbody>
          {list.data?.map((p) => (
            <tr key={p.id}>
              <td>{num(p.patientNumber)}</td>
              <td><Link to={`/patients/${p.id}`}>{p.fullName}</Link></td>
              <td>{p.phone}</td>
              <td>{p.dateOfBirth ?? '—'}</td>
              <td><span className={`pill ${p.status}`}>{STATUS_LABEL[p.status]}</span></td>
            </tr>
          ))}
          {list.data?.length === 0 && (
            <tr><td colSpan={5} className="muted">{dq ? 'No matching patients.' : 'No patients yet.'}</td></tr>
          )}
        </tbody>
      </table>
    </section>
  );
}

function RegisterForm({ onDone }: { onDone: () => void }) {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const [f, setF] = useState({ phone: '+20', fullName: '', dateOfBirth: '', sex: '' });
  const m = useMutation({
    mutationFn: (confirmNotDuplicate: boolean) =>
      api<Patient>('/patients', {
        method: 'POST',
        body: { phone: f.phone, fullName: f.fullName, ...(f.dateOfBirth && { dateOfBirth: f.dateOfBirth }), ...(f.sex && { sex: f.sex }), ...(confirmNotDuplicate && { confirmNotDuplicate }) },
      }),
    onSuccess: (p) => {
      qc.invalidateQueries({ queryKey: ['patients'] });
      onDone();
      navigate(`/patients/${p.id}`);
    },
  });
  const dup = m.error instanceof ApiError && m.error.code === 'possible_duplicate';
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });

  return (
    <form className="card grid" onSubmit={(e) => (e.preventDefault(), m.mutate(false))}>
      <label>Full name<input value={f.fullName} onChange={set('fullName')} required minLength={2} autoFocus /></label>
      <label>Phone<input value={f.phone} onChange={set('phone')} required inputMode="tel" /></label>
      <label>Date of birth<input type="date" value={f.dateOfBirth} onChange={set('dateOfBirth')} max={new Date().toISOString().slice(0, 10)} /></label>
      <label>Sex<select value={f.sex} onChange={set('sex')}><option value="">—</option><option value="female">Female</option><option value="male">Male</option></select></label>
      <div>
        <button disabled={m.isPending}>Register</button>
        {m.error && !dup && <p className="error">{(m.error as Error).message}</p>}
        {dup && (
          <div className="banner">
            A patient with this name and date of birth already exists.{' '}
            <button type="button" className="link" style={{ display: 'inline' }} onClick={() => m.mutate(true)}>This is a different person — register anyway</button>
          </div>
        )}
      </div>
    </form>
  );
}

export function PatientDetailPage({ can }: { can: (p: string) => boolean }) {
  const { id } = useParams();
  const qc = useQueryClient();
  const p = useQuery({ queryKey: ['patient', id], queryFn: () => api<Patient>(`/patients/${id}`) });
  const [editing, setEditing] = useState(false);
  const [tab, setTab] = useState<'overview' | 'timeline'>('overview');
  const reload = () => {
    qc.invalidateQueries({ queryKey: ['patient', id] });
    qc.invalidateQueries({ queryKey: ['patients'] });
  };
  const end = useMutation({ mutationFn: () => api(`/patients/${id}/end`, { method: 'POST' }), onSuccess: reload });

  if (p.isLoading) return <p>Loading…</p>;
  if (p.error || !p.data) return <p className="error">{(p.error as Error)?.message ?? 'Not found'} <Link to="/patients">Back</Link></p>;
  const d = p.data;

  return (
    <section>
      <Link to="/patients">← Patients</Link>
      <div className="row">
        <h2>{d.fullName}</h2>
        <span className={`pill ${d.status}`}>{STATUS_LABEL[d.status]}</span>
        <span className="spacer" />
        {d.status !== 'ended' && can('patients.write') && <button onClick={() => setEditing((e) => !e)}>{editing ? 'Cancel' : 'Edit'}</button>}
        {d.status !== 'ended' && can('relationships.manage') && (
          <button className="danger" onClick={() => confirm(`End your care relationship with ${d.fullName}? You will lose access to this patient going forward.`) && end.mutate()}>End relationship</button>
        )}
      </div>
      {end.error && <p className="error">{(end.error as Error).message}</p>}
      {editing ? (
        <EditForm patient={d} onDone={() => (setEditing(false), reload())} />
      ) : (
        <dl>
          <dt>Patient no.</dt><dd>{num(d.patientNumber)}</dd>
          <dt>Phone</dt><dd>{d.phone}</dd>
          <dt>Date of birth</dt><dd>{d.dateOfBirth ?? '—'}</dd>
          <dt>Sex</dt><dd>{d.sex ?? '—'}</dd>
          <dt>Patient app</dt><dd>{d.hasAccount ? 'Has an account' : 'Not yet signed up'}</dd>
          <dt>Registered</dt><dd>{new Date(d.createdAt).toLocaleDateString()}</dd>
          {d.endedAt && (<><dt>Ended</dt><dd>{new Date(d.endedAt).toLocaleDateString()} by {d.endedBy}</dd></>)}
        </dl>
      )}
      {can('clinical.read') && (
        <div className="tabs" role="tablist">
          <button role="tab" aria-selected={tab === 'overview'} className={tab === 'overview' ? 'active' : ''} onClick={() => setTab('overview')}>Overview</button>
          <button role="tab" aria-selected={tab === 'timeline'} className={tab === 'timeline' ? 'active' : ''} onClick={() => setTab('timeline')}>Timeline</button>
        </div>
      )}
      {tab === 'timeline' && can('clinical.read') && <TimelineSection patientId={d.id} onOpenDocuments={() => setTab('overview')} />}
      {tab === 'overview' && <>
      {can('clinical.read') && <PatientEncounters patient={d} canCreate={can('clinical.write') && d.status !== 'ended'} />}
      {can('clinical.read') && <Trend patientId={d.id} />}
      {can('clinical.read') && <FollowupSection patientId={d.id} canWrite={can('clinical.write') && d.status !== 'ended'} />}
      {can('clinical.read') && <AccessRequestsSection patientId={d.id} patientName={d.fullName} canRequest={can('clinical.write') && d.status === 'active'} hasAccount={d.hasAccount} />}
      {can('patients.read') && <DocumentsSection patientId={d.id} can={can} />}
      {can('appointments.read') && <PatientAppointments id={d.id} />}
      </>}
    </section>
  );
}

function EditForm({ patient, onDone }: { patient: Patient; onDone: () => void }) {
  const [f, setF] = useState({ fullName: patient.fullName, dateOfBirth: patient.dateOfBirth ?? '', sex: patient.sex ?? '' });
  const m = useMutation({
    mutationFn: () => api(`/patients/${patient.id}`, { method: 'PATCH', body: { fullName: f.fullName, dateOfBirth: f.dateOfBirth || null, sex: f.sex || null } }),
    onSuccess: onDone,
  });
  return (
    <form className="card grid" onSubmit={(e) => (e.preventDefault(), m.mutate())}>
      <label>Full name<input value={f.fullName} onChange={(e) => setF({ ...f, fullName: e.target.value })} required minLength={2} /></label>
      <label>Date of birth<input type="date" value={f.dateOfBirth} onChange={(e) => setF({ ...f, dateOfBirth: e.target.value })} /></label>
      <label>Sex<select value={f.sex} onChange={(e) => setF({ ...f, sex: e.target.value as 'male' | 'female' | '' })}><option value="">—</option><option value="female">Female</option><option value="male">Male</option></select></label>
      <div><button disabled={m.isPending}>Save</button>{m.error && <p className="error">{(m.error as Error).message}</p>}</div>
    </form>
  );
}

function PatientAppointments({ id }: { id: string }) {
  const tz = useSettings().data?.timezone ?? 'Africa/Cairo';
  const q = useQuery({ queryKey: ['patient-appointments', id], queryFn: () => api<Appointment[]>(`/appointments?patientId=${id}`) });
  if (!q.data?.length) return null;
  return (
    <>
      <h3>Appointments</h3>
      <table>
        <tbody>
          {q.data.map((a) => (
            <tr key={a.id}><td>{fmtDateTime(a.scheduledAt, tz)}</td><td>{a.type === 'follow_up' ? 'Follow-up' : 'New'}{a.isWalkIn ? ' · walk-in' : ''}</td><td><span className={`pill ${a.status}`}>{a.status.replace('_', ' ')}</span></td></tr>
          ))}
        </tbody>
      </table>
    </>
  );
}

function PatientEncounters({ patient, canCreate }: { patient: Patient; canCreate: boolean }) {
  const tz = useSettings().data?.timezone ?? 'Africa/Cairo';
  const navigate = useNavigate();
  const q = useQuery({ queryKey: ['encounters', patient.id], queryFn: () => api<EncounterSummary[]>(`/patients/${patient.id}/encounters`) });
  const create = useMutation({
    mutationFn: () => api<{ id: string }>(`/patients/${patient.id}/encounters`, { method: 'POST', body: {} }),
    onSuccess: (e) => navigate(`/encounters/${e.id}`),
  });
  return (
    <>
      <div className="row" style={{ marginTop: '1.25rem' }}>
        <h3 style={{ margin: 0 }}>Encounters</h3>
        <span className="spacer" />
        {canCreate && <button onClick={() => create.mutate()} disabled={create.isPending}>New encounter</button>}
      </div>
      {create.error && <p className="error">{(create.error as Error).message}</p>}
      <table>
        <tbody>
          {q.data?.map((e) => (
            <tr key={e.id}>
              <td style={{ width: 170 }}><Link to={`/encounters/${e.id}`}>{fmtDateTime(e.encounterDate, tz)}</Link></td>
              <td>{e.chiefComplaint || <span className="muted">(no complaint yet)</span>}{e.diagnosis && <div className="muted">{e.diagnosis}</div>}</td>
              <td><span className={`pill ${e.status === 'signed' ? 'completed' : 'invited'}`}>{e.status === 'signed' ? `Signed v${e.currentVersion}` : 'Draft'}</span>{e.published && <span className="pill" style={{ marginLeft: 6 }}>Published</span>}</td>
            </tr>
          ))}
          {q.data?.length === 0 && <tr><td className="muted">No encounters yet.</td></tr>}
        </tbody>
      </table>
    </>
  );
}

function Trend({ patientId }: { patientId: string }) {
  const tz = useSettings().data?.timezone ?? 'Africa/Cairo';
  const [kind, setKind] = useState<VitalKind>('weight_kg');
  const q = useQuery({ queryKey: ['trend', patientId, kind], queryFn: () => api<{ unit: string; points: { id: string; value: number; measuredAt: string }[] }>(`/patients/${patientId}/observations?kind=${kind}`) });
  const pts = q.data?.points ?? [];
  const vals = pts.map((p) => p.value);
  const [lo, hi] = [Math.min(...vals), Math.max(...vals)];
  const x = (i: number) => (pts.length === 1 ? 150 : 10 + (i * 280) / (pts.length - 1));
  const y = (v: number) => (hi === lo ? 40 : 70 - ((v - lo) / (hi - lo)) * 60);
  return (
    <>
      <div className="row" style={{ marginTop: '1.25rem' }}>
        <h3 style={{ margin: 0 }}>Vitals trend</h3>
        <select value={kind} onChange={(e) => setKind(e.target.value as VitalKind)} style={{ width: 'auto' }}>
          {VITAL_KEYS.map((k) => <option key={k} value={k}>{VITAL_KINDS[k].label} ({VITAL_KINDS[k].unit})</option>)}
        </select>
      </div>
      {pts.length === 0 ? <p className="muted">No measurements yet.</p> : (
        <div className="trend">
          <svg viewBox="0 0 300 80" width="300" height="80" role="img" aria-label={`${VITAL_KINDS[kind].label} over time`}>
            <polyline fill="none" stroke="#0b5cd5" strokeWidth="2" points={pts.map((p, i) => `${x(i)},${y(p.value)}`).join(' ')} />
            {pts.map((p, i) => <circle key={p.id} cx={x(i)} cy={y(p.value)} r="3" fill="#0b5cd5" />)}
          </svg>
          <table>
            <tbody>
              {[...pts].reverse().slice(0, 8).map((p) => <tr key={p.id}><td>{fmtDateTime(p.measuredAt, tz)}</td><td><strong>{p.value}</strong> {q.data?.unit}</td></tr>)}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
