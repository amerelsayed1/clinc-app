import 'package:clinic_core/clinic_core.dart';

import 'documents_models.dart';

/// Document endpoints (apps/api/src/routes/documents.ts + the shared-with-me document routes).
class DocumentsApi {
  DocumentsApi(this.api);
  final ApiClient api;

  Future<List<ClinicDoc>> list(String patientId, {String? encounterId}) async =>
      ((await api.get('/patients/$patientId/documents', query: encounterId == null ? null : {'encounterId': encounterId})) as List)
          .cast<Map<String, dynamic>>()
          .map(ClinicDoc.fromJson)
          .toList();

  Future<ClinicDoc> get(String id) async => ClinicDoc.fromJson(await api.get('/documents/$id') as Map<String, dynamic>);

  Future<StorageUsage> storage() async {
    final j = await api.get('/workspace/storage') as Map<String, dynamic>;
    return StorageUsage((j['usedBytes'] as num).toInt(), (j['quotaBytes'] as num).toInt());
  }

  /// Multi-page upload: every page is a `file` part, in order.
  Future<ClinicDoc> upload(String patientId, {required Map<String, String> fields, required List<PickedPage> pages}) async =>
      ClinicDoc.fromJson(await api.postMultipartFiles(
        '/patients/$patientId/documents',
        fields: fields,
        files: [for (final p in pages) (filename: p.name, bytes: p.bytes)],
      ) as Map<String, dynamic>);

  Future<void> review(String id) => api.post('/documents/$id/review', body: {'note': ''});
  Future<void> publish(String id) => api.post('/documents/$id/publish', body: {});
  Future<void> unpublish(String id) => api.post('/documents/$id/unpublish', body: {});
  Future<void> delete(String id, String reason) => api.request('DELETE', '/documents/$id', body: {'reason': reason});

  /// Authorises the page and returns a short-lived signed path (`/files/<token>`).
  Future<String> pageLink(String id, int page) async => (await api.get('/documents/$id/pages/$page/link') as Map<String, dynamic>)['path'] as String;

  Future<List<int>> fetch(String path) => api.getBytes(path);

  // ---- documents shared with this clinic by the patient (grant based) ----
  Future<ClinicDoc> sharedGet(String grantId, String docId) async =>
      ClinicDoc.fromJson(await api.get('/shared-with-me/$grantId/documents/$docId') as Map<String, dynamic>);

  Future<String> sharedPageLink(String grantId, String docId, int page) async =>
      (await api.get('/shared-with-me/$grantId/documents/$docId/pages/$page/link') as Map<String, dynamic>)['path'] as String;
}
