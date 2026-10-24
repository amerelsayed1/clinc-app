import 'package:clinic_core/clinic_core.dart';

import '../../permissions.dart';

class Member {
  const Member({
    required this.id,
    required this.userId,
    required this.phone,
    required this.role,
    required this.status,
    this.fullName,
    this.deniedPermissions = const [],
    this.permissions = const [],
  });

  factory Member.fromJson(Map<String, dynamic> j) => Member(
        id: j['id'] as String,
        userId: j['userId'] as String? ?? '',
        fullName: j['fullName'] as String?,
        phone: j['phone'] as String? ?? '',
        role: j['role'] as String,
        status: j['status'] as String? ?? 'active',
        deniedPermissions: (j['deniedPermissions'] as List? ?? const []).cast<String>(),
        permissions: (j['permissions'] as List? ?? const []).cast<String>(),
      );

  final String id;
  final String userId;
  final String? fullName;
  final String phone;
  final String role; // doctor | nurse | receptionist
  final String status; // active | suspended
  final List<String> deniedPermissions;
  final List<String> permissions;

  bool get isOwner => role == 'doctor';
  bool get isActive => status == 'active';
  String get displayName => (fullName == null || fullName!.trim().isEmpty) ? phone : fullName!;

  /// Permissions the owner can switch on/off for this member: exactly the role's defaults.
  List<String> get grantable => isOwner ? const [] : roleDefaults[role] ?? const [];

  /// New deny list after switching [permission] on/off (on = not denied). Duplicates are never added.
  List<String> deniedAfterToggle(String permission, {required bool allowed}) {
    final without = deniedPermissions.where((d) => d != permission).toList();
    return allowed ? without : [...without, permission];
  }
}

class Invitation {
  const Invitation({required this.id, required this.phone, required this.role, this.expiresAt});
  factory Invitation.fromJson(Map<String, dynamic> j) => Invitation(
        id: j['id'] as String,
        phone: j['phone'] as String,
        role: j['role'] as String,
        expiresAt: parseApiDate(j['expiresAt']),
      );
  final String id;
  final String phone;
  final String role;
  final DateTime? expiresAt;
}

class IssuedInvitation {
  const IssuedInvitation({required this.id, required this.code, this.expiresAt});
  factory IssuedInvitation.fromJson(Map<String, dynamic> j) =>
      IssuedInvitation(id: j['id'] as String, code: j['code'] as String, expiresAt: parseApiDate(j['expiresAt']));
  final String id;

  /// Shown once; the server only keeps its hash.
  final String code;
  final DateTime? expiresAt;
}
