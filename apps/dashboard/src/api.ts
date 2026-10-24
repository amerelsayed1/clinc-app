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
    // FormData sets its own multipart content-type (with boundary); everything else is JSON.
    headers: { ...(init.body && !(init.body instanceof FormData) ? { 'content-type': 'application/json' } : {}), ...(t ? { authorization: `Bearer ${t.accessToken}` } : {}) },
    body: init.body ? (init.body instanceof FormData ? init.body : JSON.stringify(init.body)) : undefined,
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
  mfaEnabled: boolean;
  mfaRequired: boolean;
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
  actorId?: string | null;
  actorName: string | null;
  actorRole: string | null;
  targetType?: string | null;
  targetId?: string | null;
  result?: 'success' | 'denied';
  ip?: string | null;
  device?: string | null;
  breakGlass?: boolean;
  metadata: Record<string, unknown>;
  createdAt: string;
}
export interface DataRequest {
  id: string;
  status: 'open' | 'resolved' | 'rejected';
  targetType: 'encounter' | 'document' | 'relationship';
  targetId: string;
  targetLabel: string | null;
  description: string;
  patient: { id: string; fullName: string; patientNumber: number };
  resolutionNote: string | null;
  createdAt: string;
  resolvedAt: string | null;
}
export interface Retention {
  policy: { clinicalRecordYears: number; auditLogYears: number; legalHoldBlocksDeletion: boolean };
  legalHolds: { patientId: string; fullName: string; patientNumber: number; reason: string; setAt: string }[];
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
  encounterId: string | null;
}
export type WorkingHours = Record<'sun' | 'mon' | 'tue' | 'wed' | 'thu' | 'fri' | 'sat', { start: string; end: string }[]>;
export interface Settings {
  timezone: string;
  slotMinutes: number;
  workingHours: WorkingHours;
}

export interface Rx {
  medication: string;
  dose: string;
  frequency: string;
  duration: string;
  notes: string;
}
export interface EncContent {
  chiefComplaint: string;
  history: string;
  diagnosis: string;
  plan: string;
  privateNotes?: string; // absent unless the viewer is the doctor
  prescriptions: Rx[];
}
export interface Observation {
  id: string;
  kind: string;
  value: number;
  unit: string;
  measuredAt: string;
  recordedBy: string;
  recordedByName: string | null;
  recordedRole: string;
  voided: boolean;
  voidReason: string | null;
}
export interface VersionMeta {
  version: number;
  authorName: string | null;
  createdAt: string;
  amendmentReason: string | null;
  changedFields: string[];
}
export interface Encounter {
  id: string;
  patient: { id: string; fullName: string; patientNumber: number };
  appointmentId: string | null;
  author: { id: string; fullName: string | null };
  encounterDate: string;
  status: 'draft' | 'signed';
  revision: number;
  currentVersion: number;
  signedAt: string | null;
  publishedVersion: number | null;
  content: EncContent;
  version: VersionMeta;
  observations: Observation[];
}
export interface EncounterSummary {
  id: string;
  encounterDate: string;
  status: 'draft' | 'signed';
  currentVersion: number;
  published: boolean;
  authorName: string | null;
  chiefComplaint: string;
  diagnosis: string;
}

export interface Doc {
  id: string;
  source: 'clinician' | 'staff' | 'patient';
  provenance: 'clinician_authored' | 'patient_submitted_unverified';
  uploaderName: string | null;
  uploaderRole: string;
  category: string;
  title: string;
  notes: string;
  documentDate: string | null;
  encounterId: string | null;
  totalBytes: number;
  published: boolean;
  createdAt: string;
  pages: { page: number; mime: string; sizeBytes: number }[];
  reviewed?: boolean;
}

