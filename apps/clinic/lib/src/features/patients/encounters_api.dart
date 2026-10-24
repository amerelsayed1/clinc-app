import 'package:clinic_core/clinic_core.dart';

import 'patients_models.dart';

/// Encounter / vitals endpoints (apps/api/src/routes/encounters.ts).
class EncountersApi {
  EncountersApi(this.api);
  final ApiClient api;

  Future<List<EncounterSummary>> forPatient(String patientId) async =>
      ((await api.get('/patients/$patientId/encounters')) as List).cast<Map<String, dynamic>>().map(EncounterSummary.fromJson).toList();

  Future<Encounter> create(String patientId, {String? appointmentId}) async =>
      Encounter.fromJson(await api.post('/patients/$patientId/encounters', body: {'appointmentId': ?appointmentId}) as Map<String, dynamic>);

  Future<Encounter> get(String id) async => Encounter.fromJson(await api.get('/encounters/$id') as Map<String, dynamic>);

  Future<List<EncVersion>> versions(String id) async =>
      ((await api.get('/encounters/$id/versions')) as List).cast<Map<String, dynamic>>().map(EncVersion.fromJson).toList();

  /// Autosave. Throws `revision_conflict` (409, details {revision, content}) when the draft moved on.
  Future<Encounter> saveDraft(String id, {required int revision, required EncContent content, required bool includePrivate}) async =>
      Encounter.fromJson(await api.patch('/encounters/$id', body: {'revision': revision, ...content.toDraftJson(includePrivate: includePrivate)}) as Map<String, dynamic>);

  Future<void> discard(String id) => api.delete('/encounters/$id');

  Future<Encounter> sign(String id, {required int revision}) async =>
      Encounter.fromJson(await api.post('/encounters/$id/sign', body: {'revision': revision}) as Map<String, dynamic>);

  Future<Encounter> amend(String id, {required int baseVersion, required String reason, required Map<String, dynamic> changes}) async =>
      Encounter.fromJson(await api.post('/encounters/$id/amend', body: {'baseVersion': baseVersion, 'reason': reason, 'changes': changes}) as Map<String, dynamic>);

  Future<Encounter> publish(String id) async => Encounter.fromJson(await api.post('/encounters/$id/publish', body: <String, dynamic>{}) as Map<String, dynamic>);

  Future<Encounter> unpublish(String id) async => Encounter.fromJson(await api.post('/encounters/$id/unpublish') as Map<String, dynamic>);

  Future<Observation> addObservation(String id, {required String kind, required double value}) async =>
      Observation.fromJson(await api.post('/encounters/$id/observations', body: {'kind': kind, 'value': value}) as Map<String, dynamic>);

  Future<void> voidObservation(String id, String observationId, String reason) =>
      api.post('/encounters/$id/observations/$observationId/void', body: {'reason': reason});

  Future<({String unit, List<TrendPoint> points})> trend(String patientId, String kind) async {
    final j = await api.get('/patients/$patientId/observations', query: {'kind': kind}) as Map<String, dynamic>;
    return (unit: j['unit'] as String? ?? '', points: [for (final p in (j['points'] as List? ?? const [])) TrendPoint.fromJson(p as Map<String, dynamic>)]);
  }

  Future<Prescription> prescription(String id) async => Prescription.fromJson(await api.get('/encounters/$id/prescription') as Map<String, dynamic>);
}
