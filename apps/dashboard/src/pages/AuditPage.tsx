import { useMutation, useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { api, type AuditEntry } from '../api';

const GROUPS: [string, string][] = [
  ['', 'All actions'],
  ['encounter.', 'Encounters'],
  ['patient.', 'Patient records'],
  ['document.', 'Documents'],
  ['shared_item.', 'Shared records'],
  ['grant.', 'Sharing grants'],
  ['member.', 'Staff and permissions'],
  ['invitation.', 'Invitations'],
  ['auth.', 'Sign-in and security'],
  ['correction.', 'Correction requests'],
  ['audit.', 'Audit exports'],
  ['access.denied', 'Denied attempts'],
  ['breakglass.', 'Platform break-glass'],
];

const toQuery = (f: Record<string, string>) => Object.entries(f).filter(([, v]) => v).map(([k, v]) => `&${k}=${encodeURIComponent(v)}`).join('');

export function AuditPage() {
  const [f, setF] = useState({ action: '', actor: '', from: '', to: '', result: '', targetId: '' });
  const [applied, setApplied] = useState(f);
  const q = toQuery(applied);
  const log = useQuery({ queryKey: ['audit', q], queryFn: () => api<AuditEntry[]>(`/workspace/audit?limit=200${q}`) });
  const staff = useQuery({ queryKey: ['members'], queryFn: () => api<{ userId: string; fullName: string | null; phone: string }[]>('/workspace/members') });
  const verify = useMutation({ mutationFn: () => api<{ valid: boolean; checked: number; brokenAtSeq?: number }>('/workspace/audit/verify') });
  const exportLog = useMutation({
    mutationFn: async () => {
      const data = await api<unknown>(`/workspace/audit/export?${q.slice(1)}`);
      const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' }));
      const a = document.createElement('a');
      a.href = url;
      a.download = `audit-log-${new Date().toISOString().slice(0, 10)}.json`;
      a.click();
      URL.revokeObjectURL(url);
    },
  });

  const breakGlass = (log.data ?? []).filter((e) => e.breakGlass);
  const set = (k: keyof typeof f) => (ev: { target: { value: string } }) => setF({ ...f, [k]: ev.target.value });

  return (
    <section>
      <h2>Audit log</h2>
      {breakGlass.length > 0 && (
        <div className="banner error" role="alert">
          <strong>Platform support accessed this clinic's audit log {breakGlass.filter((e) => e.action === 'breakglass.granted').length} time(s).</strong>{' '}
          Each access required a written justification; see the highlighted rows below.
        </div>
      )}
      <form
        className="filters"
        onSubmit={(e) => {
          e.preventDefault();
          setApplied(f);
        }}
      >
        <label>
          Type
          <select value={f.action} onChange={set('action')}>
            {GROUPS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
          </select>
        </label>
        <label>
          Who
          <select value={f.actor} onChange={set('actor')}>
            <option value="">Anyone</option>
            {staff.data?.map((m) => <option key={m.userId} value={m.userId}>{m.fullName ?? m.phone}</option>)}
          </select>
        </label>
        <label>From<input type="date" value={f.from} onChange={set('from')} /></label>
        <label>To<input type="date" value={f.to} onChange={set('to')} /></label>
        <label>
          Result
          <select value={f.result} onChange={set('result')}>
            <option value="">Any</option>
            <option value="success">Allowed</option>
            <option value="denied">Denied</option>
          </select>
        </label>
        <label>Record id<input value={f.targetId} onChange={set('targetId')} placeholder="patient / encounter / document id" /></label>
        <button type="submit">Apply</button>
        <button type="button" onClick={() => { const empty = { action: '', actor: '', from: '', to: '', result: '', targetId: '' }; setF(empty); setApplied(empty); }}>Clear</button>
      </form>
      <p>
        <button onClick={() => verify.mutate()} disabled={verify.isPending}>Verify integrity</button>{' '}
        <button onClick={() => exportLog.mutate()} disabled={exportLog.isPending}>Export as JSON</button>{' '}
        {verify.data && (verify.data.valid ? <span className="success">Chain intact ({verify.data.checked} entries)</span> : <span className="error">Tampering detected at entry #{verify.data.brokenAtSeq}</span>)}
        {exportLog.error && <span className="error"> {(exportLog.error as Error).message}</span>}
        {exportLog.isSuccess && <span className="muted"> Exported (this export is recorded in the log).</span>}
      </p>
      <table>
        <thead>
          <tr><th>#</th><th>When</th><th>Who</th><th>Action</th><th>Result</th><th>Where</th><th>Details</th></tr>
        </thead>
        <tbody>
          {log.data?.map((e) => (
            <tr key={e.seq} className={e.breakGlass ? 'breakglass' : e.result === 'denied' ? 'denied' : undefined}>
              <td>{e.seq}</td>
              <td>{new Date(e.createdAt).toLocaleString()}</td>
              <td>{e.actorName ?? '—'}{e.actorRole && <span className="muted"> ({e.actorRole === 'platform_admin' ? 'platform support' : e.actorRole})</span>}</td>
              <td>
                {e.breakGlass && <span className="pill badge-breakglass">break-glass</span>} <code>{e.action}</code>
              </td>
              <td>{e.result === 'denied' ? <span className="pill badge-denied">denied</span> : 'ok'}</td>
              <td className="muted" title={e.device ?? undefined}>{e.ip ?? ''}</td>
              <td className={e.breakGlass ? undefined : 'muted'}>
                {e.breakGlass && typeof e.metadata.justification === 'string' ? <>Reason: {e.metadata.justification}</> : Object.keys(e.metadata).length ? JSON.stringify(e.metadata) : ''}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {log.data?.length === 0 && <p className="muted">No entries match.</p>}
    </section>
  );
}
