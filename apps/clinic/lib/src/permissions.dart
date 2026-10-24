/// Permission names, mirroring packages/shared/src/permissions.ts. The API enforces them; the app
/// only uses them to decide what to show.
abstract final class Perm {
  static const patientsRead = 'patients.read';
  static const patientsWrite = 'patients.write';
  static const appointmentsRead = 'appointments.read';
  static const appointmentsManage = 'appointments.manage';
  static const vitalsWrite = 'vitals.write';
  static const documentsUpload = 'documents.upload';
  static const documentsUploadClinical = 'documents.upload_clinical';
  static const clinicalRead = 'clinical.read';
  static const clinicalWrite = 'clinical.write';
  static const followupsWrite = 'followups.write';
  static const relationshipsManage = 'relationships.manage';
  static const staffManage = 'staff.manage';
  static const auditRead = 'audit.read';

  static const all = <String>[
    patientsRead,
    patientsWrite,
    appointmentsRead,
    appointmentsManage,
    vitalsWrite,
    documentsUpload,
    documentsUploadClinical,
    clinicalRead,
    clinicalWrite,
    followupsWrite,
    relationshipsManage,
    staffManage,
    auditRead,
  ];
}

/// Role defaults, mirroring ROLE_DEFAULTS in packages/shared (doctor = everything).
const Map<String, List<String>> roleDefaults = {
  'doctor': Perm.all,
  'nurse': [
    Perm.patientsRead,
    Perm.patientsWrite,
    Perm.appointmentsRead,
    Perm.vitalsWrite,
    Perm.documentsUpload,
    Perm.documentsUploadClinical,
    Perm.clinicalRead,
  ],
  'receptionist': [
    Perm.patientsRead,
    Perm.patientsWrite,
    Perm.appointmentsRead,
    Perm.appointmentsManage,
    Perm.documentsUpload,
  ],
};

String roleLabel(String role) => switch (role) {
      'doctor' => 'Doctor',
      'nurse' => 'Nurse',
      'receptionist' => 'Receptionist',
      _ => role,
    };
