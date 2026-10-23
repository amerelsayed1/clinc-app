import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { ApiError, api, type Appointment, type Patient, type Settings } from '../api';
import { fmtTime, todayIn } from '../time';

const LABEL: Record<Appointment['status'], string> = {
  scheduled: 'Scheduled',
  checked_in: 'Waiting',
  in_consultation: 'In consultation',
  completed: 'Completed',
  cancelled: 'Cancelled',
  no_show: 'No-show',
};

export function useSettings() {
  return useQuery({ queryKey: ['settings'], queryFn: () => api<Settings>('/workspace/settings'), staleTime: 60_000 });
}

export function AppointmentsPage({ can }: { can: (p: string) => boolean }) {
  const settings = useSettings();
  const tz = settings.data?.timezone ?? 'Africa/Cairo';
  const [date, setDate] = useState<string>();
  const day = date ?? todayIn(tz);
  const [adding, setAdding] = useState(false);
  const qc = useQueryClient();
  const list = useQuery({
    queryKey: ['appointments', day],
    queryFn: () => api<Appointment[]>(`/appointments?date=${day}`),
    enabled: !!settings.data,
    refetchInterval: 30_000, // keeps the waiting list fresh for front desk and doctor
  });
  const reload = () => qc.invalidateQueries({ queryKey: ['appointments'] });
  const act = useMutation({
    mutationFn: ({ id, action, body }: { id: string; action: string; body?: object }) => api(`/appointments/${id}/${action}`, { method: 'POST', body: body ?? {} }),
    onSuccess: reload,
  });

  const all = list.data ?? [];
  const waiting = all.filter((a) => a.status === 'checked_in').sort((a, b) => (a.checkedInAt ?? '').localeCompare(b.checkedInAt ?? ''));
  const inRoom = all.filter((a) => a.status === 'in_consultation');
  const upcoming = all.filter((a) => a.status === 'scheduled');
  const closed = all.filter((a) => ['completed', 'cancelled', 'no_show'].includes(a.status));

  const Actions = ({ a }: { a: Appointment }) => (
    <span className="actions">
      {a.status === 'scheduled' && can('appointments.manage') && <button onClick={() => act.mutate({ id: a.id, action: 'check-in' })}>Check in</button>}
      {a.status === 'checked_in' && can('clinical.write') && <button onClick={() => act.mutate({ id: a.id, action: 'start' })}>Start consultation</button>}
      {a.status === 'in_consultation' && can('clinical.write') && <button onClick={() => act.mutate({ id: a.id, action: 'complete' })}>Complete</button>}
      {a.status === 'scheduled' && can('appointments.manage') && new Date(a.scheduledAt) <= new Date() && <button onClick={() => act.mutate({ id: a.id, action: 'no-show' })}>No-show</button>}
      {(a.status === 'scheduled' || a.status === 'checked_in') && can('appointments.manage') && (
        <button className="danger" onClick={() => confirm(`Cancel ${a.patient.fullName}'s appointment?`) && act.mutate({ id: a.id, action: 'cancel' })}>Cancel</button>
      )}
    </span>
  );

  const Table = ({ rows, empty }: { rows: Appointment[]; empty: string }) => (
    <table>
      <tbody>
        {rows.map((a, i) => (
          <tr key={a.id}>
            <td style={{ width: 60 }}>{a.status === 'checked_in' ? `#${i + 1}` : fmtTime(a.scheduledAt, tz)}</td>
            <td>
              <Link to={`/patients/${a.patient.id}`}>{a.patient.fullName}</Link>
              {a.isWalkIn && <span className="pill invited" style={{ marginLeft: 6 }}>Walk-in</span>}
              {a.type === 'follow_up' && <span className="pill" style={{ marginLeft: 6 }}>Follow-up</span>}
              <div className="muted">{a.reason ?? ''}{a.cancelReason ? `Cancelled: ${a.cancelReason}` : ''}</div>
            </td>
            <td className="muted">{a.durationMinutes} min</td>
            <td><span className={`pill ${a.status}`}>{LABEL[a.status]}</span></td>
            <td style={{ textAlign: 'right' }}><Actions a={a} /></td>
          </tr>
        ))}
        {rows.length === 0 && <tr><td className="muted">{empty}</td></tr>}
      </tbody>
    </table>
  );

  return (
    <section>
      <div className="row">
        <h2>Appointments</h2>
        <input type="date" value={day} onChange={(e) => setDate(e.target.value)} style={{ width: 'auto' }} aria-label="Day" />
        {day !== todayIn(tz) && <button className="link" onClick={() => setDate(undefined)}>Today</button>}
        <span className="spacer" />
        {can('appointments.manage') && <button onClick={() => setAdding((a) => !a)}>{adding ? 'Close' : 'New appointment'}</button>}
      </div>
      {adding && <BookingForm tz={tz} day={day} onDone={() => (setAdding(false), reload())} />}
      {act.error && <p className="error">{(act.error as Error).message}</p>}
      <h3>Waiting ({waiting.length})</h3>
      <Table rows={waiting} empty="Nobody is waiting." />
      {inRoom.length > 0 && (<><h3>In consultation</h3><Table rows={inRoom} empty="" /></>)}
      <h3>Upcoming ({upcoming.length})</h3>
      <Table rows={upcoming} empty="No upcoming appointments for this day." />
      {closed.length > 0 && (<><h3>Closed</h3><Table rows={closed} empty="" /></>)}
    </section>
  );
}

