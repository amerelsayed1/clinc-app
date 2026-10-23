// Default permission bundles per spec 02. Roles are defaults, not blanket access:
// a doctor can deny individual permissions per staff member.

export const ROLES = ['doctor', 'nurse', 'receptionist'] as const;
export type Role = (typeof ROLES)[number];
export type StaffRole = Exclude<Role, 'doctor'>;

export const PERMISSIONS = [
  'patients.read',
  'patients.write',
  'appointments.manage',
  'vitals.write',
  'documents.upload',
  'clinical.read',
  'clinical.write', // encounters, diagnoses, prescriptions, signing
  'followups.write',
  'staff.manage',
  'audit.read',
] as const;
export type Permission = (typeof PERMISSIONS)[number];

export const ROLE_DEFAULTS: Record<Role, readonly Permission[]> = {
  doctor: PERMISSIONS,
  nurse: ['patients.read', 'patients.write', 'vitals.write', 'documents.upload', 'clinical.read'],
  receptionist: ['patients.read', 'patients.write', 'appointments.manage', 'documents.upload'],
};

// Actions that need a credential-verified doctor (spec 01, F01-3).
const REQUIRES_VERIFIED_DOCTOR: readonly Permission[] = ['clinical.write', 'followups.write'];

export function effectivePermissions(input: {
  role: Role;
  denied: readonly string[];
  doctorVerified: boolean;
}): Permission[] {
  const { role, denied, doctorVerified } = input;
  return ROLE_DEFAULTS[role].filter((p) => {
    // The workspace owner cannot be locked out of their own workspace.
    if (role !== 'doctor' && denied.includes(p)) return false;
    if (role === 'doctor' && !doctorVerified && REQUIRES_VERIFIED_DOCTOR.includes(p)) return false;
    return true;
  });
}
