import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { PERMISSIONS, ROLE_DEFAULTS } from '@clinic/shared';
import { api, type Invitation, type Member } from '../api';

export function TeamPage() {
  const qc = useQueryClient();
  const members = useQuery({ queryKey: ['members'], queryFn: () => api<Member[]>('/workspace/members') });
  const invites = useQuery({ queryKey: ['invitations'], queryFn: () => api<Invitation[]>('/workspace/invitations') });
  const reload = () => {
    qc.invalidateQueries({ queryKey: ['members'] });
    qc.invalidateQueries({ queryKey: ['invitations'] });
  };

  const update = useMutation({
    mutationFn: ({ id, body }: { id: string; body: object }) => api(`/workspace/members/${id}`, { method: 'PATCH', body }),
    onSuccess: reload,
  });
  const remove = useMutation({ mutationFn: (id: string) => api(`/workspace/members/${id}`, { method: 'DELETE' }), onSuccess: reload });
  const revoke = useMutation({ mutationFn: (id: string) => api(`/workspace/invitations/${id}`, { method: 'DELETE' }), onSuccess: reload });

  return (
    <section>
      <h2>Team</h2>
      <InviteForm onDone={reload} />
      {(update.error || remove.error) && <p className="error">{((update.error || remove.error) as Error).message}</p>}
      <table>
        <thead>
          <tr><th>Name</th><th>Role</th><th>Status</th><th>Permissions</th><th /></tr>
        </thead>
        <tbody>
          {members.data?.map((m) => (
            <tr key={m.id}>
              <td>{m.fullName ?? '—'}<div className="muted">{m.phone}</div></td>
              <td>{m.role}</td>
              <td>{m.status}</td>
              <td>
                {m.role === 'doctor' ? (
                  <span className="muted">Owner — all permissions</span>
                ) : (
                  <div className="perms">
                    {PERMISSIONS.filter((p) => ROLE_DEFAULTS[m.role].includes(p)).map((p) => (
                      <label key={p} className="check">
                        <input
                          type="checkbox"
                          checked={!m.deniedPermissions.includes(p)}
                          onChange={(e) =>
                            update.mutate({ id: m.id, body: { deniedPermissions: e.target.checked ? m.deniedPermissions.filter((d) => d !== p) : [...m.deniedPermissions, p] } })
                          }
                        />
                        {p}
                      </label>
                    ))}
                  </div>
                )}
              </td>
              <td>
                {m.role !== 'doctor' && (
                  <>
                    <button onClick={() => update.mutate({ id: m.id, body: { status: m.status === 'active' ? 'suspended' : 'active' } })}>{m.status === 'active' ? 'Suspend' : 'Reactivate'}</button>{' '}
                    <button className="danger" onClick={() => confirm(`Remove ${m.fullName ?? m.phone}?`) && remove.mutate(m.id)}>Remove</button>
                  </>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      {!!invites.data?.length && (
        <>
          <h3>Pending invitations</h3>
          <ul>
            {invites.data.map((i) => (
              <li key={i.id}>
                {i.phone} · {i.role} · expires {new Date(i.expiresAt).toLocaleDateString()} <button onClick={() => revoke.mutate(i.id)}>Revoke</button>
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  );
}

function InviteForm({ onDone }: { onDone: () => void }) {
  const [phone, setPhone] = useState('+20');
  const [role, setRole] = useState<'receptionist' | 'nurse'>('receptionist');
  const m = useMutation({
    mutationFn: () => api<{ code: string }>('/workspace/invitations', { method: 'POST', body: { phone, role } }),
    onSuccess: onDone,
  });
  return (
    <form className="inline" onSubmit={(e) => (e.preventDefault(), m.mutate())}>
      <input value={phone} onChange={(e) => setPhone(e.target.value)} aria-label="Phone" />
      <select value={role} onChange={(e) => setRole(e.target.value as 'nurse' | 'receptionist')}>
        <option value="receptionist">Receptionist</option>
        <option value="nurse">Nurse</option>
      </select>
      <button disabled={m.isPending}>Invite</button>
      {m.data && <span className="success">Invitation code (shown once): <code>{m.data.code}</code></span>}
      {m.error && <span className="error">{(m.error as Error).message}</span>}
    </form>
  );
}
