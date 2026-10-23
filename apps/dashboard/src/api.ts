const TOKEN_KEY = 'clinic.tokens';

interface Tokens {
  accessToken: string;
  refreshToken: string;
}

export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string, public details?: any) {
    super(message);
  }
}

export const tokens = {
  get(): Tokens | null {
    try {
      return JSON.parse(localStorage.getItem(TOKEN_KEY) ?? 'null');
    } catch {
      return null;
    }
  },
  set(t: Tokens | null) {
    if (t) localStorage.setItem(TOKEN_KEY, JSON.stringify(t));
    else localStorage.removeItem(TOKEN_KEY);
    window.dispatchEvent(new Event('clinic:auth'));
  },
};

let refreshing: Promise<boolean> | null = null;
async function refresh(): Promise<boolean> {
  const t = tokens.get();
  if (!t) return false;
  refreshing ??= fetch('/api/auth/refresh', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ refreshToken: t.refreshToken }),
  })
    .then(async (r) => {
      if (!r.ok) return false;
      tokens.set(await r.json());
      return true;
    })
    .finally(() => (refreshing = null));
  return refreshing;
}

export async function api<T = unknown>(path: string, init: { method?: string; body?: unknown } = {}, retry = true): Promise<T> {
  const t = tokens.get();
  const res = await fetch(`/api${path}`, {
    method: init.method ?? 'GET',
    headers: { ...(init.body ? { 'content-type': 'application/json' } : {}), ...(t ? { authorization: `Bearer ${t.accessToken}` } : {}) },
    body: init.body ? JSON.stringify(init.body) : undefined,
  });
  if (res.status === 401 && retry && t && (await refresh())) return api<T>(path, init, false);
  if (res.status === 401 && t) tokens.set(null);
  if (!res.ok) {
    const e = await res.json().catch(() => ({}));
    throw new ApiError(res.status, e.error ?? 'error', e.message ?? res.statusText, e.details);
  }
  return (res.status === 204 ? undefined : await res.json().catch(() => undefined)) as T;
}

export interface Me {
  id: string;
  phone: string;
  fullName: string | null;
  isPlatformAdmin: boolean;
  doctorProfile: { licenseNumber: string; verificationStatus: 'pending' | 'verified' | 'rejected'; verificationNote: string | null } | null;
  memberships: { id: string; workspaceId: string; workspaceName: string | null; role: 'doctor' | 'nurse' | 'receptionist'; permissions: string[] }[];
}
export interface Member {
  id: string;
  userId: string;
  fullName: string | null;
  phone: string;
  role: 'doctor' | 'nurse' | 'receptionist';
  status: 'active' | 'suspended';
  deniedPermissions: string[];
  permissions: string[];
}
export interface Invitation {
  id: string;
  phone: string;
  role: string;
  expiresAt: string;
}
export interface AuditEntry {
  seq: number;
  action: string;
  actorName: string | null;
  actorRole: string | null;
  metadata: Record<string, unknown>;
  createdAt: string;
}

export interface Patient {
  id: string;
  patientNumber: number;
  fullName: string;
  phone: string;
  dateOfBirth: string | null;
  sex: 'male' | 'female' | null;
  status: 'invited' | 'active' | 'ended';
  hasAccount: boolean;
  createdAt: string;
  endedAt: string | null;
  endedBy: 'workspace' | 'patient' | null;
}

export type AppointmentStatus = 'scheduled' | 'checked_in' | 'in_consultation' | 'completed' | 'cancelled' | 'no_show';
export interface Appointment {
  id: string;
  patient: { id: string; fullName: string; patientNumber: number; phone: string };
  scheduledAt: string;
  durationMinutes: number;
  type: 'new' | 'follow_up';
  isWalkIn: boolean;
  reason: string | null;
  status: AppointmentStatus;
  checkedInAt: string | null;
  cancelReason: string | null;
}
export type WorkingHours = Record<'sun' | 'mon' | 'tue' | 'wed' | 'thu' | 'fri' | 'sat', { start: string; end: string }[]>;
export interface Settings {
  timezone: string;
  slotMinutes: number;
  workingHours: WorkingHours;
}