function BookingForm({ tz, day, onDone }: { tz: string; day: string; onDone: () => void }) {
  const [q, setQ] = useState('');
  const [patient, setPatient] = useState<Patient>();
  const [f, setF] = useState({ time: '10:00', date: day, duration: '', type: 'new', reason: '', walkIn: false });
  const found = useQuery({
    queryKey: ['patient-pick', q],
    queryFn: () => api<Patient[]>(`/patients?limit=6&q=${encodeURIComponent(q.trim())}`),
    enabled: q.trim().length >= 2 && !patient,
  });
  const m = useMutation({
    mutationFn: (override: boolean) =>
      f.walkIn
        ? api('/appointments/walk-in', { method: 'POST', body: { patientId: patient!.id, type: f.type, ...(f.reason && { reason: f.reason }) } })
        : api('/appointments', {
            method: 'POST',
            body: { patientId: patient!.id, localStart: `${f.date}T${f.time}`, type: f.type, ...(f.duration && { durationMinutes: Number(f.duration) }), ...(f.reason && { reason: f.reason }), ...(override && { override }) },
          }),
    onSuccess: onDone,
  });
  const err = m.error instanceof ApiError ? m.error : undefined;
  const overridable = err && (err.code === 'slot_conflict' || err.code === 'outside_working_hours');

  return (
    <form className="card grid" onSubmit={(e) => (e.preventDefault(), patient && m.mutate(false))}>
      <div>
        <label>Patient
          {patient ? (
            <div className="row" style={{ margin: 0 }}><strong>{patient.fullName}</strong><button type="button" className="link" style={{ display: 'inline' }} onClick={() => setPatient(undefined)}>Change</button></div>
          ) : (
            <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search name, #number or exact phone" autoFocus />
          )}
        </label>
        {!patient && found.data?.map((p) => (
          <div key={p.id}><button type="button" className="link" onClick={() => setPatient(p)}>{p.fullName} · {p.phone}</button></div>
        ))}
      </div>
      <label className="check" style={{ alignSelf: 'end' }}><input type="checkbox" checked={f.walkIn} onChange={(e) => setF({ ...f, walkIn: e.target.checked })} /> Walk-in (join waiting list now)</label>
      {!f.walkIn && (
        <>
          <label>Date<input type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} required /></label>
          <label>Time ({tz})<input type="time" value={f.time} onChange={(e) => setF({ ...f, time: e.target.value })} required /></label>
          <label>Duration (min, optional)<input type="number" min={5} max={480} value={f.duration} onChange={(e) => setF({ ...f, duration: e.target.value })} /></label>
        </>
      )}
      <label>Type<select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}><option value="new">New</option><option value="follow_up">Follow-up</option></select></label>
      <label>Reason (no diagnoses)<input value={f.reason} maxLength={200} onChange={(e) => setF({ ...f, reason: e.target.value })} /></label>
      <div>
        <button disabled={!patient || m.isPending}>{f.walkIn ? 'Add to waiting list' : 'Book'}</button>
        {err && !overridable && <p className="error">{err.message}</p>}
        {overridable && (
          <div className="banner">
            {err.code === 'slot_conflict' ? `Overlaps ${err.details?.conflicts?.map((c: Appointment) => `${c.patient.fullName} (${fmtTime(c.scheduledAt, tz)})`).join(', ')}.` : 'Outside the clinic working hours.'}{' '}
            <button type="button" className="link" style={{ display: 'inline' }} onClick={() => m.mutate(true)}>Book anyway</button>
          </div>
        )}
      </div>
    </form>
  );
}
