import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { api, type Settings, type WorkingHours } from '../api';
import { useSettings } from './AppointmentsPage';

const DAYS: { key: keyof WorkingHours; label: string }[] = [
  { key: 'sat', label: 'Saturday' }, { key: 'sun', label: 'Sunday' }, { key: 'mon', label: 'Monday' }, { key: 'tue', label: 'Tuesday' },
  { key: 'wed', label: 'Wednesday' }, { key: 'thu', label: 'Thursday' }, { key: 'fri', label: 'Friday' },
];

export function SettingsPage() {
  const qc = useQueryClient();
  const q = useSettings();
  const [s, setS] = useState<Settings>();
  useEffect(() => { if (q.data) setS(q.data); }, [q.data]);
  const save = useMutation({
    mutationFn: (v: Settings) => api<Settings>('/workspace/settings', { method: 'PATCH', body: v }),
    onSuccess: (v) => qc.setQueryData(['settings'], v),
  });
  if (!s) return <p>Loading…</p>;

  const setDay = (key: keyof WorkingHours, range: { start: string; end: string } | null) =>
    setS({ ...s, workingHours: { ...s.workingHours, [key]: range ? [range] : [] } });

  return (
    <section>
      <h2>Clinic settings</h2>
      <form className="card" onSubmit={(e) => (e.preventDefault(), save.mutate(s))}>
        <div className="grid">
          <label>Time zone<input value={s.timezone} onChange={(e) => setS({ ...s, timezone: e.target.value })} /></label>
          <label>Default appointment length (minutes)<input type="number" min={5} max={120} value={s.slotMinutes} onChange={(e) => setS({ ...s, slotMinutes: Number(e.target.value) })} /></label>
        </div>
        <h3>Working hours</h3>
        {DAYS.map(({ key, label }) => {
          const r = s.workingHours[key][0];
          return (
            <div className="row" key={key} style={{ marginBottom: '.4rem' }}>
              <label className="check" style={{ width: 120 }}><input type="checkbox" checked={!!r} onChange={(e) => setDay(key, e.target.checked ? { start: '09:00', end: '17:00' } : null)} /> {label}</label>
              {r ? (
                <>
                  <input type="time" value={r.start} onChange={(e) => setDay(key, { ...r, start: e.target.value })} style={{ width: 'auto', margin: 0 }} />
                  <span>to</span>
                  <input type="time" value={r.end} onChange={(e) => setDay(key, { ...r, end: e.target.value })} style={{ width: 'auto', margin: 0 }} />
                </>
              ) : <span className="muted">Closed</span>}
            </div>
          );
        })}
        <p><button disabled={save.isPending}>Save settings</button> {save.isSuccess && <span className="success">Saved</span>}</p>
        {save.error && <p className="error">{(save.error as Error).message}</p>}
      </form>
    </section>
  );
}
