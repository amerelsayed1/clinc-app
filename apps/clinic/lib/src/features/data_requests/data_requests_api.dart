import 'package:clinic_core/clinic_core.dart';

import 'data_requests_models.dart';

class DataRequestsApi {
  DataRequestsApi(this.api);
  final ApiClient api;

  /// `clinical.read`. [status] is open | resolved | rejected.
  Future<List<DataRequest>> list(String status) async => ((await api.get('/correction-requests', query: {'status': status})) as List)
      .cast<Map<String, dynamic>>()
      .map(DataRequest.fromJson)
      .toList();

  /// `clinical.write`. Only changes the request's status and the clinic's note, never the clinical record.
  Future<void> resolve(String id, String note) => api.post('/correction-requests/$id/resolve', body: {'note': note.trim()});
  Future<void> reject(String id, String note) => api.post('/correction-requests/$id/reject', body: {'note': note.trim()});

  /// `audit.read`.
  Future<Retention> retention() async => Retention.fromJson(await api.get('/workspace/retention') as Map<String, dynamic>);

  /// `relationships.manage`. [patientId] is the care-relationship id.
  Future<void> liftLegalHold(String patientId) => api.patch('/patients/$patientId/legal-hold', body: {'hold': false});
}
