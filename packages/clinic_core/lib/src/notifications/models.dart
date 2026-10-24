import '../auth/models.dart';

class AppNotification {
  const AppNotification({required this.id, required this.type, required this.title, required this.body, required this.data, required this.createdAt, required this.read});

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as String,
        type: j['type'] as String,
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        data: (j['data'] as Map?)?.cast<String, dynamic>() ?? const {},
        createdAt: parseApiDate(j['createdAt']),
        read: j['read'] as bool? ?? false,
      );

  final String id;
  final String type;
  final String title; // already localized by the server and non-clinical
  final String body;
  final Map<String, dynamic> data; // ids for deep links, never clinical content
  final DateTime? createdAt;
  final bool read;

  AppNotification asRead() => AppNotification(id: id, type: type, title: title, body: body, data: data, createdAt: createdAt, read: true);
}

class NotificationPage {
  const NotificationPage(this.items, this.nextCursor);
  factory NotificationPage.fromJson(Map<String, dynamic> j) =>
      NotificationPage((j['items'] as List).cast<Map<String, dynamic>>().map(AppNotification.fromJson).toList(), j['nextCursor'] as String?);
  final List<AppNotification> items;
  final String? nextCursor;
}

class ConsentState {
  const ConsentState({required this.required, this.push, this.sms});
  factory ConsentState.fromJson(Map<String, dynamic> j) => ConsentState(required: j['required'] as bool? ?? false, push: j['push'] as bool?, sms: j['sms'] as bool?);
  final bool required;
  final bool? push; // null = never asked
  final bool? sms;

  /// First launch for a patient registered by a doctor: nothing is sent outside the app until they answer.
  bool get needsPrompt => required && push == null && sms == null;
}

class QuietHours {
  const QuietHours({required this.start, required this.end, required this.timezone});
  final String start; // HH:MM
  final String end;
  final String timezone;
}

class NotificationTypeInfo {
  const NotificationTypeInfo(this.type, this.mandatory);
  final String type;
  final bool mandatory; // security notices
}

class NotificationPreferences {
  const NotificationPreferences({
    required this.locale,
    required this.localeExplicit,
    required this.channels,
    required this.quietHours,
    required this.disabledTypes,
    required this.types,
    required this.consent,
  });

  factory NotificationPreferences.fromJson(Map<String, dynamic> j) {
    final q = j['quietHours'] as Map<String, dynamic>?;
    return NotificationPreferences(
      locale: j['locale'] as String? ?? 'ar',
      localeExplicit: j['localeExplicit'] as bool? ?? false,
      channels: (j['channels'] as List? ?? const []).cast<String>(),
      quietHours: q == null ? null : QuietHours(start: q['start'] as String, end: q['end'] as String, timezone: q['timezone'] as String? ?? 'UTC'),
      disabledTypes: (j['disabledTypes'] as List? ?? const []).cast<String>(),
      types: (j['types'] as List? ?? const []).cast<Map<String, dynamic>>().map((t) => NotificationTypeInfo(t['type'] as String, t['mandatory'] as bool? ?? false)).toList(),
      consent: ConsentState.fromJson((j['consent'] as Map?)?.cast<String, dynamic>() ?? const {}),
    );
  }

  final String locale;
  final bool localeExplicit; // false until the user has saved a choice
  final List<String> channels;
  final QuietHours? quietHours;
  final List<String> disabledTypes;
  final List<NotificationTypeInfo> types;
  final ConsentState consent;
}
