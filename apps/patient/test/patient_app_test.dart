import 'package:carelink_patient/src/app.dart';
import 'package:carelink_patient/src/patient_repository.dart';
import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

Future<FakeApi> boot(WidgetTester tester, FakeApi api) async {
  final auth = AuthController(api);
  await auth.bootstrap();
  await tester.pumpWidget(PatientApp(auth: auth, repository: PatientRepository(api)));
  await tester.pump();
  await tester.pump();
  return api;
}

void main() {
  testWidgets('shows the phone login screen when signed out', (tester) async {
    await boot(tester, FakeApi({}, signedIn: false));
    expect(find.text('CareLink'), findsOneWidget);
    expect(find.text('Send code'), findsOneWidget);
  });

  testWidgets('asks for a name before claiming when fullName is missing', (tester) async {
    final api = await boot(tester, FakeApi({'GET /me': (_) => me(fullName: null)}));
    expect(find.text('Welcome to CareLink'), findsOneWidget);
    expect(api.calls, ['GET /me']); // no claim yet
  });

  testWidgets('claims once, then shows invitations with Accept / Decline', (tester) async {
    final api = await boot(
      tester,
      FakeApi({
        'GET /me': (_) => me(),
        'POST /patient/claim': (_) => [
              {'id': 'r1', 'status': 'invited', 'workspaceName': 'Nile Clinic', 'doctorName': 'Dr. Omar', 'createdAt': '2026-10-01T10:00:00Z', 'endedAt': null},
              {'id': 'r2', 'status': 'active', 'workspaceName': 'Cairo Care', 'doctorName': 'Dr. Mona', 'createdAt': '2026-09-01T10:00:00Z', 'endedAt': null},
            ],
      }),
    );
    expect(api.calls.where((c) => c == 'POST /patient/claim').length, 1);
    expect(find.text('Dr. Omar'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(find.text('End relationship'), findsOneWidget);
  });

  testWidgets('empty care team explains that a doctor will invite the patient', (tester) async {
    await boot(tester, FakeApi({'GET /me': (_) => me(), 'POST /patient/claim': (_) => []}));
    expect(find.text('No care team yet'), findsOneWidget);
    expect(find.textContaining('their invitation will appear here'), findsOneWidget);
  });

  testWidgets('ending a relationship asks for confirmation', (tester) async {
    final api = await boot(
      tester,
      FakeApi({
        'GET /me': (_) => me(),
        'POST /patient/claim': (_) => [
              {'id': 'r2', 'status': 'active', 'workspaceName': 'Cairo Care', 'doctorName': 'Dr. Mona', 'createdAt': '2026-09-01T10:00:00Z', 'endedAt': null},
            ],
        'POST /patient/relationships/r2/end': (_) => {'ok': true},
        'GET /patient/relationships': (_) => [],
      }),
    );
    await tester.tap(find.text('End relationship'));
    await tester.pumpAndSettle();
    expect(find.text('End care relationship?'), findsOneWidget);
    expect(api.calls, isNot(contains('POST /patient/relationships/r2/end')));
    await tester.tap(find.widgetWithText(FilledButton, 'End relationship'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /patient/relationships/r2/end'));
  });
}
