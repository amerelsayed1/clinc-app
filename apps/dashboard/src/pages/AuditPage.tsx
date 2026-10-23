import { useMutation, useQuery } from '@tanstack/react-query';
import { api, type AuditEntry } from '../api';

export function AuditPage() {
  const log = useQuery({ queryKey: ['audit'], queryFn: () => api<AuditEntry[]>('/workspace/audit?limit=100') });
  const verify = useMutation({ mutationFn: () => api<{ valid: boolean; checked: number; brokenAtSeq?: number }>('/workspace/audit/verify') });

  return (
    <section>
      <h2>Audit log</h2>
      <p>
        <button onClick={() => verify.mutate()} disabled={verify.isPending}>Verify integrity</button>{' '}
        {verify.data && (verify.data.valid ? <span className="success">Chain intact ({verify.data.checked} entries)</span> : <span className="error">Tampering detected at entry #{verify.data.brokenAtSeq}</span>)}
      </p>
      <table>
        <thead>
          <tr><th>#</th><th>When</th><th>Who</th><th>Action</th><th>Details</th></tr>
        </thead>
        <tbody>
          {log.data?.map((e) => (
            <tr key={e.seq}>
              <td>{e.seq}</td>
              <td>{new Date(e.createdAt).toLocaleString()}</td>
              <td>{e.actorName ?? '—'}{e.actorRole && <span className="muted"> ({e.actorRole})</span>}</td>
              <td><code>{e.action}</code></td>
              <td className="muted">{Object.keys(e.metadata).length ? JSON.stringify(e.metadata) : ''}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
