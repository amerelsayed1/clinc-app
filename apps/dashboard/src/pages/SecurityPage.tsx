import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { api, tokens, type Me } from '../api';

interface SessionInfo {
  id: string;
  deviceName: string | null;
  ip: string | null;
  lastUsedAt: string;
  current: boolean;
}

/** MFA enrolment (F01-3). Used on the Security page and as the mandatory gate for doctors/admins. */
export function MfaSetup({ onDone }: { onDone: () => void }) {
  const [enrol, setEnrol] = useState<{ secret: string; otpauthUrl: string }>();
  const [code, setCode] = useState('');
  const [recovery, setRecovery] = useState<string[]>();
  const start = useMutation({ mutationFn: () => api<{ secret: string; otpauthUrl: string }>('/auth/mfa/enroll', { method: 'POST' }), onSuccess: setEnrol });
  const activate = useMutation({
    mutationFn: () => api<{ recoveryCodes: string[] }>('/auth/mfa/activate', { method: 'POST', body: { code } }),
    onSuccess: (r) => setRecovery(r.recoveryCodes),
  });

  if (recovery) {
    return (
      <div>
        <p><strong>Save these recovery codes.</strong> Each works once if you lose your authenticator. They will not be shown again.</p>
        <pre>{recovery.join('\n')}</pre>
        <button onClick={() => navigator.clipboard?.writeText(recovery.join('\n'))}>Copy</button>{' '}
        <button onClick={onDone}>I have saved them</button>
      </div>
    );
  }
  if (!enrol) {
    return (
      <div>
        <button onClick={() => start.mutate()} disabled={start.isPending}>Set up authenticator app</button>
        {start.error && <p className="error">{(start.error as Error).message}</p>}
      </div>
    );
  }
  return (
    <form onSubmit={(e) => (e.preventDefault(), activate.mutate())}>
      <p>Add this key to an authenticator app (Google Authenticator, Authy, 1Password…):</p>
      <pre>{enrol.secret}</pre>
      <p className="muted">Or open <a href={enrol.otpauthUrl}>the setup link</a> on a device with an authenticator installed.</p>
      <label>Enter the 6-digit code<input value={code} onChange={(e) => setCode(e.target.value)} inputMode="numeric" maxLength={6} autoFocus required /></label>
      <button disabled={activate.isPending}>Turn on</button>
      {activate.error && <p className="error">{(activate.error as Error).message}</p>}
    </form>
  );
}

/** Blocks the app until MFA is on, for accounts that must have it. */
export function MfaGate({ me }: { me: Me }) {
  const qc = useQueryClient();
  return (
    <div className="center card wide">
      <h1>Secure your account</h1>
      <p className="muted">Doctor accounts must use two-step verification before clinical features are available.</p>
      <MfaSetup onDone={() => qc.invalidateQueries({ queryKey: ['me'] })} />
      <button className="link" onClick={() => tokens.set(null)}>Sign out ({me.phone})</button>
    </div>
  );
}

