import 'package:clinic_core/clinic_core.dart';

import 'timeline_models.dart';

class TimelineApi {
  TimelineApi(this.api);
  final ApiClient api;

  Future<TimelinePage> page(String patientId, TimelineFilters f, {String? cursor}) async {
    final j = await api.get('/patients/$patientId/timeline', query: f.toQuery(cursor: cursor)) as Map<String, dynamic>;
    return TimelinePage(
      ((j['items'] as List?) ?? const []).cast<Map<String, dynamic>>().map(TimelineEntry.fromJson).toList(),
      j['nextCursor'] as String?,
    );
  }

  Future<Map<String, dynamic>> encounter(String id) async => await api.get('/encounters/$id') as Map<String, dynamic>;
  Future<Map<String, dynamic>> sharedEncounter(String grantId, String id) async => await api.get('/shared-with-me/$grantId/encounters/$id') as Map<String, dynamic>;
}