// --- Sharing & consent (spec 08) ---
export interface ShareScope {
  items?: { type: 'document' | 'encounter'; id: string }[];
  categories?: string[];
  from?: string;
  to?: string;
}
export interface AccessRequestRow {
  id: string;
  status: 'pending' | 'approved' | 'denied' | 'cancelled' | 'expired';
  scope: ShareScope;
  purpose: string;
  requestedDays: number;
  sensitive: boolean;
  createdAt: string;
  expiresAt: string;
  decidedAt: string | null;
  grantId: string | null;
  clinicName: string;
  doctorName: string;
}
export interface SharedGrant {
  id: string;
  scope: ShareScope;
  purpose: string;
  createdAt: string;
  expiresAt: string;
  patientName: string;
  relationshipId: string | null;
}
export type Provenance = 'clinician_authored' | 'patient_submitted_unverified';
export interface SharedItem {
  type: 'document' | 'encounter';
  id: string;
  category: string;
  date: string;
  title: string;
  source: string;
  clinicName: string | null;
  sharedBy: 'patient';
  provenance: Provenance;
}
export interface SharedEncounter {
  id: string;
  provenance: 'clinician_authored';
  encounterDate: string;
  clinicName: string;
  doctorName: string;
  version: number;
  chiefComplaint: string;
  diagnosis: string;
  plan: string;
  prescriptions: Rx[];
  vitals: { kind: string; value: number; measuredAt: string }[];
}
export interface SharedDocument {
  id: string;
  provenance: Provenance;
  category: string;
  title: string;
  notes: string;
  documentDate: string | null;
  createdAt: string;
  pages: { page: number; mime: string }[];
}

// ---- Follow-up plans (spec 09). Submissions are always patient-reported and never verified. ----
export interface FollowupMeasurement {
  id: string;
  kind: string | null;
  name: string;
  unit: string;
  frequency: 'daily' | 'weekly' | 'custom';
  intervalDays: number;
  active: boolean;
  normalMin: number | null;
  normalMax: number | null;
  lastSubmittedAt?: string | null;
  dueAt?: string | null;
  overdue?: boolean;
}
export interface FollowupSubmission {
  id: string;
  measurementId: string;
  measurementName: string;
  unit: string;
  value: number;
  measuredAt: string;
  note: string;
  documentId: string | null;
  source: 'patient';
  verified: false;
  outsideExpectedRange: boolean;
  flagLabel: string | null;
}
export interface FollowupPlan {
  id: string;
  careRelationshipId: string;
  status: 'active' | 'closed';
  currentVersion: number;
  nextVisitDate: string | null;
  instructions: string;
  startDate: string;
  endDate: string | null;
  closedAt: string | null;
  closeReason: string | null;
  measurements: FollowupMeasurement[];
  submissions?: FollowupSubmission[];
}
export interface FollowupVersion {
  version: number;
  change: 'created' | 'edited' | 'closed';
  editedBy: string;
  at: string;
  snapshot: { plan: Partial<FollowupPlan>; measurements: FollowupMeasurement[] };
}
export interface FollowupTrend {
  measurement: FollowupMeasurement;
  points: { id: string; measuredAt: string; value: number; outsideExpectedRange: boolean }[];
}
export interface AttentionEntry {
  careRelationshipId: string;
  patientName: string;
  items: { planId: string; measurementId: string; measurementName: string; dueAt: string; daysOverdue: number; lastSubmittedAt: string | null }[];
}

export interface TimelineEntry {
  type: 'encounter' | 'prescription' | 'document' | 'observation' | 'followup' | 'appointment' | 'shared_notice';
  id: string;
  refType: string;
  date: string;
  title: string;
  summary: string;
  author: { id: string; name: string } | null;
  source: { kind: 'clinic' | 'patient'; workspaceId: string | null; name: string | null };
  version: number;
  versionCount: number;
  amended: boolean;
  historyPath: string | null;
  verificationBadge: 'clinician_authored' | 'patient_submitted' | 'reviewed';
  shared?: { sharedBy: 'patient'; via: 'grant' | 'send'; grantId: string | null; expiresAt: string | null; originClinic: string | null; label: string };
  details: Record<string, unknown>;
}
export interface TimelinePage {
  items: TimelineEntry[];
  nextCursor: string | null;
}

// ---- Spec 10: notifications ----
export interface NotificationItem {
  id: string;
  type: string;
  title: string;
  body: string;
  data: Record<string, string>;
  createdAt: string;
  read: boolean;
}
export interface NotificationPage {
  items: NotificationItem[];
  nextCursor: string | null;
}
export interface NotificationPreferences {
  locale: 'ar' | 'en';
  channels: ('push' | 'sms')[];
  quietHours: { start: string; end: string; timezone: string } | null;
  timezone: string;
  disabledTypes: string[];
  types: { type: string; mandatory: boolean }[];
  consent: { required: boolean; push: boolean | null; sms: boolean | null };
}
