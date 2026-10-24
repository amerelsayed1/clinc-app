import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { VITAL_KEYS, VITAL_KINDS } from '@clinic/shared';
import { api, type AttentionEntry, type FollowupMeasurement, type FollowupPlan, type FollowupTrend, type FollowupVersion } from '../api';
import { fmtDateTime } from '../time';
import { useSettings } from './AppointmentsPage';

/** Wording required by spec 09: a neutral flag, never a clinical conclusion. */
export const FLAG_TEXT = 'patient-reported, outside expected range';
const FREQ = (m: Pick<FollowupMeasurement, 'frequency' | 'intervalDays'>) => (m.frequency === 'custom' ? `every ${m.intervalDays} days` : m.frequency);

// ---------- Attention widget (F09-4) ----------
export function AttentionWidget() {
  const q = useQuery({ queryKey: ['followup-attention'], queryFn: () => api<AttentionEntry[]>('/followups/attention'), refetchInterval: 60_000 });
  if (!q.data?.length) return null;
  return (
    <div className="attention" role="region" aria-label="Follow-up needs attention">
      <h3>Follow-up needs attention ({q.data.length})</h3>
      <ul>
        {q.data.map((e) => (
          <li key={e.careRelationshipId}>
            <Link to={`/patients/${e.careRelationshipId}`}>{e.patientName}</Link>
            <span className="muted"> — overdue: {e.items.map((i) => `${i.measurementName} (${i.daysOverdue}d)`).join(', ')}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

// ---------- Trend chart (no charting dependency) ----------
function TrendChart({ planId, m }: { planId: string; m: FollowupMeasurement }) {
  const q = useQuery({ queryKey: ['followup-trend', planId, m.id], queryFn: () => api<FollowupTrend>(`/followups/${planId}/measurements/${m.id}/trend`) });
  const pts = q.data?.points ?? [];
  if (pts.length === 0) return <p className="muted">No patient-reported values yet.</p>;
  const vals = [...pts.map((p) => p.value), ...(m.normalMin != null ? [m.normalMin] : []), ...(m.normalMax != null ? [m.normalMax] : [])];
  const lo = Math.min(...vals);
  const hi = Math.max(...vals);
  const t0 = new Date(pts[0]!.measuredAt).getTime();
  const span = new Date(pts[pts.length - 1]!.measuredAt).getTime() - t0;
  const x = (p: { measuredAt: string }, i: number) => (pts.length === 1 || span === 0 ? 10 + (i * 280) / Math.max(1, pts.length - 1) : 10 + ((new Date(p.measuredAt).getTime() - t0) / span) * 280);
  const y = (v: number) => (hi === lo ? 40 : 70 - ((v - lo) / (hi - lo)) * 60);
  return (
    <svg className="trend-chart" viewBox="0 0 300 80" width="300" height="80" role="img" aria-label={`${m.name}, patient-reported values over time`}>
      {m.normalMin != null && <line x1="0" x2="300" y1={y(m.normalMin)} y2={y(m.normalMin)} stroke="#c4cdd8" strokeDasharray="4 3" />}
      {m.normalMax != null && <line x1="0" x2="300" y1={y(m.normalMax)} y2={y(m.normalMax)} stroke="#c4cdd8" strokeDasharray="4 3" />}
      <polyline fill="none" stroke="#0b5cd5" strokeWidth="2" points={pts.map((p, i) => `${x(p, i)},${y(p.value)}`).join(' ')} />
      {pts.map((p, i) => (
        <circle key={p.id} cx={x(p, i)} cy={y(p.value)} r="3.5" fill={p.outsideExpectedRange ? '#e0a030' : '#0b5cd5'}>
          <title>{`${p.value} ${m.unit}${p.outsideExpectedRange ? ` — ${FLAG_TEXT}` : ''}`}</title>
        </circle>
      ))}
    </svg>
  );
}

// ---------- Plan form (create + edit) ----------
interface MRow {
  id?: string;
  kind: string;
  name: string;
  unit: string;
  frequency: 'daily' | 'weekly' | 'custom';
  intervalDays: string;
  normalMin: string;
  normalMax: string;
}
const blankRow = (): MRow => ({ kind: 'heart_rate', name: '', unit: '', frequency: 'daily', intervalDays: '2', normalMin: '', normalMax: '' });
const rowOf = (m: FollowupMeasurement): MRow => ({
  id: m.id,
  kind: m.kind ?? '',
  name: m.kind ? '' : m.name,
  unit: m.kind ? '' : m.unit,
  frequency: m.frequency,
  intervalDays: String(m.intervalDays),
  normalMin: m.normalMin == null ? '' : String(m.normalMin),
  normalMax: m.normalMax == null ? '' : String(m.normalMax),
});

function PlanForm({ relationshipId, plan, onDone }: { relationshipId: string; plan?: FollowupPlan; onDone: () => void }) {
  const [f, setF] = useState({ instructions: plan?.instructions ?? '', nextVisitDate: plan?.nextVisitDate ?? '', startDate: plan?.startDate ?? '', endDate: plan?.endDate ?? '' });
  const [rows, setRows] = useState<MRow[]>(plan ? plan.measurements.filter((m) => m.active).map(rowOf) : [blankRow()]);
  const patchRow = (i: number, p: Partial<MRow>) => setRows((rs) => rs.map((r, j) => (j === i ? { ...r, ...p } : r)));
  const save = useMutation({
    mutationFn: () => {
      const measurements = rows.map((r) => ({
        ...(r.id && { id: r.id }),
        ...(r.kind ? { kind: r.kind } : { name: r.name }),
        ...(!r.kind && r.unit && { unit: r.unit }),
        frequency: r.frequency,
        ...(r.frequency === 'custom' && { intervalDays: Number(r.intervalDays) }),
        normalMin: r.normalMin === '' ? null : Number(r.normalMin),
        normalMax: r.normalMax === '' ? null : Number(r.normalMax),
      }));
      const common = { instructions: f.instructions, nextVisitDate: f.nextVisitDate || null, endDate: f.endDate || null, measurements };
      return plan
        ? api(`/followups/${plan.id}`, { method: 'PATCH', body: { ...common, version: plan.currentVersion } })
        : api(`/patients/${relationshipId}/followups`, { method: 'POST', body: { ...common, ...(f.startDate && { startDate: f.startDate }) } });
    },
    onSuccess: onDone,
  });
  return (
    <form className="card" onSubmit={(e) => (e.preventDefault(), save.mutate())}>
      <label>Instructions for the patient<textarea rows={3} value={f.instructions} maxLength={2000} onChange={(e) => setF({ ...f, instructions: e.target.value })} /></label>
      <div className="grid">
        <label>Next visit<input type="date" value={f.nextVisitDate} onChange={(e) => setF({ ...f, nextVisitDate: e.target.value })} /></label>
        {!plan && <label>Start date (default today)<input type="date" value={f.startDate} onChange={(e) => setF({ ...f, startDate: e.target.value })} /></label>}
        <label>End date<input type="date" value={f.endDate} min={f.startDate || plan?.startDate} onChange={(e) => setF({ ...f, endDate: e.target.value })} /></label>
      </div>
      <h3>Requested measurements</h3>
      {rows.map((r, i) => (
        <div className="meas-row" key={r.id ?? i}>
          <select aria-label="Measurement" value={r.kind} onChange={(e) => patchRow(i, { kind: e.target.value })}>
            {VITAL_KEYS.map((k) => <option key={k} value={k}>{VITAL_KINDS[k].label} ({VITAL_KINDS[k].unit})</option>)}
            <option value="">Custom…</option>
          </select>
          {r.kind === '' ? (
            <span style={{ display: 'flex', gap: 4 }}>
              <input aria-label="Name" placeholder="Name" value={r.name} required maxLength={80} onChange={(e) => patchRow(i, { name: e.target.value })} />
              <input aria-label="Unit" placeholder="Unit" value={r.unit} maxLength={20} style={{ width: 70 }} onChange={(e) => patchRow(i, { unit: e.target.value })} />
            </span>
          ) : <span className="muted">{VITAL_KINDS[r.kind as keyof typeof VITAL_KINDS].label}</span>}
          <select aria-label="Frequency" value={r.frequency} onChange={(e) => patchRow(i, { frequency: e.target.value as MRow['frequency'] })}>
            <option value="daily">Daily</option><option value="weekly">Weekly</option><option value="custom">Every N days</option>
          </select>
          {r.frequency === 'custom' ? <input aria-label="Every N days" type="number" min={1} max={90} value={r.intervalDays} onChange={(e) => patchRow(i, { intervalDays: e.target.value })} /> : <span />}
          <input aria-label="Expected minimum" type="number" step="any" placeholder="min" value={r.normalMin} onChange={(e) => patchRow(i, { normalMin: e.target.value })} />
          <input aria-label="Expected maximum" type="number" step="any" placeholder="max" value={r.normalMax} onChange={(e) => patchRow(i, { normalMax: e.target.value })} />
          <button type="button" className="danger" onClick={() => setRows((rs) => rs.filter((_, j) => j !== i))} aria-label="Remove measurement">×</button>
        </div>
      ))}
      <p className="muted">The expected range is only used to highlight values for you; patients never see it.</p>
      <div className="row">
        {rows.length < 10 && <button type="button" onClick={() => setRows((rs) => [...rs, blankRow()])}>Add measurement</button>}
        <span className="spacer" />
        <button disabled={save.isPending}>{plan ? 'Save changes' : 'Create plan'}</button>
      </div>
      {save.error && <p className="error">{(save.error as Error).message}</p>}
    </form>
  );
}

// ---------- One plan ----------
function PlanView({ id, canWrite, onChanged }: { id: string; canWrite: boolean; onChanged: () => void }) {
  const tz = useSettings().data?.timezone ?? 'Africa/Cairo';
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['followup', id], queryFn: () => api<FollowupPlan>(`/followups/${id}`) });
  const [editing, setEditing] = useState(false);
  const [history, setHistory] = useState(false);
  const hist = useQuery({ queryKey: ['followup-history', id], queryFn: () => api<FollowupVersion[]>(`/followups/${id}/history`), enabled: history });
  const reload = () => {
    qc.invalidateQueries({ queryKey: ['followup'] });
    qc.invalidateQueries({ queryKey: ['followup-trend'] });
    qc.invalidateQueries({ queryKey: ['followup-history'] });
    qc.invalidateQueries({ queryKey: ['followup-attention'] });
    onChanged();
  };
  const close = useMutation({ mutationFn: (reason: string) => api(`/followups/${id}/close`, { method: 'POST', body: { reason } }), onSuccess: reload });
  const p = q.data;
  if (!p) return null;
  const subs = p.submissions ?? [];
  return (
    <div className="card" style={{ marginBottom: '1rem' }}>
      <div className="row">
        <strong>Plan {p.startDate} → {p.endDate ?? 'open-ended'}</strong>
        <span className={`pill ${p.status === 'closed' ? 'ended' : ''}`}>{p.status === 'closed' ? 'Closed' : 'Active'}</span>
        <span className="muted">v{p.currentVersion}{p.nextVisitDate ? ` · next visit ${p.nextVisitDate}` : ''}</span>
        <span className="spacer" />
        {canWrite && p.status === 'active' && <button onClick={() => setEditing((e) => !e)}>{editing ? 'Cancel' : 'Edit'}</button>}
        {canWrite && p.status === 'active' && <button className="danger" onClick={() => { const r = prompt('Close this follow-up plan? Optional reason:'); if (r !== null) close.mutate(r); }}>Close plan</button>}
        <button onClick={() => setHistory((h) => !h)}>{history ? 'Hide history' : 'History'}</button>
      </div>
      {close.error && <p className="error">{(close.error as Error).message}</p>}
      {p.closeReason && <p className="muted">Closed: {p.closeReason}</p>}
      {editing ? (
        <PlanForm relationshipId={p.careRelationshipId} plan={p} onDone={() => (setEditing(false), reload())} />
      ) : (
        <>
          {p.instructions && <p>{p.instructions}</p>}
          <p className="muted">Values below are reported by the patient and are not verified findings.</p>
          {p.measurements.filter((m) => m.active).map((m) => (
            <div className="followup-meas" key={m.id}>
              <div className="row" style={{ marginBottom: '.25rem' }}>
                <strong>{m.name}</strong>
                <span className="muted">{m.unit} · {FREQ(m)}{m.normalMin != null || m.normalMax != null ? ` · expected ${m.normalMin ?? '…'}–${m.normalMax ?? '…'}` : ''}</span>
                {m.overdue && <span className="pill invited">Overdue</span>}
              </div>
              <TrendChart planId={p.id} m={m} />
            </div>
          ))}
          <h3>Submissions</h3>
          <table>
            <tbody>
              {subs.map((s) => (
                <tr key={s.id} className={s.outsideExpectedRange ? 'flagged' : ''}>
                  <td style={{ width: 170 }}>{fmtDateTime(s.measuredAt, tz)}</td>
                  <td>
                    {s.measurementName}: <strong>{s.value}</strong> {s.unit}
                    {s.outsideExpectedRange && <span className="flag">{FLAG_TEXT}</span>}
                    {s.note && <div className="muted">{s.note}</div>}
                  </td>
                  <td className="muted">patient-reported{s.documentId ? ' · attachment' : ''}</td>
                </tr>
              ))}
              {subs.length === 0 && <tr><td className="muted">Nothing submitted yet.</td></tr>}
            </tbody>
          </table>
        </>
      )}
      {history && (
        <>
          <h3>Edit history</h3>
          <table>
            <tbody>
              {hist.data?.map((v) => (
                <tr key={v.version}>
                  <td style={{ width: 170 }}>{fmtDateTime(v.at, tz)}</td>
                  <td>v{v.version} {v.change} by {v.editedBy}<div className="muted">{v.snapshot.plan.instructions || '(no instructions)'} · {v.snapshot.measurements.filter((m) => m.active).map((m) => m.name).join(', ') || 'no measurements'}</div></td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </div>
  );
}

// ---------- Section on the patient page ----------
export function FollowupSection({ patientId, canWrite }: { patientId: string; canWrite: boolean }) {
  const qc = useQueryClient();
  const [creating, setCreating] = useState(false);
  const q = useQuery({ queryKey: ['followups', patientId], queryFn: () => api<FollowupPlan[]>(`/patients/${patientId}/followups`) });
  const reload = () => qc.invalidateQueries({ queryKey: ['followups', patientId] });
  return (
    <>
      <div className="row" style={{ marginTop: '1.25rem' }}>
        <h3 style={{ margin: 0 }}>Follow-up</h3>
        <span className="spacer" />
        {canWrite && <button onClick={() => setCreating((c) => !c)}>{creating ? 'Cancel' : 'New follow-up plan'}</button>}
      </div>
      {creating && <PlanForm relationshipId={patientId} onDone={() => (setCreating(false), reload())} />}
      {q.data?.map((p) => <PlanView key={p.id} id={p.id} canWrite={canWrite} onChanged={reload} />)}
      {q.data?.length === 0 && !creating && <p className="muted">No follow-up plans.</p>}
    </>
  );
}
