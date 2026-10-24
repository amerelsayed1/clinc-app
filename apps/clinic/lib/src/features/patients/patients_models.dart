import 'package:clinic_core/clinic_core.dart';

String patientNo(int n) => 'P-${n.toString().padLeft(5, '0')}';

String statusLabel(String status) => switch (status) {
      'active' => 'Active',
      'invited' => 'Awaiting patient confirmation',
      'ended' => 'Ended',
      _ => status,
    };

class Patient {
  const Patient({
    required this.id,
    required this.patientNumber,
    required this.fullName,
    required this.phone,
    required this.status,
    this.dateOfBirth,
    this.sex,
    this.hasAccount = false,
    this.createdAt,
    this.endedAt,
    this.endedBy,
  });

  factory Patient.fromJson(Map<String, dynamic> j) => Patient(
        id: j['id'] as String,
        patientNumber: (j['patientNumber'] as num?)?.toInt() ?? 0,
        fullName: j['fullName'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
        dateOfBirth: j['dateOfBirth'] as String?,
        sex: j['sex'] as String?,
        status: j['status'] as String? ?? 'active',
        hasAccount: j['hasAccount'] as bool? ?? false,
        createdAt: parseApiDate(j['createdAt']),
        endedAt: parseApiDate(j['endedAt']),
        endedBy: j['endedBy'] as String?,
      );

  final String id; // care relationship id
  final int patientNumber;
  final String fullName;
  final String phone;
  final String? dateOfBirth; // YYYY-MM-DD
  final String? sex; // male | female
  final String status; // active | invited | ended
  final bool hasAccount;
  final DateTime? createdAt;
  final DateTime? endedAt;
  final String? endedBy;

  bool get isEnded => status == 'ended';
}

class Rx {
  const Rx({this.medication = '', this.dose = '', this.frequency = '', this.duration = '', this.notes = ''});
  factory Rx.fromJson(Map<String, dynamic> j) => Rx(
        medication: j['medication'] as String? ?? '',
        dose: j['dose'] as String? ?? '',
        frequency: j['frequency'] as String? ?? '',
        duration: j['duration'] as String? ?? '',
        notes: j['notes'] as String? ?? '',
      );
  final String medication;
  final String dose;
  final String frequency;
  final String duration;
  final String notes;

  Map<String, String> toJson() => {'medication': medication.trim(), 'dose': dose.trim(), 'frequency': frequency.trim(), 'duration': duration.trim(), 'notes': notes.trim()};

  bool get isBlank => medication.trim().isEmpty && dose.trim().isEmpty && frequency.trim().isEmpty && duration.trim().isEmpty && notes.trim().isEmpty;

  @override
  bool operator ==(Object other) => other is Rx && other.toString() == toString();
  @override
  int get hashCode => toString().hashCode;
  @override
  String toString() => 'Rx($medication|$dose|$frequency|$duration|$notes)';
}

class EncContent {
  const EncContent({
    this.chiefComplaint = '',
    this.history = '',
    this.diagnosis = '',
    this.plan = '',
    this.privateNotes,
    this.prescriptions = const [],
  });

  factory EncContent.fromJson(Map<String, dynamic> j) => EncContent(
        chiefComplaint: j['chiefComplaint'] as String? ?? '',
        history: j['history'] as String? ?? '',
        diagnosis: j['diagnosis'] as String? ?? '',
        plan: j['plan'] as String? ?? '',
        privateNotes: j['privateNotes'] as String?,
        prescriptions: [for (final r in (j['prescriptions'] as List? ?? const [])) Rx.fromJson(r as Map<String, dynamic>)],
      );

  final String chiefComplaint;
  final String history;
  final String diagnosis;
  final String plan;

  /// Absent unless the viewer is the doctor.
  final String? privateNotes;
  final List<Rx> prescriptions;

  /// Rows without a medication name are not sent (the API requires one; the row is still being typed).
  List<Rx> get sendablePrescriptions => prescriptions.where((r) => r.medication.trim().isNotEmpty).toList();

  /// True when a row has details but no medication name.
  bool get hasIncompletePrescription => prescriptions.any((r) => r.medication.trim().isEmpty && !r.isBlank);

  EncContent copyWith({String? chiefComplaint, String? history, String? diagnosis, String? plan, String? privateNotes, List<Rx>? prescriptions}) => EncContent(
        chiefComplaint: chiefComplaint ?? this.chiefComplaint,
        history: history ?? this.history,
        diagnosis: diagnosis ?? this.diagnosis,
        plan: plan ?? this.plan,
        privateNotes: privateNotes ?? this.privateNotes,
        prescriptions: prescriptions ?? this.prescriptions,
      );

