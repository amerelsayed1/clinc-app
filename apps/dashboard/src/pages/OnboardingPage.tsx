import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { api, tokens, type Me } from '../api';

/** First sign-in: doctors register + create a workspace; staff enter an invitation code. */
export function OnboardingPage({ me }: { me: Me }) {
  const qc = useQueryClient();
  const refresh = () => qc.invalidateQueries({ queryKey: ['me'] });
  const [mode, setMode] = useState<'doctor' | 'staff'>('doctor');

  return (
    <div className="center card wide">
      <h1>Welcome</h1>
      <p className="muted">{me.phone}</p>
      <div className="tabs">
        <button className={mode === 'doctor' ? 'active' : ''} onClick={() => setMode('doctor')}>I'm a doctor</button>
        <button className={mode === 'staff' ? 'active' : ''} onClick={() => setMode('staff')}>I have an invitation</button>
      </div>
      {mode === 'doctor' ? <DoctorSetup me={me} onDone={refresh} /> : <AcceptInvite onDone={refresh} />}
      <button className="link" onClick={() => tokens.set(null)}>Sign out</button>
    </div>
  );
}

function DoctorSetup({ me, onDone }: { me: Me; onDone: () => void }) {
  const [fullName, setFullName] = useState(me.fullName ?? '');
  const [licenseNumber, setLicense] = useState('');
  const [clinicName, setClinicName] = useState('');
  const m = useMutation({
    mutationFn: async () => {
      if (!me.doctorProfile) await api('/doctors/register', { method: 'POST', body: { fullName, licenseNumber } });
      await api('/workspaces', { method: 'POST', body: clinicName ? { name: clinicName } : {} });
    },
    onSuccess: onDone,
  });
  return (
    <form onSubmit={(e) => (e.preventDefault(), m.mutate())}>
      {!me.doctorProfile && (
        <>
          <label>Full name<input value={fullName} onChange={(e) => setFullName(e.target.value)} required minLength={2} /></label>
          <label>Medical licence number<input value={licenseNumber} onChange={(e) => setLicense(e.target.value)} required minLength={3} /></label>
        </>
      )}
      <label>Clinic name (optional)<input value={clinicName} onChange={(e) => setClinicName(e.target.value)} /></label>
      <button disabled={m.isPending}>Create my workspace</button>
      {m.error && <p className="error">{(m.error as Error).message}</p>}
    </form>
  );
}

function AcceptInvite({ onDone }: { onDone: () => void }) {
  const [code, setCode] = useState('');
  const m = useMutation({ mutationFn: () => api('/invitations/accept', { method: 'POST', body: { code } }), onSuccess: onDone });
  return (
    <form onSubmit={(e) => (e.preventDefault(), m.mutate())}>
      <label>Invitation code<input value={code} onChange={(e) => setCode(e.target.value)} required autoCapitalize="characters" /></label>
      <button disabled={m.isPending}>Join clinic</button>
      {m.error && <p className="error">{(m.error as Error).message}</p>}
    </form>
  );
}
