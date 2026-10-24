/// Correction requests and retention (apps/api/src/routes/security.ts).
library;

const Map<String, String> correctionTargetLabels = {
  'encounter': 'Consultation',
  'document': 'Document',
  'relationship': 'Registration details',
};

class DataRequest {
  const DataRequest({
    required this.id,
    required this.status,
    required this.targetType,
    required this.targetLabel,
    required this.description,
    required this.patientName,
    required this.patientNumber,
    required this.resolutionNote,
    required this.createdAt,
  });
  factory DataRequest.fromJson(Map<String, dynamic> j) {
    final p = (j['patient'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DataRequest(
      id: j['id'] as String,
      status: j['status'] as String,
      targetType: (j['targetType'] as String?) ?? '',
      targetLabel: j['targetLabel'] as String?,
      description: (j['description'] as String?) ?? '',
      patientName: (p['fullName'] as String?) ?? '',
      patientNumber: (p['patientNumber'] as num?)?.toInt(),
      resolutionNote: j['resolutionNote'] as String?,
      createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '')?.toLocal(),
    );
  }
  final String id;
  final String status; // open | resolved | rejected
  final String targetType;
  final String? targetLabel;
  final String description;
  final String patientName;
  final int? patientNumber;
  final String? resolutionNote;
  final DateTime? createdAt;

  bool get isOpen => status == 'open';
  String get targetText => '${correctionTargetLabels[targetType] ?? targetType}${targetLabel == null ? '' : ' ($targetLabel)'}';
}

class LegalHold {
  const LegalHold({
    required this.patientId,
    required this.fullName,
    required this.patientNumber,
    required this.reason,
    required this.setAt,
  });
  factory LegalHold.fromJson(Map<String, dynamic> j) => LegalHold(
    patientId: j['patientId'] as String,
    fullName: (j['fullName'] as String?) ?? '',
    patientNumber: (j['patientNumber'] as num?)?.toInt(),
    reason: (j['reason'] as String?) ?? '',
    setAt: DateTime.tryParse((j['setAt'] as String?) ?? '')?.toLocal(),
  );
  final String patientId; // care-relationship id
  final String fullName;
  final int? patientNumber;
  final String reason;
  final DateTime? setAt;
}

class Retention {
  const Retention({required this.clinicalRecordYears, required this.auditLogYears, required this.holds});
  factory Retention.fromJson(Map<String, dynamic> j) {
    final p = (j['policy'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Retention(
      clinicalRecordYears: (p['clinicalRecordYears'] as num?)?.toInt() ?? 0,
      auditLogYears: (p['auditLogYears'] as num?)?.toInt() ?? 0,
      holds: ((j['legalHolds'] as List?) ?? const []).cast<Map<String, dynamic>>().map(LegalHold.fromJson).toList(),
    );
  }
  final int clinicalRecordYears;
  final int auditLogYears;
  final List<LegalHold> holds;
}
