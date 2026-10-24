import 'package:clinic_core/clinic_core.dart';

class ApptPatient {
  const ApptPatient({required this.id, required this.fullName, required this.patientNumber, required this.phone});
  factory ApptPatient.fromJson(Map<String, dynamic> j) => ApptPatient(
        id: j['id'] as String,
        fullName: j['fullName'] as String? ?? '',
        patientNumber: (j['patientNumber'] as num?)?.toInt() ?? 0,
        phone: j['phone'] as String? ?? '',
      );
  final String id;
  final String fullName;
  final int patientNumber;
  final String phone;
}

class Appointment {
  const Appointment({
    required this.id,
    required this.patient,
    required this.scheduledAt,
    required this.durationMinutes,
    required this.type,
    required this.status,
    this.isWalkIn = false,
    this.reason,
    this.checkedInAt,
    this.cancelReason,
    this.encounterId,
  });

  factory Appointment.fromJson(Map<String, dynamic> j) => Appointment(
        id: j['id'] as String,
        patient: ApptPatient.fromJson((j['patient'] as Map).cast<String, dynamic>()),
        scheduledAt: parseApiDate(j['scheduledAt']) ?? DateTime.now(),
        durationMinutes: (j['durationMinutes'] as num?)?.toInt() ?? 0,
        type: j['type'] as String? ?? 'new',
        isWalkIn: j['isWalkIn'] as bool? ?? false,
        reason: j['reason'] as String?,
        status: j['status'] as String,
        checkedInAt: parseApiDate(j['checkedInAt']),
        cancelReason: j['cancelReason'] as String?,
        encounterId: j['encounterId'] as String?,
      );

  final String id;
  final ApptPatient patient;
  final DateTime scheduledAt;
  final int durationMinutes;
  final String type; // new | follow_up
  final bool isWalkIn;
  final String? reason;
  final String status; // scheduled | checked_in | in_consultation | completed | cancelled | no_show
  final DateTime? checkedInAt;
  final String? cancelReason;
  final String? encounterId;

  bool get isFollowUp => type == 'follow_up';
}

String appointmentStatusLabel(String s) => switch (s) {
      'scheduled' => 'Scheduled',
      'checked_in' => 'Waiting',
      'in_consultation' => 'In consultation',
      'completed' => 'Completed',
      'cancelled' => 'Cancelled',
      'no_show' => 'No-show',
      _ => s,
    };

/// A booking that needs the front desk's confirmation to go ahead.
class SlotProblem {
  const SlotProblem({required this.code, required this.conflicts});
  final String code; // slot_conflict | outside_working_hours
  final List<Appointment> conflicts;

  static SlotProblem? from(Object error) {
    if (error is! ApiException || (error.code != 'slot_conflict' && error.code != 'outside_working_hours')) return null;
    final d = error.details;
    final conflicts = d is Map && d['conflicts'] is List
        ? [for (final c in d['conflicts'] as List) Appointment.fromJson((c as Map).cast<String, dynamic>())]
        : <Appointment>[];
    return SlotProblem(code: error.code, conflicts: conflicts);
  }
}
