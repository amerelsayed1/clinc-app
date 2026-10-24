import 'package:clinic_core/clinic_core.dart';

import 'followup_models.dart';

/// Follow-up endpoints (apps/api/src/routes/followups.ts). Reads need clinical.read, writes clinical.write.
class FollowupApi {
  FollowupApi(this.api);
  final ApiClient api;

  Future<List<FollowupPlan>> plans(String patientId) async =>
      ((await api.get('/patients/$patientId/followups')) as List).cast<Map<String, dynamic>>().map(FollowupPlan.fromJson).toList();

  Future<FollowupPlan> plan(String id) async => FollowupPlan.fromJson(await api.get('/followups/$id') as Map<String, dynamic>);

  Future<FollowupPlan> create(String patientId, Map<String, dynamic> body) async =>
      FollowupPlan.fromJson(await api.post('/patients/$patientId/followups', body: body) as Map<String, dynamic>);

  Future<void> edit(String id, Map<String, dynamic> body) => api.patch('/followups/$id', body: body);

  Future<void> close(String id, String reason) => api.post('/followups/$id/close', body: {'reason': reason});

  Future<List<FollowupVersion>> history(String id) async =>
      ((await api.get('/followups/$id/history')) as List).cast<Map<String, dynamic>>().map(FollowupVersion.fromJson).toList();

  Future<List<TrendPoint>> trend(String planId, String measurementId) async {
    final j = await api.get('/followups/$planId/measurements/$measurementId/trend') as Map<String, dynamic>;
    return [
      for (final p in ((j['points'] as List?) ?? const []).cast<Map<String, dynamic>>())
        TrendPoint(measuredAt: DateTime.parse(p['measuredAt'] as String), value: (p['value'] as num).toDouble(), outside: (p['outsideExpectedRange'] ?? false) as bool),
    ];
  }

  Future<List<AttentionEntry>> attention() async =>
      ((await api.get('/followups/attention')) as List).cast<Map<String, dynamic>>().map(AttentionEntry.fromJson).toList();
}
