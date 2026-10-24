/// Audit log models and filters (apps/api/src/audit.ts, routes/workspaces.ts).
library;

import 'dart:convert';

const List<(String, String)> auditActionGroups = [
  ('', 'All actions'),
  ('encounter.', 'Encounters'),
  ('patient.', 'Patient records'),
  ('document.', 'Documents'),
  ('shared_item.', 'Shared records'),
  ('grant.', 'Sharing grants'),
  ('member.', 'Staff and permissions'),
  ('invitation.', 'Invitations'),
  ('auth.', 'Sign-in and security'),
  ('correction.', 'Correction requests'),
  ('audit.', 'Audit exports'),
  ('access.denied', 'Denied attempts'),
  ('breakglass.', 'Platform break-glass'),
];

class AuditEntry {
  const AuditEntry({
    required this.seq,
    required this.action,
    required this.actorName,
    required this.actorRole,
    required this.targetType,
    required this.targetId,
    required this.result,
    required this.ip,
    required this.device,
    required this.breakGlass,
    required this.metadata,
    required this.createdAt,
  });
  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
    seq: (j['seq'] as num).toInt(),
    action: j['action'] as String,
    actorName: j['actorName'] as String?,
    actorRole: j['actorRole'] as String?,
    targetType: j['targetType'] as String?,
    targetId: j['targetId'] as String?,
    result: (j['result'] as String?) ?? 'success',
    ip: j['ip'] as String?,
    device: j['device'] as String?,
    breakGlass: j['breakGlass'] == true,
    metadata: (j['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
    createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '')?.toLocal(),
  );

  final int seq;
  final String action;
  final String? actorName;
  final String? actorRole;
  final String? targetType;
  final String? targetId;
  final String result;
  final String? ip;
  final String? device;
  final bool breakGlass;
  final Map<String, dynamic> metadata;
  final DateTime? createdAt;

  bool get denied => result == 'denied';
  String get actorLabel =>
      '${actorName ?? '-'}${actorRole == null ? '' : ' (${actorRole == 'platform_admin' ? 'platform support' : actorRole})'}';

  /// Break-glass entries show the written justification; others a compact JSON of the metadata.
  String get details {
    final j = metadata['justification'];
    if (breakGlass && j is String) return 'Reason: $j';
    return metadata.isEmpty ? '' : jsonEncode(metadata);
  }
}

class AuditFilters {
  const AuditFilters({this.action = '', this.actor = '', this.from = '', this.to = '', this.result = '', this.targetId = ''});
  final String action;
  final String actor;
  final String from; // YYYY-MM-DD
  final String to;
  final String result; // '', 'success', 'denied'
  final String targetId;

  bool get isEmpty => action.isEmpty && actor.isEmpty && from.isEmpty && to.isEmpty && result.isEmpty && targetId.isEmpty;
  int get activeCount => [action, actor, from, to, result, targetId].where((s) => s.isNotEmpty).length;

  AuditFilters copyWith({String? action, String? actor, String? from, String? to, String? result, String? targetId}) => AuditFilters(
    action: action ?? this.action,
    actor: actor ?? this.actor,
    from: from ?? this.from,
    to: to ?? this.to,
    result: result ?? this.result,
    targetId: targetId ?? this.targetId,
  );

  /// Query-string map for GET /workspace/audit[/export]; empty filters are omitted.
  Map<String, String> toQuery() => {
    if (action.isNotEmpty) 'action': action,
    if (actor.isNotEmpty) 'actor': actor,
    if (from.isNotEmpty) 'from': from,
    if (to.isNotEmpty) 'to': to,
    if (result.isNotEmpty) 'result': result,
    if (targetId.isNotEmpty) 'targetId': targetId.trim(),
  };
}

class ChainStatus {
  const ChainStatus({required this.valid, required this.checked, this.brokenAtSeq});
  factory ChainStatus.fromJson(Map<String, dynamic> j) => ChainStatus(
    valid: j['valid'] == true,
    checked: (j['checked'] as num?)?.toInt() ?? 0,
    brokenAtSeq: (j['brokenAtSeq'] as num?)?.toInt(),
  );
  final bool valid;
  final int checked;
  final int? brokenAtSeq;
}

class StaffRef {
  const StaffRef(this.userId, this.label);
  final String userId;
  final String label;
}
