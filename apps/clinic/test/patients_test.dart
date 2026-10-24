import 'package:carelink_clinic/src/features/patients/patient_detail_page.dart';
import 'package:carelink_clinic/src/features/patients/patient_tabs.dart';
import 'package:carelink_clinic/src/features/patients/patients_models.dart';
import 'package:carelink_clinic/src/features/patients/patients_page.dart';
import 'package:carelink_clinic/src/session.dart';
import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';
import 'patients_helpers.dart';

Future<void> pumpPage(WidgetTester tester, Widget home) async {
  await tester.pumpWidget(MaterialApp(home: home));
  await tester.pumpAndSettle();
}

void main() {
  group('Patients list', () {
    late QueryApi api;
    late ClinicSession session;

    Future<void> open(WidgetTester tester, String role, List<String> perms) async {
      api = QueryApi({
        'GET /patients': (_) => [patientJson(), patientJson(id: 'p2', name: 'Omar Hassan', number: 13, status: 'invited', phone: '+201002223333')],
      });
      session = await clinicSession(api, role, perms);
      await pumpPage(tester, Scaffold(body: PatientsPage(session: session, searchDebounce: const Duration(milliseconds: 10))));
    }

    testWidgets('lists patients with status badges', (tester) async {
      await open(tester, 'receptionist', receptionistPerms);
      expect(find.text('Salma Ali'), findsOneWidget);
      expect(find.text('Omar Hassan'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Invited'), findsOneWidget);
      expect(find.textContaining('P-00012'), findsOneWidget);
      expect(api.lastQuery['GET /patients']!['status'], 'open');
    });

    testWidgets('read-only role has no Register button', (tester) async {
      await open(tester, 'nurse', ['patients.read']);
      expect(find.byKey(const ValueKey('register-patient')), findsNothing);
      await open(tester, 'receptionist', receptionistPerms);
      expect(find.byKey(const ValueKey('register-patient')), findsOneWidget);
    });

    testWidgets('search sends q and Ended filter sends status=ended', (tester) async {
      await open(tester, 'receptionist', receptionistPerms);
      await tester.enterText(find.byKey(const ValueKey('patient-search')), 'sal');
      await tester.pumpAndSettle();
      expect(api.lastQuery['GET /patients']!['q'], 'sal');
      await tester.tap(find.text('Ended'));
      await tester.pumpAndSettle();
      expect(api.lastQuery['GET /patients']!['status'], 'ended');
    });
  });

  group('Register / edit', () {
    testWidgets('duplicate warning needs an explicit override', (tester) async {
      var attempts = 0;
      final api = QueryApi({
        'GET /patients': (_) => <dynamic>[],
        'GET /patients/p9': (_) => patientJson(id: 'p9', name: 'New Person'),
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /appointments': (_) => <dynamic>[],
        'POST /patients': (body) {
          attempts++;
          if (attempts == 1) throw ApiException(status: 409, code: 'possible_duplicate', message: 'dup');
          return patientJson(id: 'p9', name: 'New Person');
        },
      });
      final session = await clinicSession(api, 'receptionist', receptionistPerms);
      await pumpPage(tester, Scaffold(body: PatientsPage(session: session)));
      await tester.tap(find.byKey(const ValueKey('register-patient')));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Full name'), 'New Person');
      await tester.enterText(find.widgetWithText(TextField, 'Phone number'), '+201005556666');
      await tester.tap(find.byKey(const ValueKey('save-patient')));
      await tester.pumpAndSettle();
      expect(api.bodies['POST /patients'], {'phone': '+201005556666', 'fullName': 'New Person'});
      expect(find.textContaining('already exists'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('register-anyway')));
      await tester.pumpAndSettle();
      expect(api.bodies['POST /patients'], {'phone': '+201005556666', 'fullName': 'New Person', 'confirmNotDuplicate': true});
      // Lands on the new patient's detail page.
      expect(find.text('New Person'), findsWidgets);
      expect(find.text('Encounters'), findsNothing); // receptionist: no clinical tab
    });

    testWidgets('rejects a bad phone before calling the API', (tester) async {
      final api = QueryApi({'GET /patients': (_) => <dynamic>[]});
      final session = await clinicSession(api, 'receptionist', receptionistPerms);
      await pumpPage(tester, Scaffold(body: PatientsPage(session: session)));
      await tester.tap(find.byKey(const ValueKey('register-patient')));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Full name'), 'Someone');
      await tester.enterText(find.widgetWithText(TextField, 'Phone number'), '12345');
      await tester.tap(find.byKey(const ValueKey('save-patient')));
      await tester.pumpAndSettle();
      expect(api.calls, isNot(contains('POST /patients')));
      expect(find.textContaining('international format'), findsWidgets);
    });

    testWidgets('edit sends demographics; phone is locked', (tester) async {
      final api = QueryApi({
        'GET /patients/p1': (_) => patientJson(),
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /appointments': (_) => <dynamic>[],
        'PATCH /patients/p1': (_) => patientJson(name: 'Salma A. Ali'),
      });
      final session = await clinicSession(api, 'receptionist', receptionistPerms);
      await pumpPage(tester, PatientDetailPage(session: session, patientId: 'p1'));
      await tester.tap(find.byKey(const ValueKey('patient-menu')));
      await tester.pumpAndSettle();
      expect(find.text('End relationship'), findsNothing); // needs relationships.manage
      await tester.tap(find.text('Edit details'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Phone number')).enabled, isFalse);
      await tester.enterText(find.widgetWithText(TextField, 'Full name'), 'Salma A. Ali');
      await tester.tap(find.byKey(const ValueKey('save-patient')));
      await tester.pumpAndSettle();
      expect(api.bodies['PATCH /patients/p1'], {'fullName': 'Salma A. Ali', 'dateOfBirth': '1990-05-01', 'sex': 'female'});
      expect(find.text('Salma A. Ali'), findsWidgets);
    });
  });

  group('Patient detail', () {
    Map<String, Object? Function(Object?)> routes() => {
          'GET /patients/p1': (_) => patientJson(),
          'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
          'GET /appointments': (_) => [apptJson('a1', 'completed')],
          'GET /patients/p1/encounters': (_) => [
                {'id': 'e1', 'encounterDate': '2026-10-20T09:00:00Z', 'status': 'signed', 'currentVersion': 2, 'published': true, 'authorName': 'Dr Test', 'chiefComplaint': 'Cough', 'diagnosis': 'Bronchitis'},
                {'id': 'e2', 'encounterDate': '2026-10-24T09:00:00Z', 'status': 'draft', 'currentVersion': 1, 'published': false, 'authorName': 'Dr Test', 'chiefComplaint': '', 'diagnosis': ''},
              ],
          'GET /patients/p1/observations': (_) => {
                'kind': 'weight_kg',
                'unit': 'kg',
                'points': [
                  {'id': 'o1', 'value': 70, 'measuredAt': '2026-10-01T09:00:00Z'},
                  {'id': 'o2', 'value': 72.5, 'measuredAt': '2026-10-20T09:00:00Z'},
                ],
              },
        };

    testWidgets('receptionist sees no clinical content', (tester) async {
      final api = FakeApi(routes());
      final session = await clinicSession(api, 'receptionist', receptionistPerms);
      await pumpPage(tester, PatientDetailPage(session: session, patientId: 'p1'));
      expect(find.text('Encounters'), findsNothing);
      expect(find.text('Vitals trend'), findsNothing);
      expect(find.text('Appointments'), findsOneWidget);
      expect(api.calls, isNot(contains('GET /patients/p1/observations')));
      expect(api.calls, isNot(contains('GET /patients/p1/encounters')));
    });

    testWidgets('doctor sees Overview with vitals trend and an Encounters tab', (tester) async {
      final api = FakeApi(routes());
      final session = await clinicSession(api, 'doctor', doctorPerms);
      await pumpPage(tester, PatientDetailPage(session: session, patientId: 'p1'));
      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('Encounters'), findsOneWidget);
      expect(find.text('Vitals trend'), findsOneWidget);
      expect(find.textContaining('72.5 kg'), findsOneWidget);
      await tester.tap(find.text('Encounters'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Bronchitis'), findsOneWidget);
      expect(find.text('Signed v2'), findsOneWidget);
      expect(find.text('Published'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      expect(find.byKey(const ValueKey('new-encounter')), findsOneWidget);
    });

    testWidgets('nurse sees encounters but cannot start one', (tester) async {
      final api = FakeApi(routes());
      final session = await clinicSession(api, 'nurse', nursePerms);
      await pumpPage(tester, PatientDetailPage(session: session, patientId: 'p1'));
      await tester.tap(find.text('Encounters'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Bronchitis'), findsOneWidget);
      expect(find.byKey(const ValueKey('new-encounter')), findsNothing);
    });

    testWidgets('tabs come from the extension list and are filtered by permission', (tester) async {
      final api = FakeApi(routes());
      final session = await clinicSession(api, 'receptionist', receptionistPerms);
      final tabs = [
        PatientTab(label: 'Basics', builder: (c, s, p) => Text('basics for ${p.name} ${p.status} ${p.hasAccount}')),
        PatientTab(label: 'Secret', requiredPermissions: const ['clinical.read'], builder: (c, s, p) => const Text('secret')),
        PatientTab(label: 'Docs', requiredPermissions: const ['documents.upload'], builder: (c, s, p) => Text('docs ${p.relationshipId}')),
      ];
      await pumpPage(tester, PatientDetailPage(session: session, patientId: 'p1', tabs: tabs));
      expect(find.text('basics for Salma Ali active false'), findsOneWidget);
      expect(find.text('Secret'), findsNothing);
      await tester.tap(find.text('Docs'));
      await tester.pumpAndSettle();
      expect(find.text('docs p1'), findsOneWidget);
    });

    testWidgets('end relationship asks for confirmation first', (tester) async {
      final api = FakeApi({...routes(), 'POST /patients/p1/end': (_) => {'ok': true}});
      final session = await clinicSession(api, 'doctor', doctorPerms);
      await pumpPage(tester, PatientDetailPage(session: session, patientId: 'p1'));
      await tester.tap(find.byKey(const ValueKey('patient-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('End relationship'));
      await tester.pumpAndSettle();
      expect(api.calls, isNot(contains('POST /patients/p1/end')));
      await tester.tap(find.widgetWithText(FilledButton, 'End relationship'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('POST /patients/p1/end'));
    });
  });

  test('Patient model and status labels', () {
    final p = Patient.fromJson(patientJson(status: 'ended'));
    expect(p.isEnded, isTrue);
    expect(statusLabel('invited'), contains('Awaiting'));
    expect(patientNo(7), 'P-00007');
  });
}
