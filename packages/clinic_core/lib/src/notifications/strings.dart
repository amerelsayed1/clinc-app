import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// Arabic/English strings for the shared notification screens (spec 10, F10-7).
///
/// Hand-written rather than generated so the package needs nothing beyond the SDK packages
/// `flutter_localizations` and `intl`. To add a language: add a map to [_table] and its code to
/// [supportedLocales]. Missing keys fall back to English, then to the key itself.
class CareStrings {
  CareStrings(this.locale);
  final Locale locale;

  static const supportedLocales = [Locale('en'), Locale('ar')];

  /// Add to `MaterialApp.localizationsDelegates` (includes Material/Cupertino/Widgets delegates, which provide RTL).
  static const List<LocalizationsDelegate<dynamic>> delegates = [
    CareStringsDelegate(),
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];

  /// Falls back to English when no delegate is installed (e.g. a widget test with a bare MaterialApp).
  static CareStrings of(BuildContext context) => Localizations.of<CareStrings>(context, CareStrings) ?? CareStrings(const Locale('en'));

  String get(String key) => _table[locale.languageCode]?[key] ?? _table['en']![key] ?? key;

  String get inbox => get('inbox');
  String get notifications => get('notifications');
  String get notificationsSubtitle => get('notificationsSubtitle');
  String get markAllRead => get('markAllRead');
  String get emptyInbox => get('emptyInbox');
  String get loadMore => get('loadMore');
  String get retry => get('retry');
  String get preferences => get('preferences');
  String get language => get('language');
  String get channels => get('channels');
  String get channelsHelp => get('channelsHelp');
  String get channelPush => get('channelPush');
  String get channelSms => get('channelSms');
  String get quietHours => get('quietHours');
  String get quietHoursHelp => get('quietHoursHelp');
  String get quietFrom => get('quietFrom');
  String get quietTo => get('quietTo');
  String get types => get('types');
  String get alwaysOn => get('alwaysOn');
  String get save => get('save');
  String get saved => get('saved');
  String get consentTitle => get('consentTitle');
  String get consentBody => get('consentBody');
  String get consentPush => get('consentPush');
  String get consentSms => get('consentSms');
  String get consentAllow => get('consentAllow');
  String get consentLater => get('consentLater');
  String get consentPrivacyNote => get('consentPrivacyNote');
  String typeLabel(String type) => get('type_$type');
  String unreadSemantics(int n) => n == 0 ? notifications : get('unreadCount').replaceAll('{n}', '$n');
}

class CareStringsDelegate extends LocalizationsDelegate<CareStrings> {
  const CareStringsDelegate();
  @override
  bool isSupported(Locale locale) => CareStrings.supportedLocales.any((l) => l.languageCode == locale.languageCode);
  @override
  Future<CareStrings> load(Locale locale) => SynchronousFuture(CareStrings(locale));
  @override
  bool shouldReload(CareStringsDelegate old) => false;
}

