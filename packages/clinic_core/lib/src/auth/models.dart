class DoctorProfile {
  const DoctorProfile({required this.licenseNumber, required this.verificationStatus, this.verificationNote});
  factory DoctorProfile.fromJson(Map<String, dynamic> j) => DoctorProfile(
        licenseNumber: j['licenseNumber'] as String? ?? '',
        verificationStatus: j['verificationStatus'] as String? ?? 'pending',
        verificationNote: j['verificationNote'] as String?,
      );
  final String licenseNumber;
  final String verificationStatus;
  final String? verificationNote;
}

class Me {
  const Me({
    required this.id,
    required this.phone,
    this.fullName,
    this.isPlatformAdmin = false,
    this.mfaEnabled = false,
    this.mfaRequired = false,
    this.doctorProfile,
    this.memberships = const [],
  });

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        id: j['id'] as String,
        phone: j['phone'] as String,
        fullName: j['fullName'] as String?,
        isPlatformAdmin: j['isPlatformAdmin'] as bool? ?? false,
        mfaEnabled: j['mfaEnabled'] as bool? ?? false,
        mfaRequired: j['mfaRequired'] as bool? ?? false,
        doctorProfile: j['doctorProfile'] == null ? null : DoctorProfile.fromJson(j['doctorProfile'] as Map<String, dynamic>),
        memberships: (j['memberships'] as List? ?? const []).cast<Map<String, dynamic>>(),
      );

  final String id;
  final String phone;
  final String? fullName;
  final bool isPlatformAdmin;
  final bool mfaEnabled;
  final bool mfaRequired;
  final DoctorProfile? doctorProfile;
  final List<Map<String, dynamic>> memberships;

  bool get hasName => fullName != null && fullName!.trim().isNotEmpty;
  bool get needsMfaEnrolment => mfaRequired && !mfaEnabled;
}

class SessionInfo {
  const SessionInfo({required this.id, this.deviceName, this.ip, this.createdAt, this.lastUsedAt, this.current = false});
  factory SessionInfo.fromJson(Map<String, dynamic> j) => SessionInfo(
        id: j['id'] as String,
        deviceName: j['deviceName'] as String?,
        ip: j['ip'] as String?,
        createdAt: _date(j['createdAt']),
        lastUsedAt: _date(j['lastUsedAt']),
        current: j['current'] as bool? ?? false,
      );
  final String id;
  final String? deviceName;
  final String? ip;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;
  final bool current;
}

class MfaEnrollment {
  const MfaEnrollment({required this.secret, required this.otpauthUrl});
  factory MfaEnrollment.fromJson(Map<String, dynamic> j) =>
      MfaEnrollment(secret: j['secret'] as String, otpauthUrl: j['otpauthUrl'] as String);
  final String secret;
  final String otpauthUrl;
}

/// Parses an ISO timestamp from the API into local time (null-safe).
DateTime? parseApiDate(Object? v) => _date(v);

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