export function SecurityPage({ me }: { me: Me }) {
  const qc = useQueryClient();
  const sessions = useQuery({ queryKey: ['sessions'], queryFn: () => api<SessionInfo[]>('/sessions') });
  const reloadSessions = () => qc.invalidateQueries({ queryKey: ['sessions'] });
  const revoke = useMutation({ mutationFn: (id: string) => api(`/sessions/${id}`, { method: 'DELETE' }), onSuccess: reloadSessions });
  const revokeOthers = useMutation({ mutationFn: () => api('/sessions/revoke-others', { method: 'POST' }), onSuccess: reloadSessions });
  const [mfaCode, setMfaCode] = useState('');
  const disable = useMutation({
    mutationFn: () => api('/auth/mfa/disable', { method: 'POST', body: { code: mfaCode } }),
    onSuccess: () => (setMfaCode(''), qc.invalidateQueries({ queryKey: ['me'] })),
  });

  return (
    <section>
      <h2>Security</h2>

      <h3>Two-step verification</h3>
      {me.mfaEnabled ? (
        <>
          <p>On. Signing in asks for a code from your authenticator app.</p>
          {!me.mfaRequired && (
            <form onSubmit={(e) => (e.preventDefault(), disable.mutate())}>
              <label>Authenticator code to turn off<input value={mfaCode} onChange={(e) => setMfaCode(e.target.value)} inputMode="numeric" maxLength={6} /></label>
              <button className="danger" disabled={disable.isPending}>Turn off</button>
              {disable.error && <p className="error">{(disable.error as Error).message}</p>}
            </form>
          )}
        </>
      ) : (
        <MfaSetup onDone={() => qc.invalidateQueries({ queryKey: ['me'] })} />
      )}

      <h3>Signed-in devices</h3>
      <table>
        <thead><tr><th>Device</th><th>Last active</th><th /></tr></thead>
        <tbody>
          {sessions.data?.map((s) => (
            <tr key={s.id}>
              <td>{s.deviceName ?? 'Unknown device'}{s.current && ' (this device)'}<div className="muted">{s.ip}</div></td>
              <td>{new Date(s.lastUsedAt).toLocaleString()}</td>
              <td>{!s.current && <button className="danger" onClick={() => revoke.mutate(s.id)}>Sign out</button>}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {(sessions.data?.length ?? 0) > 1 && <p><button className="danger" onClick={() => revokeOthers.mutate()}>Sign out all other devices</button></p>}

      <h3>Phone number</h3>
      <PhoneChange current={me.phone} onDone={() => qc.invalidateQueries({ queryKey: ['me'] })} />
    </section>
  );
}

function PhoneChange({ current, onDone }: { current: string; onDone: () => void }) {
  const [newPhone, setNewPhone] = useState('+20');
  const [step, setStep] = useState<'enter' | 'codes' | 'done'>('enter');
  const [oldCode, setOldCode] = useState('');
  const [newCode, setNewCode] = useState('');
  const [dev, setDev] = useState<{ devOldCode: string; devNewCode: string }>();
  const request = useMutation({
    mutationFn: () => api<{ devOldCode: string; devNewCode: string } | undefined>('/auth/phone-change/request', { method: 'POST', body: { newPhone } }),
    onSuccess: (r) => (setDev(r), setStep('codes')),
  });
  const confirm = useMutation({
    mutationFn: () => api('/auth/phone-change/confirm', { method: 'POST', body: { newPhone, oldCode, newCode } }),
    onSuccess: () => (setStep('done'), onDone()),
  });
  if (step === 'done') return <p>Your number is now {newPhone}. Other devices were signed out.</p>;
  return step === 'enter' ? (
    <form onSubmit={(e) => (e.preventDefault(), request.mutate())}>
      <p className="muted">Current number: {current}. We send a code to both numbers.</p>
      <label>New number<input value={newPhone} onChange={(e) => setNewPhone(e.target.value)} inputMode="tel" /></label>
      <button disabled={request.isPending}>Send codes</button>
      {request.error && <p className="error">{(request.error as Error).message}</p>}
    </form>
  ) : (
    <form onSubmit={(e) => (e.preventDefault(), confirm.mutate())}>
      <label>Code sent to {current}<input value={oldCode} onChange={(e) => setOldCode(e.target.value)} inputMode="numeric" maxLength={6} /></label>
      <label>Code sent to {newPhone}<input value={newCode} onChange={(e) => setNewCode(e.target.value)} inputMode="numeric" maxLength={6} /></label>
      {dev && <p className="muted">Dev mode codes: {dev.devOldCode} / {dev.devNewCode}</p>}
      <button disabled={confirm.isPending}>Change number</button>
      <button type="button" className="link" onClick={() => setStep('enter')}>Back</button>
      {confirm.error && <p className="error">{(confirm.error as Error).message}</p>}
    </form>
  );
}
