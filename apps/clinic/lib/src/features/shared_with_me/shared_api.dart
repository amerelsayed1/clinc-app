import 'package:clinic_core/clinic_core.dart';

import 'shared_models.dart';

/// Endpoints of apps/api/src/routes/sharing.ts used by the clinic side. Reads need `clinical.read`,
/// sending/cancelling an access request needs `clinical.write`.
class SharedApi {
  SharedApi(this.api);
  final ApiClient api;

  String get baseUrl => api.baseUrl;

  Future<List<SharedGrant>> grants() async =>
      ((await api.get('/shared-with-me')) as List).cast<Map<String, dynamic>>().map(SharedGrant.fromJson).toList();

  Future<List<SharedItem>> items(String grantId) async =>
      ((await api.get('/shared-with-me/$grantId/items')) as List).cast<Map<String, dynamic>>().map(SharedItem.fromJson).toList();

  Future<SharedEncounter> encounter(String grantId, String id) async =>
      SharedEncounter.fromJson(await api.get('/shared-with-me/$grantId/encounters/$id') as Map<String, dynamic>);

  Future<SharedDocument> document(String grantId, String id) async =>
      SharedDocument.fromJson(await api.get('/shared-with-me/$grantId/documents/$id') as Map<String, dynamic>);

  /// Short-lived signed path (`/files/<token>`); prepend [baseUrl] to display it.
  Future<String> pageLink(String grantId, String docId, int page) async =>
      (await api.get('/shared-with-me/$grantId/documents/$docId/pages/$page/link') as Map<String, dynamic>)['path'] as String;

  Future<List<AccessRequest>> accessRequests() async =>
      ((await api.get('/access-requests')) as List).cast<Map<String, dynamic>>().map(AccessRequest.fromJson).toList();

  /// [relationshipId] is the care-relationship id (what the dashboard calls the patient id).
  Future<void> requestAccess(String relationshipId, Map<String, Object?> body) =>
      api.post('/patients/$relationshipId/access-requests', body: body);

  Future<void> cancelAccessRequest(String id) => api.delete('/access-requests/$id');
}

bool isGone(Object e) => e is ApiException && e.status == 404;
