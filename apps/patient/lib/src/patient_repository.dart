import 'package:clinic_core/clinic_core.dart';

import 'followup_models.dart';
import 'privacy_models.dart';
import 'sharing_models.dart';
import 'timeline_models.dart';

class Relationship {
  const Relationship({
    required this.id,
    required this.status,
    required this.workspaceName,
    this.doctorName,
    this.createdAt,
    this.endedAt,
  });

  factory Relationship.fromJson(Map<String, dynamic> j) => Relationship(
        id: j['id'] as String,
        status: j['status'] as String,
        workspaceName: j['workspaceName'] as String? ?? '',
        doctorName: j['doctorName'] as String?,
        createdAt: parseApiDate(j['createdAt']),
        endedAt: parseApiDate(j['endedAt']),
      );

  final String id;
  final String status; // invited | active | ended | declined ...
  final String workspaceName;
  final String? doctorName;
  final DateTime? createdAt;
  final DateTime? endedAt;

  bool get isInvited => status == 'invited';
  bool get isActive => status == 'active';
}

/// Patient-side endpoints. Backed by the shared [ApiClient] so tests can inject a fake.
class PatientRepository {
  PatientRepository(this.api);
  final ApiClient api;

  List<Relationship> _parse(dynamic json) =>
      (json as List).cast<Map<String, dynamic>>().map(Relationship.fromJson).toList();

  /// Links the signed-in phone to a patient record a doctor may have created. Idempotent.
  Future<List<Relationship>> claim() async => _parse(await api.post('/patient/claim'));

  Future<List<Relationship>> relationships() async => _parse(await api.get('/patient/relationships'));

  Future<void> accept(String id) => api.post('/patient/relationships/$id/accept');
  Future<void> decline(String id) => api.post('/patient/relationships/$id/decline');
  Future<void> end(String id) => api.post('/patient/relationships/$id/end');

  // --- Sharing & consent (spec 08) ---
  Future<List<ShareableItem>> shareable() async =>
      ((await api.get('/patient/shareable')) as List).cast<Map<String, dynamic>>().map(ShareableItem.fromJson).toList();

  Future<List<Grant>> grants() async => ((await api.get('/patient/grants')) as List).cast<Map<String, dynamic>>().map(Grant.fromJson).toList();

  Future<Grant> createGrant(Map<String, dynamic> body) async => Grant.fromJson(await api.post('/patient/grants', body: body) as Map<String, dynamic>);

  Future<void> revokeGrant(String id) => api.delete('/patient/grants/$id');

  Future<List<AccessRequest>> accessRequests() async =>
      ((await api.get('/patient/access-requests')) as List).cast<Map<String, dynamic>>().map(AccessRequest.fromJson).toList();

  Future<void> approveRequest(String id, Map<String, dynamic> body) => api.post('/patient/access-requests/$id/approve', body: body);
  Future<void> denyRequest(String id) => api.post('/patient/access-requests/$id/deny');

  Future<List<AccessLogEntry>> accessLog({String? grantId}) async =>
      ((await api.get('/patient/access-log', query: grantId == null ? null : {'grantId': grantId})) as List)
          .cast<Map<String, dynamic>>()
          .map(AccessLogEntry.fromJson)
          .toList();

  // --- Follow-up plans (spec 09) ---
  Future<List<FollowupPlan>> followups() async =>
      ((await api.get('/patient/followups')) as List).cast<Map<String, dynamic>>().map(FollowupPlan.fromJson).toList();

  Future<List<FollowupSubmission>> followupSubmissions(String planId) async =>
      ((await api.get('/patient/followups/$planId/submissions')) as List).cast<Map<String, dynamic>>().map(FollowupSubmission.fromJson).toList();

