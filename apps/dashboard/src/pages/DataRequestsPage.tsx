import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { api, type DataRequest, type Retention } from '../api';

const TARGET: Record<DataRequest['targetType'], string> = { encounter: 'Consultation', document: 'Document', relationship: 'Registration details' };

/** Owner-only (F11-7): patients' correction requests. Deciding never edits the record; amendments go through the encounter's normal flow. */
export function DataRequestsPage({ canDecide }: { canDecide: boolean }) {
  const qc = useQueryClient();
  const [status, setStatus] = useState<'open' | 'resolved' | 'rejected'>('open');
  const list = useQuery({ queryKey: ['data-requests', status], queryFn: () => api<DataRequest[]>(`/correction-requests?status=${status}`) });
  const retention = useQuery({ queryKey: ['retention'], queryFn: () => api<Retention>('/workspace/retention') });
  const [note, setNote] = useState<Record<string, string>>({});
  const decide = useMutation({
    mutationFn: ({ id, action }: { id: string; action: 'resolve' | 'reject' }) => api(`/correction-requests/${id}/${action}`, { method: 'POST', body: { note: note[id] ?? '' } }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['data-requests'] }),
  });

  return (
    <section>
      <h2>Data requests</h2>
      <p className="muted">
        Patients can ask you to correct a record. Nothing changes automatically: if a correction is justified, amend the consultation (which keeps the earlier version), then mark the request resolved.
      </p>
      <p>
        {(['open', 'resolved', 'rejected'] as const).map((s) => (
          <button key={s} onClick={() => setStatus(s)} disabled={s === status}>{s}</button>
        ))}
      </p>
      {decide.error && <p className="error">{(decide.error as Error).message}</p>}
      {list.data?.length === 0 && <p className="muted">No {status} requests.</p>}
      {list.data?.map((r) => (
        <div className="card" key={r.id} style={{ marginBottom: '1rem' }}>
          <strong>{r.patient.fullName}</strong> <span className="muted">#{r.patient.patientNumber} · {TARGET[r.targetType]}{r.targetLabel ? ` (${r.targetLabel})` : ''} · {new Date(r.createdAt).toLocaleDateString()}</span>
          <p>{r.description}</p>
          {r.status === 'open' && canDecide ? (
            <>
              <input placeholder="Your reply to the patient (required)" value={note[r.id] ?? ''} onChange={(e) => setNote({ ...note, [r.id]: e.target.value })} style={{ width: '60%' }} />{' '}
              <button disabled={(note[r.id] ?? '').trim().length < 3 || decide.isPending} onClick={() => decide.mutate({ id: r.id, action: 'resolve' })}>Resolved</button>{' '}
              <button disabled={(note[r.id] ?? '').trim().length < 3 || decide.isPending} onClick={() => decide.mutate({ id: r.id, action: 'reject' })}>Reject</button>
              {r.targetType === 'encounter' && <> <a href={`/encounters/${r.targetId}`}>Open consultation</a></>}
            </>
          ) : (
            r.status !== 'open' && <p className="muted">{r.status}: {r.resolutionNote}</p>
          )}
        </div>
      ))}
      <h3>Retention</h3>
      {retention.data && (
        <>
          <p className="muted">
            Clinical records are kept for {retention.data.policy.clinicalRecordYears} years and the audit log for {retention.data.policy.auditLogYears} years (policy pending legal review). A legal hold overrides every deletion.
          </p>
          {retention.data.legalHolds.length === 0 ? <p className="muted">No records under legal hold.</p> : (
            <table>
              <thead><tr><th>Patient</th><th>Reason</th><th>Since</th></tr></thead>
              <tbody>{retention.data.legalHolds.map((h) => <tr key={h.patientId}><td>{h.fullName}</td><td>{h.reason}</td><td>{new Date(h.setAt).toLocaleDateString()}</td></tr>)}</tbody>
            </table>
          )}
        </>
      )}
    </section>
  );
}