  /// Body for `PATCH /encounters/:id` (without revision). Private notes only when [includePrivate].
  Map<String, dynamic> toDraftJson({required bool includePrivate}) => {
        'chiefComplaint': chiefComplaint,
        'history': history,
        'diagnosis': diagnosis,
        'plan': plan,
        if (includePrivate) 'privateNotes': privateNotes ?? '',
        'prescriptions': [for (final r in sendablePrescriptions) r.toJson()],
      };

  /// Only the fields that differ from [before] (so the recorded amendment field list is accurate).
  Map<String, dynamic> changesFrom(EncContent before, {required bool includePrivate}) => {
        if (chiefComplaint != before.chiefComplaint) 'chiefComplaint': chiefComplaint,
        if (history != before.history) 'history': history,
        if (diagnosis != before.diagnosis) 'diagnosis': diagnosis,
        if (plan != before.plan) 'plan': plan,
        if (includePrivate && (privateNotes ?? '') != (before.privateNotes ?? '')) 'privateNotes': privateNotes ?? '',
        if (!_sameRx(sendablePrescriptions, before.prescriptions)) 'prescriptions': [for (final r in sendablePrescriptions) r.toJson()],
      };

  static bool _sameRx(List<Rx> a, List<Rx> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].toJson().toString() != b[i].toJson().toString()) return false;
    }
    return true;
  }
}

class Observation {
  const Observation({
    required this.id,
    required this.kind,
    required this.value,
    required this.unit,
    required this.recordedBy,
    required this.recordedRole,
    this.recordedByName,
    this.measuredAt,
    this.voided = false,
    this.voidReason,
  });

  factory Observation.fromJson(Map<String, dynamic> j) => Observation(
        id: j['id'] as String,
        kind: j['kind'] as String,
        value: (j['value'] as num).toDouble(),
        unit: j['unit'] as String? ?? vitalKinds[j['kind']]?.unit ?? '',
        recordedBy: j['recordedBy'] as String? ?? '',
        recordedByName: j['recordedByName'] as String?,
        recordedRole: j['recordedRole'] as String? ?? '',
        measuredAt: parseApiDate(j['measuredAt']),
        voided: j['voided'] as bool? ?? false,
        voidReason: j['voidReason'] as String?,
      );

  final String id;
  final String kind;
  final double value;
  final String unit;
  final String recordedBy;
  final String? recordedByName;
  final String recordedRole;
  final DateTime? measuredAt;
  final bool voided;
  final String? voidReason;

  String get label => vitalKinds[kind]?.label ?? kind;
  String get valueText => value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();
}

class VitalKind {
  const VitalKind(this.label, this.unit, this.min, this.max);
  final String label;
  final String unit;
  final double min;
  final double max;
}

/// Mirrors packages/shared/src/vitals.ts (plausibility bounds only catch typing mistakes).
const vitalKinds = <String, VitalKind>{
  'weight_kg': VitalKind('Weight', 'kg', 0.3, 500),
  'height_cm': VitalKind('Height', 'cm', 20, 260),
  'systolic_bp': VitalKind('Systolic BP', 'mmHg', 40, 300),
  'diastolic_bp': VitalKind('Diastolic BP', 'mmHg', 20, 200),
  'heart_rate': VitalKind('Heart rate', 'bpm', 20, 300),
  'resp_rate': VitalKind('Respiratory rate', '/min', 4, 80),
  'temperature_c': VitalKind('Temperature', '°C', 25, 45),
  'spo2': VitalKind('SpO₂', '%', 30, 100),
  'glucose_mg_dl': VitalKind('Blood glucose', 'mg/dL', 10, 1500),
};

class VersionMeta {
  const VersionMeta({required this.version, this.authorName, this.createdAt, this.amendmentReason, this.changedFields = const []});
  factory VersionMeta.fromJson(Map<String, dynamic> j) => VersionMeta(
        version: (j['version'] as num).toInt(),
        authorName: j['authorName'] as String?,
        createdAt: parseApiDate(j['createdAt']),
        amendmentReason: j['amendmentReason'] as String?,
        changedFields: (j['changedFields'] as List? ?? const []).cast<String>(),
      );
  final int version;
  final String? authorName;
  final DateTime? createdAt;
  final String? amendmentReason;
  final List<String> changedFields;
}

class EncVersion {
  const EncVersion({required this.meta, required this.content});
  factory EncVersion.fromJson(Map<String, dynamic> j) =>
      EncVersion(meta: VersionMeta.fromJson(j), content: EncContent.fromJson((j['content'] as Map).cast<String, dynamic>()));
  final VersionMeta meta;
  final EncContent content;
}

