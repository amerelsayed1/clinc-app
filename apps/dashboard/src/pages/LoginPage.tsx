import { useState } from 'react';
import { api, tokens } from '../api';

export function LoginPage() {
  const [phone, setPhone] = useState('+20');
  const [code, setCode] = useState('');
  const [step, setStep] = useState<'phone' | 'code' | 'mfa'>('phone');
  const [mfaToken, setMfaToken] = useState('');
  const [mfaCode, setMfaCode] = useState('');
  const [useRecovery, setUseRecovery] = useState(false);
  const [devCode, setDevCode] = useState<string>();
  const [error, setError] = useState<string>();
  const [busy, setBusy] = useState(false);

  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    setError(undefined);
    try {
      await fn();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="center card">
      <h1>Clinic sign in</h1>
      {step === 'phone' ? (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            run(async () => {
              const r = await api<{ devCode?: string } | undefined>('/auth/otp/request', { method: 'POST', body: { phone } });
              setDevCode(r?.devCode);
              setStep('code');
            });
          }}
        >
          <label>
            Phone number
            <input value={phone} onChange={(e) => setPhone(e.target.value)} inputMode="tel" autoFocus />
          </label>
          <button disabled={busy}>Send code</button>
        </form>
      ) : step === 'mfa' ? (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            run(async () => {
              const r = await api<{ accessToken: string; refreshToken: string }>('/auth/mfa/verify', {
                method: 'POST',
                body: useRecovery ? { mfaToken, recoveryCode: mfaCode } : { mfaToken, code: mfaCode },
              });
              tokens.set({ accessToken: r.accessToken, refreshToken: r.refreshToken });
            });
          }}
        >
          <label>
            {useRecovery ? 'Recovery code' : 'Authenticator app code'}
            <input value={mfaCode} onChange={(e) => setMfaCode(e.target.value)} inputMode={useRecovery ? 'text' : 'numeric'} maxLength={useRecovery ? 20 : 6} autoFocus />
          </label>
          <button disabled={busy}>Verify</button>
          <button type="button" className="link" onClick={() => (setUseRecovery(!useRecovery), setMfaCode(''))}>
            {useRecovery ? 'Use authenticator code' : 'Use a recovery code'}
          </button>
        </form>
      ) : (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            run(async () => {
              const r = await api<{ accessToken?: string; refreshToken?: string; mfaRequired?: boolean; mfaToken?: string }>('/auth/otp/verify', {
                method: 'POST',
                body: { phone, code, deviceName: navigator.userAgent.slice(0, 80) },
              });
              if (r.mfaRequired && r.mfaToken) {
                setMfaToken(r.mfaToken);
                setStep('mfa');
              } else tokens.set({ accessToken: r.accessToken!, refreshToken: r.refreshToken! });
            });
          }}
        >
          <label>
            Code sent to {phone}
            <input value={code} onChange={(e) => setCode(e.target.value)} inputMode="numeric" maxLength={6} autoFocus />
          </label>
          {devCode && <p className="muted">Dev mode code: {devCode}</p>}
          <button disabled={busy}>Verify</button>
          <button type="button" className="link" onClick={() => setStep('phone')}>
            Change number
          </button>
        </form>
      )}
      {error && <p className="error">{error}</p>}
    </div>
  );
}
