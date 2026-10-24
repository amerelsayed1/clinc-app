import 'package:clinic_core/clinic_core.dart';

import '../settings/settings_models.dart';
import 'appointments_models.dart';

/// Appointment endpoints (apps/api/src/routes/appointments.ts).
class AppointmentsApi {
  AppointmentsApi(this.api);
  final ApiClient api;

  Future<ClinicSettings> settings() async => ClinicSettings.fromJson(await api.get('/workspace/settings') as Map<String, dynamic>);

  List<Appointment> _list(Object? res) => (res as List).cast<Map<String, dynamic>>().map(Appointment.fromJson).toList();

  /// One day (YYYY-MM-DD in the clinic's time zone).
  Future<List<Appointment>> day(String date) async => _list(await api.get('/appointments', query: {'date': date}));

  Future<List<Appointment>> forPatient(String patientId) async => _list(await api.get('/appointments', query: {'patientId': patientId}));

  /// [localStart] is the clinic wall-clock time, `YYYY-MM-DDTHH:MM`.
  Future<Appointment> book({
    required String patientId,
    required String localStart,
    String type = 'new',
    String? reason,
    int? durationMinutes,
    bool override = false,
  }) async =>
      Appointment.fromJson(await api.post('/appointments', body: {
        'patientId': patientId,
        'localStart': localStart,
        'type': type,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
        'durationMinutes': ?durationMinutes,
        if (override) 'override': true,
      }) as Map<String, dynamic>);

  Future<Appointment> walkIn({required String patientId, String type = 'new', String? reason}) async =>
      Appointment.fromJson(await api.post('/appointments/walk-in', body: {
        'patientId': patientId,
        'type': type,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      }) as Map<String, dynamic>);

  Future<Appointment> reschedule(
    String id, {
    required String localStart,
    required String type,
    String? reason,
    int? durationMinutes,
    bool override = false,
  }) async =>
      Appointment.fromJson(await api.patch('/appointments/$id', body: {
        'localStart': localStart,
        'type': type,
        'reason': (reason == null || reason.trim().isEmpty) ? null : reason.trim(),
        'durationMinutes': ?durationMinutes,
        if (override) 'override': true,
      }) as Map<String, dynamic>);

  /// action: check-in | start | complete | cancel | no-show
  Future<Appointment> act(String id, String action, {String? reason}) async => Appointment.fromJson(
      await api.post('/appointments/$id/$action', body: {if (action == 'cancel' && reason != null && reason.isNotEmpty) 'reason': reason}) as Map<String, dynamic>);
}
