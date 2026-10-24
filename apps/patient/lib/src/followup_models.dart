import 'package:clinic_core/clinic_core.dart';

/// A measurement the doctor asked for. The patient app never receives the doctor's expected range.
class FollowupMeasurement {
  const FollowupMeasurement({
    required this.id,
    required this.name,
    required this.unit,
    required this.frequency,
    required this.intervalDays,
    this.lastSubmittedAt,
    this.dueAt,
    this.isDue = false,
  });

  factory FollowupMeasurement.fromJson(Map<String, dynamic> j) => FollowupMeasurement(
        id: j['id'] as String,
        name: j['name'] as String,
        unit: j['unit'] as String? ?? '',
        frequency: j['frequency'] as String? ?? 'daily',
        intervalDays: (j['intervalDays'] as num?)?.toInt() ?? 1,
        lastSubmittedAt: parseApiDate(j['lastSubmittedAt']),
        dueAt: parseApiDate(j['dueAt']),
        isDue: j['isDue'] == true,
      );

  final String id;
  final String name;
  final String unit;
  final String frequency; // daily | weekly | custom
  final int intervalDays;
  final DateTime? lastSubmittedAt;
  final DateTime? dueAt;
  final bool isDue;

  String get frequencyLabel => switch (frequency) {
        'daily' => 'Every day',
        'weekly' => 'Every week',
        _ => intervalDays == 1 ? 'Every day' : 'Every $intervalDays days',
      };
}

class FollowupPlan {
  const FollowupPlan({
    required this.id,
    required this.clinicName,
    this.doctorName,
    required this.status,
    this.nextVisitDate,
    this.instructions = '',
    this.startDate,
    this.endDate,
    this.measurements = const [],
  });

  factory FollowupPlan.fromJson(Map<String, dynamic> j) => FollowupPlan(
        id: j['id'] as String,
        clinicName: j['clinicName'] as String? ?? '',
        doctorName: j['doctorName'] as String?,
        status: j['status'] as String? ?? 'active',
        nextVisitDate: j['nextVisitDate'] as String?,
        instructions: j['instructions'] as String? ?? '',
        startDate: j['startDate'] as String?,
        endDate: j['endDate'] as String?,
        measurements: ((j['measurements'] as List?) ?? const []).cast<Map<String, dynamic>>().map(FollowupMeasurement.fromJson).toList(),
      );

  final String id;
  final String clinicName;
  final String? doctorName;
  final String status; // active | closed
  final String? nextVisitDate;
  final String instructions;
  final String? startDate;
  final String? endDate;
  final List<FollowupMeasurement> measurements;

  bool get isClosed => status == 'closed';

  /// True while the plan can still take values (the server makes the final call, including the end date).
  bool get acceptsValues {
    if (isClosed) return false;
    final end = endDate;
    if (end == null) return true;
    return formatDate(DateTime.now()).compareTo(end) <= 0;
  }

  int get dueCount => acceptsValues ? measurements.where((m) => m.isDue).length : 0;
  String get title => doctorName ?? clinicName;
}

/// Something the patient reported. Always the patient's own, unverified data.
class FollowupSubmission {
  const FollowupSubmission({required this.id, required this.measurementName, required this.unit, required this.value, required this.measuredAt, this.note = '', this.hasAttachment = false});

  factory FollowupSubmission.fromJson(Map<String, dynamic> j) => FollowupSubmission(
        id: j['id'] as String,
        measurementName: j['measurementName'] as String? ?? '',
        unit: j['unit'] as String? ?? '',
        value: (j['value'] as num).toDouble(),
        measuredAt: parseApiDate(j['measuredAt']) ?? DateTime.now(),
        note: j['note'] as String? ?? '',
        hasAttachment: j['documentId'] != null,
      );

  final String id;
  final String measurementName;
  final String unit;
  final double value;
  final DateTime measuredAt;
  final String note;
  final bool hasAttachment;
}

/// Parses what the user typed. Accepts a decimal comma. Returns null when it is not a finite number.
double? parseReading(String text) {
  final v = double.tryParse(text.trim().replaceAll(',', '.'));
  return v != null && v.isFinite ? v : null;
}

String? validateReading({required String valueText, required DateTime measuredAt, DateTime? now}) {
  if (parseReading(valueText) == null) return 'Enter the value as a number.';
  if (measuredAt.isAfter((now ?? DateTime.now()).add(const Duration(minutes: 5)))) return 'The time cannot be in the future.';
  return null;
}

String followupErrorMessage(Object e) {
  if (e is ApiException) {
    switch (e.code) {
      case 'plan_closed':
        return 'Your doctor has closed this follow-up plan, so new values cannot be added.';
      case 'plan_ended':
        return 'This follow-up plan has ended, so new values cannot be added.';
      case 'plan_not_started':
        return 'This follow-up plan has not started yet.';
      case 'implausible_value':
        return e.message;
    }
  }
  return errorMessage(e);
}

class PickedAttachment {
  const PickedAttachment(this.bytes, this.name);
  final List<int> bytes;
  final String name;
}
