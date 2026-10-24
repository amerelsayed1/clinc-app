import 'package:clinic_core/clinic_core.dart';

import 'audit_models.dart';

/// Needs `audit.read`. The members list (for the "who" filter) needs `staff.manage` and is optional.
class AuditApi {
  AuditApi(this.api);
  final ApiClient api;

  static const pageSize = 50;

  /// One page, newest first. Pass the last seen `seq` as [before] for the next page.
  Future<List<AuditEntry>> list(AuditFilters f, {int? before}) async {
    final q = {...f.toQuery(), 'limit': '$pageSize', if (before != null) 'before': '$before'};
    return ((await api.get('/workspace/audit', query: q)) as List).cast<Map<String, dynamic>>().map(AuditEntry.fromJson).toList();
  }

  Future<ChainStatus> verify() async => ChainStatus.fromJson(await api.get('/workspace/audit/verify') as Map<String, dynamic>);

  /// The full export document (itself an audited event). Returned as decoded JSON.
  Future<Object?> export(AuditFilters f) => api.get('/workspace/audit/export', query: f.toQuery());

  Future<List<StaffRef>> staff() async => ((await api.get('/workspace/members')) as List)
      .cast<Map<String, dynamic>>()
      .map((m) => StaffRef(m['userId'] as String, (m['fullName'] as String?) ?? (m['phone'] as String? ?? '')))
      .toList();
}
