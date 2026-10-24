import 'package:clinic_core/clinic_core.dart';

/// Entry kinds in display order. `label` is shown on filter chips and tiles.
const timelineTypes = <String, String>{
  'encounter': 'Visits',
  'prescription': 'Prescriptions',
  'document': 'Documents',
  'observation': 'Vitals',
  'followup': 'Follow-up',
  'appointment': 'Appointments',
  'shared_notice': 'Sharing',
};

/// Where an entry came from, so a patient can always tell their own uploads from clinician-authored records.
enum Provenance { clinician, patientSubmitted, reviewed }

class TimelineEntry {
  const TimelineEntry({
    required this.type,
    required this.id,
    required this.refType,
    required this.date,
    required this.title,
    required this.summary,
    required this.provenance,
    this.authorName,
    this.clinicName,
    this.workspaceId,
    this.version = 1,
    this.amended = false,
    this.details = const {},
  });

  factory TimelineEntry.fromJson(Map<String, dynamic> j) {
    final source = (j['source'] as Map<String, dynamic>?) ?? const {};
    final author = j['author'] as Map<String, dynamic>?;
    return TimelineEntry(
      type: j['type'] as String,
      id: j['id'] as String,
      refType: j['refType'] as String? ?? '',
      date: parseApiDate(j['date']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      title: j['title'] as String? ?? '',
      summary: j['summary'] as String? ?? '',
      provenance: switch (j['verificationBadge']) {
        'patient_submitted' => Provenance.patientSubmitted,
        'reviewed' => Provenance.reviewed,
        _ => Provenance.clinician,
      },
      authorName: author?['name'] as String?,
      clinicName: source['kind'] == 'clinic' ? source['name'] as String? : null,
      workspaceId: source['workspaceId'] as String?,
      version: (j['version'] as num?)?.toInt() ?? 1,
      amended: j['amended'] == true,
      details: (j['details'] as Map<String, dynamic>?) ?? const {},
    );
  }

  final String type;
  final String id;
  final String refType; // encounter | document | appointment | grant | followup_plan | followup_submission
  final DateTime date;
  final String title;
  final String summary;
  final Provenance provenance;
  final String? authorName;
  final String? clinicName;
  final String? workspaceId;
  final int version;
  final bool amended;
  final Map<String, dynamic> details;

  String get key => '$type:$id';

  String get typeLabel => timelineTypes[type] ?? type;

  /// "Dr. Omar at Nile Clinic", "You uploaded this", etc.
  String get provenanceLabel {
    final parts = [?authorName, ?clinicName].join(' at ');
    return switch (provenance) {
      Provenance.patientSubmitted => clinicName == null ? 'Added by you' : 'Reported by you to $clinicName',
      Provenance.reviewed => 'Added by you, reviewed by a clinician',
      Provenance.clinician => parts.isEmpty ? 'Care team' : parts,
    };
  }

  String get badgeLabel => switch (provenance) {
        Provenance.clinician => 'Clinician-authored',
        Provenance.patientSubmitted => 'Added by you',
        Provenance.reviewed => 'Reviewed by clinician',
      };

  bool get opensEncounter => refType == 'encounter';
  bool get opensDocument => refType == 'document';
}

class TimelineResult {
  const TimelineResult({required this.items, this.nextCursor});
  factory TimelineResult.fromJson(Map<String, dynamic> j) => TimelineResult(
        items: (j['items'] as List).cast<Map<String, dynamic>>().map(TimelineEntry.fromJson).toList(),
        nextCursor: j['nextCursor'] as String?,
      );
  final List<TimelineEntry> items;
  final String? nextCursor;
}

class TimelineFilters {
  const TimelineFilters({this.types = const {}, this.from, this.to, this.query = '', this.workspaceId});
  final Set<String> types;
  final DateTime? from;
  final DateTime? to;
  final String query;
  final String? workspaceId; // a clinic id, or 'patient' for the patient's own uploads

  bool get isEmpty => types.isEmpty && from == null && to == null && query.trim().isEmpty && workspaceId == null;

  TimelineFilters copyWith({Set<String>? types, DateTime? from, DateTime? to, bool clearDates = false, String? query, String? workspaceId, bool clearSource = false}) => TimelineFilters(
        types: types ?? this.types,
        from: clearDates ? null : (from ?? this.from),
        to: clearDates ? null : (to ?? this.to),
        query: query ?? this.query,
        workspaceId: clearSource ? null : (workspaceId ?? this.workspaceId),
      );

  Map<String, String> toQuery({String? cursor, int limit = 30}) => {
        'limit': '$limit',
        if (types.isNotEmpty) 'type': types.join(','),
        if (from != null) 'from': formatDate(from),
        if (to != null) 'to': formatDate(to),
        if (query.trim().isNotEmpty) 'q': query.trim(),
        'source': ?workspaceId,
        'cursor': ?cursor,
      };
}

/// Published consultation as the patient sees it (no history, no private notes).
class EncounterView {
  const EncounterView({required this.id, required this.date, this.clinicName, this.doctorName, this.chiefComplaint = '', this.diagnosis = '', this.plan = '', this.prescriptions = const [], this.vitals = const []});
  factory EncounterView.fromJson(Map<String, dynamic> j) => EncounterView(
        id: j['id'] as String,
        date: parseApiDate(j['encounterDate']),
        clinicName: j['clinicName'] as String?,
        doctorName: j['doctorName'] as String?,
        chiefComplaint: j['chiefComplaint'] as String? ?? '',
        diagnosis: j['diagnosis'] as String? ?? '',
        plan: j['plan'] as String? ?? '',
        prescriptions: ((j['prescriptions'] as List?) ?? const []).cast<Map<String, dynamic>>(),
        vitals: ((j['vitals'] as List?) ?? const []).cast<Map<String, dynamic>>().where((v) => v['voided'] != true).toList(),
      );
  final String id;
  final DateTime? date;
  final String? clinicName;
  final String? doctorName;
  final String chiefComplaint;
  final String diagnosis;
  final String plan;
  final List<Map<String, dynamic>> prescriptions;
  final List<Map<String, dynamic>> vitals;
}

class DocumentView {
  const DocumentView({required this.id, required this.title, required this.category, this.notes = '', this.pageCount = 0, this.fromPatient = false, this.clinicName});
  factory DocumentView.fromJson(Map<String, dynamic> j) => DocumentView(
        id: j['id'] as String,
        title: (j['title'] as String?)?.isNotEmpty == true ? j['title'] as String : (j['category'] as String? ?? 'Document'),
        category: j['category'] as String? ?? 'other',
        notes: j['notes'] as String? ?? '',
        pageCount: ((j['pages'] as List?) ?? const []).length,
        fromPatient: j['source'] == 'patient',
      );
  final String id;
  final String title;
  final String category;
  final String notes;
  final int pageCount;
  final bool fromPatient;
  final String? clinicName;
}
