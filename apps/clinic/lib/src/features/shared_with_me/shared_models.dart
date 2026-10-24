/// Models for patient-shared records and access requests (apps/api/src/routes/sharing.ts).
library;

const Map<String, String> shareCategoryLabels = {
  'encounters': 'Consultations',
  'prescription': 'Prescriptions',
  'lab_result': 'Lab results',
  'imaging': 'Imaging',
  'report': 'Reports',
  'other': 'Other documents',
};

/// Consultation records are sensitive: requests that include them are capped at this many days.
const int sensitiveMaxDays = 14;
const int defaultMaxDays = 90;

DateTime? _dt(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

class ShareScope {
  const ShareScope({this.itemCount, this.categories = const [], this.from, this.to});
  factory ShareScope.fromJson(Map<String, dynamic>? j) {
    j ??= const {};
    final items = j['items'] as List?;
    return ShareScope(
      itemCount: items?.length,
      categories: ((j['categories'] as List?) ?? const []).cast<String>(),
      from: j['from'] as String?,
      to: j['to'] as String?,
    );
  }

  /// Non-null when the grant is per-record ("specific items").
  final int? itemCount;
  final List<String> categories;
  final String? from;
  final String? to;

  bool get includesEncounters => categories.contains('encounters');

  String get text {
    if (itemCount != null) return '$itemCount selected ${itemCount == 1 ? 'record' : 'records'}';
    final cats = categories.map((c) => shareCategoryLabels[c] ?? c).join(', ');
    return from != null || to != null ? '$cats (${from ?? 'any'} to ${to ?? 'any'})' : cats;
  }
}

class SharedGrant {
  const SharedGrant({
    required this.id,
    required this.scope,
    required this.purpose,
    required this.createdAt,
    required this.expiresAt,
    required this.patientName,
  });
  factory SharedGrant.fromJson(Map<String, dynamic> j) => SharedGrant(
    id: j['id'] as String,
    scope: ShareScope.fromJson(j['scope'] as Map<String, dynamic>?),
    purpose: (j['purpose'] as String?) ?? '',
    createdAt: _dt(j['createdAt']),
    expiresAt: _dt(j['expiresAt']),
    patientName: (j['patientName'] as String?) ?? '',
  );
  final String id;
  final ShareScope scope;
  final String purpose;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final String patientName;
}

const clinicianAuthored = 'clinician_authored';
const patientUnverified = 'patient_submitted_unverified';

String provenanceLabel(String p) => p == patientUnverified ? 'Patient-submitted · unverified' : 'Clinician-authored';

class SharedItem {
  const SharedItem({
    required this.type,
    required this.id,
    required this.category,
    required this.date,
    required this.title,
    required this.clinicName,
    required this.provenance,
  });
  factory SharedItem.fromJson(Map<String, dynamic> j) => SharedItem(
    type: j['type'] as String,
    id: j['id'] as String,
    category: (j['category'] as String?) ?? '',
    date: (j['date'] as String?) ?? '',
    title: (j['title'] as String?) ?? '',
    clinicName: j['clinicName'] as String?,
    provenance: (j['provenance'] as String?) ?? patientUnverified,
  );
  final String type; // 'document' | 'encounter'
  final String id;
  final String category;
  final String date;
  final String title;
  final String? clinicName;
  final String provenance;
  bool get isEncounter => type == 'encounter';
  String get categoryLabel => isEncounter ? 'Consultation' : (shareCategoryLabels[category] ?? category);
}

class SharedRx {
  const SharedRx(this.text);
  factory SharedRx.fromJson(Map<String, dynamic> j) {
    final parts = [
      j['medication'],
      j['dose'],
      j['frequency'],
      j['duration'],
      j['notes'],
    ].whereType<String>().where((s) => s.trim().isNotEmpty);
    return SharedRx(parts.join(' · '));
  }
  final String text;
}

class SharedEncounter {
  const SharedEncounter({
    required this.provenance,
    required this.encounterDate,
    required this.clinicName,
    required this.doctorName,
    required this.version,
    required this.chiefComplaint,
    required this.diagnosis,
    required this.plan,
    required this.prescriptions,
    required this.vitals,
  });
  factory SharedEncounter.fromJson(Map<String, dynamic> j) => SharedEncounter(
    provenance: (j['provenance'] as String?) ?? clinicianAuthored,
    encounterDate: (j['encounterDate'] as String?) ?? '',
    clinicName: (j['clinicName'] as String?) ?? '',
    doctorName: (j['doctorName'] as String?) ?? '',
    version: (j['version'] as num?)?.toInt() ?? 1,
    chiefComplaint: (j['chiefComplaint'] as String?) ?? '',
    diagnosis: (j['diagnosis'] as String?) ?? '',
    plan: (j['plan'] as String?) ?? '',
    prescriptions: ((j['prescriptions'] as List?) ?? const []).cast<Map<String, dynamic>>().map(SharedRx.fromJson).toList(),
    vitals: ((j['vitals'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map((v) => '${(v['kind'] as String).replaceAll('_', ' ')}: ${v['value']}')
        .toList(),
  );
  final String provenance;
  final String encounterDate;
  final String clinicName;
  final String doctorName;
  final int version;
  final String chiefComplaint;
  final String diagnosis;
  final String plan;
  final List<SharedRx> prescriptions;
  final List<String> vitals;
}

class SharedDocument {
  const SharedDocument({
    required this.provenance,
    required this.category,
    required this.title,
    required this.notes,
    required this.date,
    required this.pages,
  });
  factory SharedDocument.fromJson(Map<String, dynamic> j) => SharedDocument(
    provenance: (j['provenance'] as String?) ?? patientUnverified,
    category: (j['category'] as String?) ?? '',
    title: (j['title'] as String?) ?? '',
    notes: (j['notes'] as String?) ?? '',
    date: (j['documentDate'] as String?) ?? ((j['createdAt'] as String?) ?? '').split('T').first,
    pages: ((j['pages'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map((p) => (page: (p['page'] as num).toInt(), mime: p['mime'] as String))
        .toList(),
  );
  final String provenance;
  final String category;
  final String title;
  final String notes;
  final String date;
  final List<({int page, String mime})> pages;
}

const Map<String, String> accessRequestStatusLabels = {
  'pending': 'Waiting for patient',
  'approved': 'Approved',
  'denied': 'Denied',
  'cancelled': 'Cancelled',
  'expired': 'Expired',
};

class AccessRequest {
  const AccessRequest({
    required this.id,
    required this.status,
    required this.scope,
    required this.purpose,
    required this.requestedDays,
    required this.sensitive,
    required this.createdAt,
    required this.doctorName,
  });
  factory AccessRequest.fromJson(Map<String, dynamic> j) => AccessRequest(
    id: j['id'] as String,
    status: j['status'] as String,
    scope: ShareScope.fromJson(j['scope'] as Map<String, dynamic>?),
    purpose: (j['purpose'] as String?) ?? '',
    requestedDays: (j['requestedDays'] as num?)?.toInt() ?? 0,
    sensitive: j['sensitive'] == true,
    createdAt: _dt(j['createdAt']),
    doctorName: (j['doctorName'] as String?) ?? '',
  );
  final String id;
  final String status;
  final ShareScope scope;
  final String purpose;
  final int requestedDays;
  final bool sensitive;
  final DateTime? createdAt;
  final String doctorName;
  String get statusLabel => accessRequestStatusLabels[status] ?? status;
  bool get isPending => status == 'pending';
}

/// Max days for a request: 14 when consultations are included (sensitive), otherwise 90.
int maxDaysFor(Iterable<String> categories) => categories.contains('encounters') ? sensitiveMaxDays : defaultMaxDays;

/// Body of POST /patients/:id/access-requests. Category scope only (the dashboard's form); [from]/[to]
/// are `YYYY-MM-DD` and omitted when empty. Days are clamped to the sensitive cap when consultations are included.
Map<String, Object?> buildAccessRequestBody({
  required List<String> categories,
  required String purpose,
  required int days,
  String? from,
  String? to,
}) => {
  'scope': {'categories': categories, if (from != null && from.isNotEmpty) 'from': from, if (to != null && to.isNotEmpty) 'to': to},
  'purpose': purpose.trim(),
  'days': days.clamp(1, maxDaysFor(categories)),
};
