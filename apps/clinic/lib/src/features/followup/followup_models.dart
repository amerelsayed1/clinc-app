/// Wording required by spec 09: a neutral flag, never a clinical conclusion or a verified finding.
const followupFlagText = 'patient-reported, outside expected range';

/// Same list as VITAL_KINDS in packages/shared (key, label, unit).
const vitalKinds = <(String, String, String)>[
  ('weight_kg', 'Weight', 'kg'),
  ('height_cm', 'Height', 'cm'),
  ('systolic_bp', 'Systolic BP', 'mmHg'),
  ('diastolic_bp', 'Diastolic BP', 'mmHg'),
  ('heart_rate', 'Heart rate', 'bpm'),
  ('resp_rate', 'Respiratory rate', '/min'),
  ('temperature_c', 'Temperature', '°C'),
  ('spo2', 'SpO₂', '%'),
  ('glucose_mg_dl', 'Blood glucose', 'mg/dL'),
];

double? _num(Object? v) => v == null ? null : (v as num).toDouble();

String fmtNum(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

class FollowupMeasurement {
  const FollowupMeasurement({
    required this.id,
    required this.name,
    required this.unit,
    required this.frequency,
    required this.intervalDays,
    required this.active,
    this.kind,
    this.normalMin,
    this.normalMax,
    this.overdue = false,
  });
  final String id;
  final String? kind;
  final String name;
  final String unit;
  final String frequency; // daily | weekly | custom
  final int intervalDays;
  final bool active;
  final double? normalMin;
  final double? normalMax;
  final bool overdue;

  String get frequencyLabel => frequency == 'custom' ? 'every $intervalDays days' : frequency;
  bool get hasRange => normalMin != null || normalMax != null;

  factory FollowupMeasurement.fromJson(Map<String, dynamic> j) => FollowupMeasurement(
        id: j['id'] as String,
        kind: j['kind'] as String?,
        name: (j['name'] ?? '') as String,
        unit: (j['unit'] ?? '') as String,
        frequency: (j['frequency'] ?? 'daily') as String,
        intervalDays: ((j['intervalDays'] ?? 1) as num).toInt(),
        active: (j['active'] ?? true) as bool,
        normalMin: _num(j['normalMin']),
        normalMax: _num(j['normalMax']),
        overdue: (j['overdue'] ?? false) as bool,
      );
}

class FollowupSubmission {
  const FollowupSubmission({required this.id, required this.measurementName, required this.unit, required this.value, required this.measuredAt, required this.note, required this.outsideExpectedRange, this.documentId});
  final String id;
  final String measurementName;
  final String unit;
  final double value;
  final String measuredAt;
  final String note;
  final bool outsideExpectedRange;
  final String? documentId;

  factory FollowupSubmission.fromJson(Map<String, dynamic> j) => FollowupSubmission(
        id: j['id'] as String,
        measurementName: (j['measurementName'] ?? '') as String,
        unit: (j['unit'] ?? '') as String,
        value: (j['value'] as num).toDouble(),
        measuredAt: (j['measuredAt'] ?? '') as String,
        note: (j['note'] ?? '') as String,
        outsideExpectedRange: (j['outsideExpectedRange'] ?? false) as bool,
        documentId: j['documentId'] as String?,
      );
}

class FollowupPlan {
  const FollowupPlan({
    required this.id,
    required this.careRelationshipId,
    required this.status,
    required this.currentVersion,
    required this.instructions,
    required this.startDate,
    required this.measurements,
    this.nextVisitDate,
    this.endDate,
    this.closeReason,
    this.submissions = const [],
  });
  final String id;
  final String careRelationshipId;
  final String status;
  final int currentVersion;
  final String instructions;
  final String startDate;
  final String? nextVisitDate;
  final String? endDate;
  final String? closeReason;
  final List<FollowupMeasurement> measurements;
  final List<FollowupSubmission> submissions;

  bool get isActive => status == 'active';
  List<FollowupMeasurement> get activeMeasurements => measurements.where((m) => m.active).toList();

  factory FollowupPlan.fromJson(Map<String, dynamic> j) => FollowupPlan(
        id: j['id'] as String,
        careRelationshipId: (j['careRelationshipId'] ?? '') as String,
        status: (j['status'] ?? 'active') as String,
        currentVersion: ((j['currentVersion'] ?? 1) as num).toInt(),
        instructions: (j['instructions'] ?? '') as String,
        startDate: (j['startDate'] ?? '') as String,
        nextVisitDate: j['nextVisitDate'] as String?,
        endDate: j['endDate'] as String?,
        closeReason: j['closeReason'] as String?,
        measurements: ((j['measurements'] as List?) ?? const []).cast<Map<String, dynamic>>().map(FollowupMeasurement.fromJson).toList(),
        submissions: ((j['submissions'] as List?) ?? const []).cast<Map<String, dynamic>>().map(FollowupSubmission.fromJson).toList(),
      );
}

class TrendPoint {
  const TrendPoint({required this.measuredAt, required this.value, required this.outside});
  final DateTime measuredAt;
  final double value;
  final bool outside;
}

class FollowupVersion {
  const FollowupVersion({required this.version, required this.change, required this.editedBy, required this.at, required this.instructions, required this.measurementNames});
  final int version;
  final String change;
  final String editedBy;
  final String at;
  final String instructions;
  final List<String> measurementNames;

  factory FollowupVersion.fromJson(Map<String, dynamic> j) {
    final snap = (j['snapshot'] as Map?)?.cast<String, dynamic>() ?? const {};
    final plan = (snap['plan'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ms = ((snap['measurements'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return FollowupVersion(
      version: (j['version'] as num).toInt(),
      change: (j['change'] ?? '') as String,
      editedBy: (j['editedBy'] ?? '') as String,
      at: (j['at'] ?? '') as String,
      instructions: (plan['instructions'] ?? '') as String,
      measurementNames: [for (final m in ms) if (m['active'] != false) (m['name'] ?? '') as String],
    );
  }
}

class AttentionItem {
  const AttentionItem({required this.measurementName, required this.daysOverdue});
  final String measurementName;
  final int daysOverdue;
}

class AttentionEntry {
  const AttentionEntry({required this.careRelationshipId, required this.patientName, required this.items});
  final String careRelationshipId;
  final String patientName;
  final List<AttentionItem> items;

  factory AttentionEntry.fromJson(Map<String, dynamic> j) => AttentionEntry(
        careRelationshipId: j['careRelationshipId'] as String,
        patientName: (j['patientName'] ?? '') as String,
        items: [
          for (final i in ((j['items'] as List?) ?? const []).cast<Map<String, dynamic>>())
            AttentionItem(measurementName: (i['measurementName'] ?? '') as String, daysOverdue: ((i['daysOverdue'] ?? 0) as num).toInt()),
        ],
      );
}

/// Editable row of the plan form.
class MeasurementDraft {
  MeasurementDraft({this.id, this.kind = 'heart_rate', this.name = '', this.unit = '', this.frequency = 'daily', this.intervalDays = '2', this.normalMin = '', this.normalMax = ''});
  String? id;
  String kind; // '' = custom
  String name;
  String unit;
  String frequency;
  String intervalDays;
  String normalMin;
  String normalMax;

  factory MeasurementDraft.of(FollowupMeasurement m) => MeasurementDraft(
        id: m.id,
        kind: m.kind ?? '',
        name: m.kind != null ? '' : m.name,
        unit: m.kind != null ? '' : m.unit,
        frequency: m.frequency,
        intervalDays: '${m.intervalDays}',
        normalMin: m.normalMin == null ? '' : fmtNum(m.normalMin!),
        normalMax: m.normalMax == null ? '' : fmtNum(m.normalMax!),
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        if (kind.isNotEmpty) 'kind': kind else 'name': name.trim(),
        if (kind.isEmpty && unit.trim().isNotEmpty) 'unit': unit.trim(),
        'frequency': frequency,
        if (frequency == 'custom') 'intervalDays': int.tryParse(intervalDays) ?? 1,
        'normalMin': normalMin.trim().isEmpty ? null : double.tryParse(normalMin.trim()),
        'normalMax': normalMax.trim().isEmpty ? null : double.tryParse(normalMax.trim()),
      };
}