const _table = <String, Map<String, String>>{
  'en': {
    'inbox': 'Inbox',
    'notifications': 'Notifications',
    'notificationsSubtitle': 'Inbox, reminders, quiet hours',
    'unreadCount': 'Notifications, {n} unread',
    'markAllRead': 'Mark all as read',
    'emptyInbox': 'No notifications yet',
    'loadMore': 'Load more',
    'retry': 'Try again',
    'preferences': 'Notification settings',
    'language': 'Language',
    'channels': 'How we reach you',
    'channelsHelp': 'The inbox is always on. Push and SMS messages never contain medical details; open the app to read them.',
    'channelPush': 'Push notifications',
    'channelSms': 'SMS for time-sensitive reminders',
    'quietHours': 'Quiet hours',
    'quietHoursHelp': 'Push and SMS wait until quiet hours end. Security notices are never delayed.',
    'quietFrom': 'From',
    'quietTo': 'To',
    'types': 'What to notify me about',
    'alwaysOn': 'Always on',
    'save': 'Save',
    'saved': 'Saved',
    'consentTitle': 'Stay informed?',
    'consentBody': 'Your clinic can remind you about appointments and tell you when something new is waiting for you in the app.',
    'consentPush': 'Push notifications',
    'consentSms': 'SMS reminders (when push is unavailable)',
    'consentAllow': 'Save my choice',
    'consentLater': 'No thanks',
    'consentPrivacyNote': 'Messages are generic, for example "You have a new update from your clinic". Details only appear after you open the app. You can change this any time in Notification settings.',
    'type_appointment_reminder': 'Appointment reminders',
    'type_appointment_rescheduled': 'Appointment changes',
    'type_appointment_cancelled': 'Appointment cancellations',
    'type_document_published': 'New documents',
    'type_encounter_published': 'New visit summaries',
    'type_followup_reminder': 'Follow-up reminders',
    'type_staff_invited': 'Workspace invitations',
    'type_staff_joined': 'Invitation accepted',
    'type_access_request_received': 'Record access requests',
    'type_access_request_approved': 'Access request approved',
    'type_access_request_denied': 'Access request declined',
    'type_grant_received': 'Records shared with my clinic',
    'type_grant_expiring': 'Shared access ending soon',
    'type_security_phone_changed': 'Phone number changed',
    'type_security_mfa_enabled': 'Two-step verification turned on',
    'type_security_mfa_disabled': 'Two-step verification turned off',
    'type_security_new_login': 'Sign-in from a new device',
  },
  'ar': {
    'inbox': 'الوارد',
    'notifications': 'الإشعارات',
    'notificationsSubtitle': 'الوارد والتذكيرات وساعات الهدوء',
    'unreadCount': 'الإشعارات، {n} غير مقروءة',
    'markAllRead': 'تحديد الكل كمقروء',
    'emptyInbox': 'لا توجد إشعارات بعد',
    'loadMore': 'عرض المزيد',
    'retry': 'حاول مرة أخرى',
    'preferences': 'إعدادات الإشعارات',
    'language': 'اللغة',
    'channels': 'كيف نتواصل معك',
    'channelsHelp': 'الوارد مفعّل دائماً. رسائل الإشعارات والرسائل النصية لا تحتوي على تفاصيل طبية؛ افتح التطبيق لقراءتها.',
    'channelPush': 'الإشعارات الفورية',
    'channelSms': 'رسائل نصية للتذكيرات العاجلة',
    'quietHours': 'ساعات الهدوء',
    'quietHoursHelp': 'تُؤجَّل الإشعارات والرسائل النصية حتى تنتهي ساعات الهدوء. تنبيهات الأمان لا تُؤجَّل أبداً.',
    'quietFrom': 'من',
    'quietTo': 'إلى',
    'types': 'ما الذي تريد أن نُنبّهك به',
    'alwaysOn': 'مفعّل دائماً',
    'save': 'حفظ',
    'saved': 'تم الحفظ',
    'consentTitle': 'هل تريد البقاء على اطلاع؟',
    'consentBody': 'يمكن لعيادتك تذكيرك بالمواعيد وإخبارك عند وجود جديد في انتظارك داخل التطبيق.',
    'consentPush': 'الإشعارات الفورية',
    'consentSms': 'تذكيرات بالرسائل النصية (عند عدم توفر الإشعارات)',
    'consentAllow': 'حفظ اختياري',
    'consentLater': 'لا، شكراً',
    'consentPrivacyNote': 'الرسائل عامة، مثل "لديك تحديث جديد من عيادتك". لا تظهر التفاصيل إلا بعد فتح التطبيق. يمكنك تغيير ذلك في أي وقت من إعدادات الإشعارات.',
    'type_appointment_reminder': 'تذكيرات المواعيد',
    'type_appointment_rescheduled': 'تغييرات المواعيد',
    'type_appointment_cancelled': 'إلغاء المواعيد',
    'type_document_published': 'المستندات الجديدة',
    'type_encounter_published': 'ملخصات الزيارات الجديدة',
    'type_followup_reminder': 'تذكيرات المتابعة',
    'type_staff_invited': 'دعوات الانضمام',
    'type_staff_joined': 'قبول الدعوة',
    'type_access_request_received': 'طلبات الاطلاع على السجلات',
    'type_access_request_approved': 'الموافقة على طلب الاطلاع',
    'type_access_request_denied': 'رفض طلب الاطلاع',
    'type_grant_received': 'سجلات مشاركة مع عيادتي',
    'type_grant_expiring': 'اقتراب انتهاء المشاركة',
    'type_security_phone_changed': 'تغيير رقم الهاتف',
    'type_security_mfa_enabled': 'تفعيل التحقق بخطوتين',
    'type_security_mfa_disabled': 'إيقاف التحقق بخطوتين',
    'type_security_new_login': 'تسجيل دخول من جهاز جديد',
  },
};