class Encounter {
  const Encounter({
    required this.id,
    required this.patientId,
    required this.patientName,
    required this.patientNumber,
    required this.authorId,
    required this.status,
    required this.revision,
    required this.currentVersion,
    required this.content,
    required this.version,
    this.authorName,
    this.appointmentId,
    this.encounterDate,
    this.publishedVersion,
    this.observations = const [],
  });

  factory Encounter.fromJson(Map<String, dynamic> j) {
    final patient = (j['patient'] as Map).cast<String, dynamic>();
    final author = (j['author'] as Map).cast<String, dynamic>();
    return Encounter(
      id: j['id'] as String,
      patientId: patient['id'] as String,
      patientName: patient['fullName'] as String? ?? '',
      patientNumber: (patient['patientNumber'] as num?)?.toInt() ?? 0,
      authorId: author['id'] as String,
      authorName: author['fullName'] as String?,
      appointmentId: j['appointmentId'] as String?,
      encounterDate: parseApiDate(j['encounterDate']),
      status: j['status'] as String,
      revision: (j['revision'] as num).toInt(),
      currentVersion: (j['currentVersion'] as num).toInt(),
      publishedVersion: (j['publishedVersion'] as num?)?.toInt(),
      content: EncContent.fromJson((j['content'] as Map).cast<String, dynamic>()),
      version: VersionMeta.fromJson((j['version'] as Map).cast<String, dynamic>()),
      observations: [for (final o in (j['observations'] as List? ?? const [])) Observation.fromJson(o as Map<String, dynamic>)],
    );
  }

  final String id;
  final String patientId;
  final String patientName;
  final int patientNumber;
  final String authorId;
  final String? authorName;
  final String? appointmentId;
  final DateTime? encounterDate;
  final String status; // draft | signed
  final int revision;
  final int currentVersion;
  final int? publishedVersion;
  final EncContent content;
  final VersionMeta version;
  final List<Observation> observations;

  bool get isDraft => status == 'draft';
  bool get isSigned => status == 'signed';
  bool get currentIsPublished => publishedVersion != null && publishedVersion == currentVersion;
}

class EncounterSummary {
  const EncounterSummary({required this.id, required this.status, required this.currentVersion, required this.published, this.encounterDate, this.authorName, this.chiefComplaint = '', this.diagnosis = ''});
  factory EncounterSummary.fromJson(Map<String, dynamic> j) => EncounterSummary(
        id: j['id'] as String,
        encounterDate: parseApiDate(j['encounterDate']),
        status: j['status'] as String,
        currentVersion: (j['currentVersion'] as num?)?.toInt() ?? 1,
        published: j['published'] as bool? ?? false,
        authorName: j['authorName'] as String?,
        chiefComplaint: j['chiefComplaint'] as String? ?? '',
        diagnosis: j['diagnosis'] as String? ?? '',
      );
  final String id;
  final DateTime? encounterDate;
  final String status;
  final int currentVersion;
  final bool published;
  final String? authorName;
  final String chiefComplaint;
  final String diagnosis;
}

class TrendPoint {
  const TrendPoint({required this.id, required this.value, this.measuredAt});
  factory TrendPoint.fromJson(Map<String, dynamic> j) => TrendPoint(id: j['id'] as String, value: (j['value'] as num).toDouble(), measuredAt: parseApiDate(j['measuredAt']));
  final String id;
  final double value;
  final DateTime? measuredAt;
}

class Prescription {
  const Prescription({required this.clinic, required this.doctorName, required this.licenseNumber, required this.patientName, required this.patientNumber, required this.dateOfBirth, required this.date, required this.items});
  factory Prescription.fromJson(Map<String, dynamic> j) {
    final doctor = (j['doctor'] as Map).cast<String, dynamic>();
    final patient = (j['patient'] as Map).cast<String, dynamic>();
    return Prescription(
      clinic: j['clinic'] as String?,
      doctorName: doctor['fullName'] as String?,
      licenseNumber: doctor['licenseNumber'] as String?,
      patientName: patient['fullName'] as String? ?? '',
      patientNumber: (patient['patientNumber'] as num?)?.toInt() ?? 0,
      dateOfBirth: patient['dateOfBirth'] as String?,
      date: parseApiDate(j['date']),
      items: [for (final r in (j['items'] as List? ?? const [])) Rx.fromJson(r as Map<String, dynamic>)],
    );
  }
  final String? clinic;
  final String? doctorName;
  final String? licenseNumber;
  final String patientName;
  final int patientNumber;
  final String? dateOfBirth;
  final DateTime? date;
  final List<Rx> items;
}
