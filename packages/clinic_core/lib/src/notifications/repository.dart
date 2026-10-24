import '../api/api_client.dart';
import 'models.dart';

/// Spec 10 endpoints. Backed by the shared [ApiClient] so tests can inject a fake.
class NotificationsRepository {
  NotificationsRepository(this.api);
  final ApiClient api;

  Future<NotificationPage> inbox({String? cursor, int limit = 30}) async =>
      NotificationPage.fromJson(await api.get('/notifications', query: {'limit': '$limit', 'cursor': ?cursor}) as Map<String, dynamic>);

  Future<int> unreadCount() async => ((await api.get('/notifications/unread-count')) as Map<String, dynamic>)['count'] as int;

  Future<void> markRead(String id) => api.post('/notifications/$id/read');
  Future<void> markAllRead() => api.post('/notifications/read-all');

  Future<NotificationPreferences> preferences() async => NotificationPreferences.fromJson(await api.get('/notification-preferences') as Map<String, dynamic>);

  /// Only the keys present in [patch] change: `locale`, `channels`, `quietHours` (null clears), `disabledTypes`.
  Future<NotificationPreferences> savePreferences(Map<String, dynamic> patch) async =>
      NotificationPreferences.fromJson(await api.request('PUT', '/notification-preferences', body: patch) as Map<String, dynamic>);

  Future<ConsentState> consent() async => ConsentState.fromJson(await api.get('/notification-consent') as Map<String, dynamic>);

  Future<ConsentState> saveConsent({bool? push, bool? sms}) async =>
      ConsentState.fromJson(await api.request('PUT', '/notification-consent', body: {'push': ?push, 'sms': ?sms}) as Map<String, dynamic>);

  Future<String> registerDevice(String token, String platform) async =>
      ((await api.post('/devices', body: {'token': token, 'platform': platform})) as Map<String, dynamic>)['id'] as String;

  Future<void> unregisterDevice(String token) => api.request('DELETE', '/devices', query: {'token': token});
}
