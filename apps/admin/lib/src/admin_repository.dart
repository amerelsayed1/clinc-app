import 'package:clinic_core/clinic_core.dart';

class DoctorApplication {
  const DoctorApplication({
    required this.userId,
    this.fullName,
    required this.phone,
    required this.licenseNumber,
    required this.status,
    this.createdAt,
  });

  factory DoctorApplication.fromJson(Map<String, dynamic> j) => DoctorApplication(
        userId: j['userId'] as String,
        fullName: j['fullName'] as String?,
        phone: j['phone'] as String? ?? '',
        licenseNumber: j['licenseNumber'] as String? ?? '',
        status: j['status'] as String? ?? 'pending',
        createdAt: parseApiDate(j['createdAt']),
      );

  final String userId;
  final String? fullName;
  final String phone;
  final String licenseNumber;
  final String status; // pending | verified | rejected
  final DateTime? createdAt;

  String get displayName => (fullName == null || fullName!.trim().isEmpty) ? 'Unnamed doctor' : fullName!;
}

/// Platform-admin endpoints (require isPlatformAdmin on the server).
class AdminRepository {
  AdminRepository(this.api);
  final ApiClient api;

  Future<List<DoctorApplication>> doctors(String status) async {
    final json = await api.get('/admin/doctors', query: {'status': status});
    return (json as List).cast<Map<String, dynamic>>().map(DoctorApplication.fromJson).toList();
  }

  Future<void> decide(String userId, {required bool verify, String? note}) => api.post(
        '/admin/doctors/$userId/decision',
        body: {'decision': verify ? 'verified' : 'rejected', if (note != null && note.trim().isNotEmpty) 'note': note.trim()},
      );

  // --- Audit and break-glass (spec 11) ---

  Future<List<WorkspaceSummary>> workspaces() async =>
      ((await api.get('/admin/workspaces')) as List).cast<Map<String, dynamic>>().map(WorkspaceSummary.fromJson).toList();

  /// Verifies every audit hash chain now. The server records the run.
  Future<ChainVerification> verifyAudit() async => ChainVerification.fromJson(await api.get('/admin/audit/verify') as Map<String, dynamic>);

  Future<List<ChainVerification>> verifications() async =>
      ((await api.get('/admin/audit/verifications')) as List).cast<Map<String, dynamic>>().map(ChainVerification.fromJson).toList();

  Future<List<BreakGlassAccess>> breakGlassAccess() async =>
      ((await api.get('/admin/break-glass')) as List).cast<Map<String, dynamic>>().map(BreakGlassAccess.fromJson).toList();

  /// Opens time-boxed access to one clinic's audit log. The justification is stored in that clinic's own audit log.
  Future<void> grantBreakGlass({required String workspaceId, required String justification, required int minutes}) =>
      api.post('/admin/break-glass', body: {'workspaceId': workspaceId, 'justification': justification.trim(), 'minutes': minutes});

  Future<void> revokeBreakGlass(String id) => api.delete('/admin/break-glass/$id');

  Future<List<AuditRow>> workspaceAudit(String workspaceId, {String? action}) async {
    final json = await api.get('/admin/workspaces/$workspaceId/audit', query: {'limit': '100', if (action != null && action.isNotEmpty) 'action': action}) as Map<String, dynamic>;
    return (json['entries'] as List).cast<Map<String, dynamic>>().map(AuditRow.fromJson).toList();
  }
}

class WorkspaceSummary {
  const WorkspaceSummary({required this.id, required this.name, required this.ownerName});
  factory WorkspaceSummary.fromJson(Map<String, dynamic> j) =>
      WorkspaceSummary(id: j['id'] as String, name: (j['name'] as String?)?.trim().isNotEmpty == true ? j['name'] as String : 'Unnamed clinic', ownerName: j['ownerName'] as String? ?? '');
  final String id;
  final String name;
  final String ownerName;
}

class ChainVerification {
  const ChainVerification({required this.valid, required this.chainsChecked, required this.entriesChecked, required this.broken, this.ranAt});
  factory ChainVerification.fromJson(Map<String, dynamic> j) => ChainVerification(
        valid: j['valid'] == true,
        chainsChecked: (j['chainsChecked'] as num?)?.toInt() ?? 0,
        entriesChecked: (j['entriesChecked'] as num?)?.toInt() ?? 0,
        broken: ((j['chains'] ?? j['broken'] ?? const []) as List).cast<Map<String, dynamic>>().where((c) => c['valid'] != true).map((c) => '${c['chainKey']} (entry #${c['brokenAtSeq']})').toList(),
        ranAt: parseApiDate(j['ranAt']),
      );
  final bool valid;
  final int chainsChecked;
  final int entriesChecked;
  final List<String> broken; // chain keys that failed
  final DateTime? ranAt;
}

class BreakGlassAccess {
  const BreakGlassAccess({required this.id, required this.workspaceId, required this.workspaceName, required this.justification, required this.expiresAt, required this.active});
  factory BreakGlassAccess.fromJson(Map<String, dynamic> j) => BreakGlassAccess(
        id: j['id'] as String,
        workspaceId: j['workspaceId'] as String,
        workspaceName: j['workspaceName'] as String? ?? '',
        justification: j['justification'] as String? ?? '',
        expiresAt: parseApiDate(j['expiresAt']),
        active: j['active'] == true,
      );
  final String id;
  final String workspaceId;
  final String workspaceName;
  final String justification;
  final DateTime? expiresAt;
  final bool active;
}

class AuditRow {
  const AuditRow({required this.seq, required this.action, required this.actor, required this.result, required this.at, required this.breakGlass});
  factory AuditRow.fromJson(Map<String, dynamic> j) => AuditRow(
        seq: (j['seq'] as num).toInt(),
        action: j['action'] as String,
        actor: [j['actorName'], j['actorRole']].whereType<String>().join(' · '),
        result: j['result'] as String? ?? 'success',
        at: parseApiDate(j['createdAt']),
        breakGlass: j['breakGlass'] == true,
      );
  final int seq;
  final String action;
  final String actor;
  final String result;
  final DateTime? at;
  final bool breakGlass;
}
