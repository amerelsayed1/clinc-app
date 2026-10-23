import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { NavLink, Navigate, Route, Routes } from 'react-router-dom';
import { api, tokens, type Me } from './api';
import { AppointmentsPage } from './pages/AppointmentsPage';
import { AuditPage } from './pages/AuditPage';
import { EncounterPage, PrescriptionPage } from './pages/EncounterPage';
import { LoginPage } from './pages/LoginPage';
import { OnboardingPage } from './pages/OnboardingPage';
import { PatientDetailPage, PatientsPage } from './pages/PatientsPage';
import { SettingsPage } from './pages/SettingsPage';
import { TeamPage } from './pages/TeamPage';

function useAuthed() {
  const [authed, setAuthed] = useState(() => !!tokens.get());
  useEffect(() => {
    const sync = () => setAuthed(!!tokens.get());
    window.addEventListener('clinic:auth', sync);
    return () => window.removeEventListener('clinic:auth', sync);
  }, []);
  return authed;
}

export function App() {
  const authed = useAuthed();
  const qc = useQueryClient();
  const me = useQuery({ queryKey: ['me'], queryFn: () => api<Me>('/me'), enabled: authed });

  if (!authed) return <LoginPage />;
  if (me.isLoading) return <p className="center">Loading…</p>;
  if (me.isError || !me.data) return <p className="center">Could not load your account. <button onClick={() => tokens.set(null)}>Sign in again</button></p>;

  const user = me.data;
  const membership = user.memberships[0];
  if (!membership) return <OnboardingPage me={user} />;

  const can = (p: string) => membership.permissions.includes(p);
  const logout = async () => {
    await api('/auth/logout', { method: 'POST' }).catch(() => undefined);
    tokens.set(null);
    qc.clear();
  };

  return (
    <div className="shell">
      <header>
        <strong>{membership.workspaceName ?? 'My Clinic'}</strong>
        <nav>
          {can('appointments.read') && <NavLink to="/appointments">Appointments</NavLink>}
          {can('patients.read') && <NavLink to="/patients">Patients</NavLink>}
          {can('staff.manage') && <NavLink to="/team">Team</NavLink>}
          {can('staff.manage') && <NavLink to="/settings">Settings</NavLink>}
          {can('audit.read') && <NavLink to="/audit">Audit log</NavLink>}
        </nav>
        <span className="spacer" />
        <span className="muted">
          {user.fullName ?? user.phone} · {membership.role}
        </span>
        <button onClick={logout}>Sign out</button>
      </header>
      {user.doctorProfile?.verificationStatus === 'pending' && membership.role === 'doctor' && (
        <div className="banner">Your licence is awaiting verification. Clinical features unlock once it is approved.</div>
      )}
      {user.doctorProfile?.verificationStatus === 'rejected' && <div className="banner error">Your licence verification was rejected: {user.doctorProfile.verificationNote ?? 'contact support'}.</div>}
      <main>
        <Routes>
          <Route path="/appointments" element={can('appointments.read') ? <AppointmentsPage can={can} /> : <Navigate to="/" />} />
          <Route path="/settings" element={can('staff.manage') ? <SettingsPage /> : <Navigate to="/" />} />
          <Route path="/encounters/:id" element={can('clinical.read') ? <EncounterPage can={can} /> : <Navigate to="/" />} />
          <Route path="/encounters/:id/prescription" element={can('clinical.read') ? <PrescriptionPage /> : <Navigate to="/" />} />
          <Route path="/patients" element={can('patients.read') ? <PatientsPage can={can} /> : <Navigate to="/" />} />
          <Route path="/patients/:id" element={can('patients.read') ? <PatientDetailPage can={can} /> : <Navigate to="/" />} />
          <Route path="/team" element={can('staff.manage') ? <TeamPage /> : <Navigate to="/" />} />
          <Route path="/audit" element={can('audit.read') ? <AuditPage /> : <Navigate to="/" />} />
          <Route
            path="*"
            element={
              <section>
                <h2>Welcome{user.fullName ? `, ${user.fullName}` : ''}</h2>
                <p className="muted">Patients, appointments and encounters arrive in the next features. Your permissions: {membership.permissions.join(', ')}.</p>
              </section>
            }
          />
        </Routes>
      </main>
    </div>
  );
}
