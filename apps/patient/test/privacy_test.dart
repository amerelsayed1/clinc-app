import 'dart:convert';

import 'package:carelink_patient/src/app.dart';
import 'package:carelink_patient/src/patient_repository.dart';
import 'package:carelink_patient/src/privacy_page.dart';
import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

class _Auth implements DeviceAuthenticator {
  bool ok = true;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<bool> authenticate(String reason) async => ok;
}

const _bundle = {
  'format': 'carelink-patient-export/1',
  'profile': {'phone': '+201000000001'},
  'encounters': [
    {'id': 'e1', 'chiefComplaint': 'Cough'},
  ],
  'documents': [
    {'id': 'd1'},
    {'id': 'd2'},
  ],
};

Future<FakeApi> boot(WidgetTester tester, Map<String, Object? Function(Object?)> routes, {AppLockController? lock}) async {
  final api = FakeApi({
    'GET /me': (_) => me(),
    'POST /patient/claim': (_) => [
          {'id': 'r1', 'status': 'active', 'workspaceName': 'Cairo Care', 'doctorName': 'Dr. Mona', 'createdAt': '2026-09-01T10:00:00Z', 'endedAt': null},
        ],
    'GET /notification-consent': (_) => {'required': false, 'push': false, 'sms': false},
    'GET /notification-preferences': (_) => {'locale': 'en', 'explicit': true, 'channels': {}, 'quietHours': null, 'timezone': 'UTC', 'disabledTypes': [], 'types': [], 'consent': {'required': false, 'push': false, 'sms': false}},
    'GET /notifications/unread-count': (_) => {'count': 0},
    'GET /patient/access-requests': (_) => [],
    ...routes,
  });
  final auth = AuthController(api);
  await auth.bootstrap();
  await tester.pumpWidget(PatientApp(auth: auth, repository: PatientRepository(api), lock: lock));
  await tester.pumpAndSettle();
  return api;
}

Future<void> openPrivacy(WidgetTester tester) async {
  await tester.tap(find.text('Account'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Privacy and data'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('exports my data and offers save/share and copy', (tester) async {
    final api = await boot(tester, {
      'POST /patient/export': (_) => _bundle,
      'GET /patient/correction-requests': (_) => [],
    });
    await openPrivacy(tester);
    expect(find.text('Privacy and data'), findsWidgets);
    await tester.tap(find.text('Prepare my data'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /patient/export'));
    expect(find.byKey(const Key('export-summary')), findsOneWidget);
    expect(find.textContaining('1 consultation, 2 documents'), findsOneWidget);
    expect(find.text('Save or share file'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('the share action receives the exact JSON bundle', (tester) async {
    String? shared;
    String? name;
    final api = FakeApi({'POST /patient/export': (_) => _bundle, 'GET /patient/correction-requests': (_) => []});
    await tester.pumpWidget(MaterialApp(home: PrivacyPage(repository: PatientRepository(api), sharer: (n, j) async {
      name = n;
      shared = j;
    })));
    await tester.tap(find.text('Prepare my data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save or share file'));
    await tester.pumpAndSettle();
    expect(name, startsWith('carelink-my-data-'));
    expect(name, endsWith('.json'));
    expect(jsonDecode(shared!), _bundle);
  });

  testWidgets('shows the rate limit message when exporting too often', (tester) async {
    final api = FakeApi({
      'POST /patient/export': (_) => throw ApiException(status: 429, code: 'rate_limited', message: 'You can export your data a few times per hour. Try again later.'),
      'GET /patient/correction-requests': (_) => [],
    });
    await tester.pumpWidget(MaterialApp(home: PrivacyPage(repository: PatientRepository(api))));
    await tester.tap(find.text('Prepare my data'));
    await tester.pumpAndSettle();
    expect(find.textContaining('a few times per hour'), findsOneWidget);
    expect(find.text('Save or share file'), findsNothing);
  });

  testWidgets('requests a correction on a clinic record and lists the outcome', (tester) async {
    Map<String, dynamic>? sent;
    var requests = <Map<String, dynamic>>[];
    final api = FakeApi({
      'GET /patient/correction-requests': (_) => requests,
      'GET /patient/encounters': (_) => [
            {'id': 'e1', 'encounterDate': '2026-10-01T09:00:00Z', 'clinicName': 'Cairo Care', 'doctorName': 'Dr. Mona'},
          ],
      'GET /patient/documents': (_) => [
            {'id': 'd1', 'source': 'clinician', 'title': 'CBC', 'category': 'lab_result'},
            {'id': 'd2', 'source': 'patient', 'title': 'My photo', 'category': 'other'},
          ],
      'GET /patient/relationships': (_) => [
            {'id': 'r1', 'status': 'active', 'workspaceName': 'Cairo Care'},
          ],
      'POST /patient/correction-requests': (b) {
        sent = b as Map<String, dynamic>;
        requests = [
          {'id': 'c1', 'targetType': 'encounter', 'description': sent!['description'], 'status': 'rejected', 'resolutionNote': 'Recorded correctly', 'clinicName': 'Cairo Care', 'createdAt': '2026-10-02T09:00:00Z'},
        ];
        return {'id': 'c1', 'status': 'open'};
      },
    });
    await tester.pumpWidget(MaterialApp(home: PrivacyPage(repository: PatientRepository(api))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Request a correction'));
    await tester.pumpAndSettle();
    expect(find.text('Consultation 2026-10-01'), findsOneWidget);
    expect(find.text('CBC'), findsOneWidget);
    expect(find.text('My photo'), findsNothing, reason: 'own uploads are edited by the patient, not corrected by the clinic');
    expect(find.text('My details at Cairo Care'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send to clinic')).onPressed, isNull);
    await tester.tap(find.text('Consultation 2026-10-01'));
    await tester.enterText(find.byType(TextField), 'The diagnosis is wrong');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send to clinic'));
    await tester.pumpAndSettle();
    expect(sent, {'targetType': 'encounter', 'targetId': 'e1', 'description': 'The diagnosis is wrong'});
    expect(find.text('My requests'), findsOneWidget);
    expect(find.textContaining('Reply: Recorded correctly'), findsOneWidget);
  });

  testWidgets('app lock: turning it on requires authentication and the app locks when backgrounded', (tester) async {
    final auth = _Auth();
    final lock = AppLockController(authenticator: auth, store: MemoryLockSettingsStore());
    await boot(tester, {'GET /patient/correction-requests': (_) => []}, lock: lock);
    await openPrivacy(tester);
    auth.ok = false;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(lock.enabled, isFalse);
    auth.ok = true;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(lock.enabled, isTrue);

    auth.ok = false; // the user cannot pass the prompt
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pumpAndSettle();
    expect(find.text('CareLink is locked'), findsOneWidget);
    expect(find.text('Privacy and data'), findsNothing, reason: 'no clinical UI is painted while locked');
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump();
    auth.ok = true;
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Privacy and data'), findsWidgets);
  });

  testWidgets('the signed-in app is covered in the app switcher and blocks screenshots', (tester) async {
    final flags = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SecureScreen.channel, (call) async {
      flags.add((call.arguments as Map)['secure'] as bool);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SecureScreen.channel, null));
    await boot(tester, {});
    expect(flags, contains(true));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.byKey(const ValueKey('privacy-cover')), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byKey(const ValueKey('privacy-cover')), findsNothing);
  });
}