  Future<FollowupSubmission> submitFollowup(String planId, {required String measurementId, required double value, required DateTime measuredAt, String note = '', String? documentId}) async =>
      FollowupSubmission.fromJson(await api.post('/patient/followups/$planId/submissions', body: {
        'measurementId': measurementId,
        'value': value,
        'measuredAt': measuredAt.toUtc().toIso8601String(),
        if (note.trim().isNotEmpty) 'note': note.trim(),
        'documentId': ?documentId,
      }) as Map<String, dynamic>);

  /// Uploads a photo through the existing patient document endpoint and returns the new document id.
  Future<String> uploadAttachment(PickedAttachment file) async {
    final r = await api.postMultipart('/patient/documents', fields: {'category': 'other', 'title': 'Follow-up attachment'}, bytes: file.bytes, filename: file.name);
    return (r as Map<String, dynamic>)['id'] as String;
  }

  // --- Medical timeline (spec 07) ---
  Future<TimelineResult> timeline(TimelineFilters filters, {String? cursor, int limit = 30}) async =>
      TimelineResult.fromJson(await api.get('/patient/timeline', query: filters.toQuery(cursor: cursor, limit: limit)) as Map<String, dynamic>);

  Future<EncounterView> encounterDetail(String id) async => EncounterView.fromJson(await api.get('/patient/encounters/$id') as Map<String, dynamic>);

  /// There is no single-document endpoint for patients; their document list is small and already authorised.
  Future<DocumentView> documentDetail(String id) async {
    final list = (await api.get('/patient/documents') as List).cast<Map<String, dynamic>>();
    return DocumentView.fromJson(list.firstWhere((d) => d['id'] == id, orElse: () => throw ApiException(status: 404, code: 'not_found', message: 'Document not found')));
  }

  /// Short-lived path of one page's file; prefix with the API base URL.
  Future<String> documentPageLink(String id, int page) async => (await api.get('/patient/documents/$id/pages/$page/link') as Map<String, dynamic>)['path'] as String;

  // --- Privacy and data rights (spec 11) ---

  /// The patient's own data bundle (profile, relationships, published records, grants, access log). Audited and rate limited server side.
  Future<Map<String, dynamic>> exportData() async => await api.post('/patient/export') as Map<String, dynamic>;

  Future<List<CorrectionRequest>> correctionRequests() async =>
      ((await api.get('/patient/correction-requests')) as List).cast<Map<String, dynamic>>().map(CorrectionRequest.fromJson).toList();

  Future<void> requestCorrection({required String targetType, required String targetId, required String description}) =>
      api.post('/patient/correction-requests', body: {'targetType': targetType, 'targetId': targetId, 'description': description.trim()});

  /// Records the patient can see and that a clinic authored: published consultations, published documents, registration details.
  Future<List<CorrectableRecord>> correctableRecords() async {
    final encounters = (await api.get('/patient/encounters') as List).cast<Map<String, dynamic>>();
    final documents = (await api.get('/patient/documents') as List).cast<Map<String, dynamic>>();
    final rels = (await api.get('/patient/relationships') as List).cast<Map<String, dynamic>>();
    return [
      for (final e in encounters)
        CorrectableRecord(
          type: 'encounter',
          id: e['id'] as String,
          title: 'Consultation ${formatDate(parseApiDate(e['encounterDate']))}',
          subtitle: '${e['clinicName'] ?? ''}${e['doctorName'] == null ? '' : ' · ${e['doctorName']}'}',
        ),
      for (final d in documents.where((d) => d['source'] != 'patient'))
        CorrectableRecord(type: 'document', id: d['id'] as String, title: (d['title'] as String?)?.isNotEmpty == true ? d['title'] as String : '${d['category']}', subtitle: 'Document from your clinic'),
      for (final r in rels.where((r) => r['status'] != 'declined'))
        CorrectableRecord(type: 'relationship', id: r['id'] as String, title: 'My details at ${r['workspaceName'] ?? 'clinic'}', subtitle: 'Name, date of birth and sex on file'),
    ];
  }
}
