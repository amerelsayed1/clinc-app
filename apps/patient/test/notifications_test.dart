import 'package:carelink_patient/src/app.dart';
import 'package:carelink_patient/src/patient_repository.dart';
import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

Map<String, dynamic> note(String id, {bool read = false}) => {
      'id': id,
      'type': 'document_published',
      'title': 'New document',
      'body': 'New document available from Nile Clinic.',
      'data': {'documentId': 'd1'},
      'createdAt': '2026-10-01T10:00:00Z',
      'read': read,
    };

Map<String, dynamic> prefs({String locale = 'en', bool explicit = false}) => {
      'locale': locale,
      'localeExplicit': explicit,
      'channels': ['push', 'sms'],
      'quietHours': null,
      'timezone': 'Africa/Cairo',
      'disabledTypes': [],
      'types': [
        {'type': 'document_published', 'mandatory': false},
        {'type': 'security_new_login', 'mandatory': true},
      ],
      'consent': {'required': true, 'push': null, 'sms': null},
    };

Future<FakeApi> boot(WidgetTester tester, Map<String, Object? Function(Object? body)> routes) async {
  final api = FakeApi({'GET /me': (_) => me(), 'POST /patient/claim': (_) => [], ...routes});
  final auth = AuthController(api);
  await auth.bootstrap();
  await tester.pumpWidget(PatientApp(auth: auth, repository: PatientRepository(api)));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('first launch asks for notification consent and records the answer (F10-5)', (tester) async {
    final api = await boot(tester, {
      'GET /notification-consent': (_) => {'required': true, 'push': null, 'sms': null},
      'PUT /notification-consent': (b) => {'required': true, ...(b as Map<String, dynamic>)},
      'GET /notification-preferences': (_) => prefs(),
      'GET /notifications/unread-count': (_) => {'count': 0},
    });
    expect(find.text('Stay informed?'), findsOneWidget);
    expect(find.textContaining('Details only appear after you open the app'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('consent-save')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('PUT /notification-consent'));
    expect(find.text('Stay informed?'), findsNothing);
    expect(find.text('Care team'), findsWidgets);
  });

  testWidgets('does not ask again once answered', (tester) async {
    await boot(tester, {
      'GET /notification-consent': (_) => {'required': true, 'push': false, 'sms': false},
      'GET /notification-preferences': (_) => prefs(),
      'GET /notifications/unread-count': (_) => {'count': 0},
    });
    expect(find.text('Stay informed?'), findsNothing);
  });

  testWidgets('Inbox tab shows the unread badge, lists items and marks them read', (tester) async {
    final api = await boot(tester, {
      'GET /notification-consent': (_) => {'required': true, 'push': true, 'sms': true},
      'GET /notification-preferences': (_) => prefs(),
      'GET /notifications/unread-count': (_) => {'count': 3},
      'GET /notifications': (_) => {'items': [note('n1'), note('n2', read: true)], 'nextCursor': null},
      'POST /notifications/n1/read': (_) => {'ok': true},
    });
    expect(find.text('3'), findsOneWidget); // badge on the Inbox destination
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    expect(find.text('New document available from Nile Clinic.'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('notification-n1')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /notifications/n1/read'));
    expect(find.text('2'), findsOneWidget); // badge decremented
  });

  testWidgets('a saved Arabic preference switches the app to Arabic RTL, and settings can switch it back', (tester) async {
    await boot(tester, {
      'GET /notification-consent': (_) => {'required': true, 'push': true, 'sms': true},
      'GET /notification-preferences': (_) => prefs(locale: 'ar', explicit: true),
      'PUT /notification-preferences': (b) => prefs(locale: (b as Map<String, dynamic>)['locale'] as String, explicit: true),
      'GET /notifications/unread-count': (_) => {'count': 0},
      'GET /notifications': (_) => {'items': [], 'nextCursor': null},
    });
    expect(find.text('الوارد'), findsWidgets); // Inbox tab label in Arabic
    expect(Directionality.of(tester.element(find.text('الوارد').first)), TextDirection.rtl);
    // Account -> notification settings -> English.
    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الإشعارات'));
    await tester.pumpAndSettle();
    expect(find.text('إعدادات الإشعارات'), findsOneWidget);
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(find.text('Notification settings'), findsOneWidget);
    expect(Directionality.of(tester.element(find.text('Notification settings'))), TextDirection.ltr);
  });

  testWidgets('notification failures never break the app', (tester) async {
    await boot(tester, {});
    expect(find.text('Stay informed?'), findsNothing);
    expect(find.text('No care team yet'), findsOneWidget);
  });
}
