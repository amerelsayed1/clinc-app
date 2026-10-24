import 'package:carelink_clinic/src/features/patients/encounter_draft.dart';
import 'package:carelink_clinic/src/features/patients/encounter_page.dart';
import 'package:carelink_clinic/src/features/patients/patients_models.dart';
import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';
import 'patients_helpers.dart';

Future<void> openEnc(WidgetTester tester, FakeApi api, String role, List<String> perms, {Map<String, dynamic>? doctorProfile}) async {
  await tester.binding.setSurfaceSize(const Size(800, 2600)); // tall: everything is on screen without scrolling
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final session = await clinicSession(api, role, perms, doctorProfile: doctorProfile);
  await tester.pumpWidget(MaterialApp(home: EncounterPage(session: session, encounterId: 'e1')));
  await tester.pumpAndSettle();
}

Finder field(String label) => find.widgetWithText(TextField, label);

void main() {
  setUp(() {
    encounterAutosaveDelay = const Duration(milliseconds: 50);
    encounterRetryDelay = const Duration(milliseconds: 200);
  });
  tearDown(() {
    encounterAutosaveDelay = const Duration(milliseconds: 1200);
    encounterRetryDelay = const Duration(seconds: 6);
  });

  group('draft editing', () {
    testWidgets('autosaves with the revision and shows the saved indicator', (tester) async {
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(),
        'PATCH /encounters/e1': (_) => encounterJson(revision: 4),
      });
      await openEnc(tester, api, 'doctor', doctorPerms);
      expect(find.text('All changes saved'), findsOneWidget);
      await tester.enterText(field('Plan'), 'Rest and fluids');
      await tester.pump();
      expect(find.text('Unsaved changes…'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      final body = api.bodies['PATCH /encounters/e1'] as Map;
      expect(body['revision'], 3);
      expect(body['plan'], 'Rest and fluids');
      expect(body['privateNotes'], 'secret'); // doctor sends private notes
      expect(find.text('All changes saved'), findsOneWidget);

      // The next save uses the revision the server returned.
      await tester.enterText(field('Plan'), 'Rest');
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect((api.bodies['PATCH /encounters/e1'] as Map)['revision'], 4);
    });

    testWidgets('revision conflict offers a reload that discards local edits', (tester) async {
      var serverPlan = 'plan from phone';
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(revision: 5, content: {'chiefComplaint': 'Cough', 'history': '', 'diagnosis': '', 'plan': serverPlan, 'privateNotes': '', 'prescriptions': <dynamic>[]}),
        'PATCH /encounters/e1': (_) => throw ApiException(status: 409, code: 'revision_conflict', message: 'changed', details: {'revision': 5}),
      });
      await openEnc(tester, api, 'doctor', doctorPerms);
      await tester.enterText(field('Plan'), 'my local text');
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('Draft changed elsewhere'), findsOneWidget);
      expect(find.byKey(const ValueKey('sign-encounter')), findsOneWidget);
      serverPlan = 'newer plan';
      await tester.tap(find.byKey(const ValueKey('conflict-reload')));
      await tester.pumpAndSettle();
      expect(api.calls.where((c) => c == 'GET /encounters/e1').length, 2);
      expect(find.text('newer plan'), findsOneWidget);
      expect(find.text('my local text'), findsNothing);
      expect(find.text('All changes saved'), findsOneWidget);
    });

    testWidgets('keep mine adopts the server revision and saves again', (tester) async {
      var attempt = 0;
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(),
        'PATCH /encounters/e1': (b) {
          attempt++;
          if (attempt == 1) throw ApiException(status: 409, code: 'revision_conflict', message: 'changed', details: {'revision': 9});
          return encounterJson(revision: 10);
        },
      });
      await openEnc(tester, api, 'doctor', doctorPerms);
      await tester.enterText(field('Plan'), 'mine');
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('conflict-overwrite')));
      await tester.pumpAndSettle();
      final body = api.bodies['PATCH /encounters/e1'] as Map;
      expect(body['revision'], 9);
      expect(body['plan'], 'mine');
      expect(find.text('All changes saved'), findsOneWidget);
    });

    testWidgets('offline: shows Not saved, keeps the text, retries and recovers', (tester) async {
      var online = false;
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(),
        'PATCH /encounters/e1': (_) {
          if (!online) throw ApiException.network();
          return encounterJson(revision: 4);
        },
      });
      await openEnc(tester, api, 'doctor', doctorPerms);
      await tester.enterText(field('Plan'), 'typed offline');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('Not saved - will retry'), findsOneWidget);
      expect(find.text('typed offline'), findsOneWidget);
      online = true;
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('All changes saved'), findsOneWidget);
    });

    testWidgets('blank medication rows are not sent; medications are', (tester) async {
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(),
        'PATCH /encounters/e1': (_) => encounterJson(revision: 4),
      });
      await openEnc(tester, api, 'doctor', doctorPerms);
      await tester.ensureVisible(find.byKey(const ValueKey('rx-add')));
      await tester.tap(find.byKey(const ValueKey('rx-add')));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect((api.bodies['PATCH /encounters/e1'] as Map)['prescriptions'], isEmpty);
      await tester.enterText(field('Medication'), 'Amoxicillin');
      await tester.enterText(field('Dose'), '500 mg');
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect((api.bodies['PATCH /encounters/e1'] as Map)['prescriptions'], [
        {'medication': 'Amoxicillin', 'dose': '500 mg', 'frequency': '', 'duration': '', 'notes': ''}
      ]);
    });

    testWidgets('sign saves, confirms and sends the revision', (tester) async {
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(),
        'GET /encounters/e1/versions': (_) => <dynamic>[],
        'PATCH /encounters/e1': (_) => encounterJson(revision: 4),
        'POST /encounters/e1/sign': (_) => encounterJson(status: 'signed', revision: 4),
      });
      await openEnc(tester, api, 'doctor', doctorPerms);
      await tester.enterText(field('Diagnosis'), 'Bronchitis');
      await tester.ensureVisible(find.byKey(const ValueKey('sign-encounter')));
      await tester.tap(find.byKey(const ValueKey('sign-encounter')));
      await tester.pumpAndSettle();
      expect(api.calls, isNot(contains('POST /encounters/e1/sign'))); // confirm first
      await tester.tap(find.widgetWithText(FilledButton, 'Sign'));
      await tester.pumpAndSettle();
      expect(api.calls.indexOf('PATCH /encounters/e1'), lessThan(api.calls.indexOf('POST /encounters/e1/sign')));
      expect(api.bodies['POST /encounters/e1/sign'], {'revision': 4});
      expect(find.text('Signed · v1'), findsOneWidget);
    });

    testWidgets('signing without a chief complaint is blocked client-side', (tester) async {
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(content: {'chiefComplaint': '', 'history': '', 'diagnosis': '', 'plan': '', 'privateNotes': '', 'prescriptions': <dynamic>[]}),
      });
      await openEnc(tester, api, 'doctor', doctorPerms);
      await tester.ensureVisible(find.byKey(const ValueKey('sign-encounter')));
      await tester.tap(find.byKey(const ValueKey('sign-encounter')));
      await tester.pumpAndSettle();
      expect(find.textContaining('chief complaint'), findsOneWidget);
      expect(api.calls, isNot(contains('POST /encounters/e1/sign')));
    });

    testWidgets('discard asks first, then deletes', (tester) async {
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(),
        'DELETE /encounters/e1': (_) => null,
      });
      await openEnc(tester, api, 'doctor', doctorPerms);
      await tester.ensureVisible(find.byKey(const ValueKey('discard-draft')));
      await tester.tap(find.byKey(const ValueKey('discard-draft')));
      await tester.pumpAndSettle();
      expect(api.calls, isNot(contains('DELETE /encounters/e1')));
      await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('DELETE /encounters/e1'));
    });
  });

  group('permissions', () {
    testWidgets('nurse: records vitals but cannot edit or sign clinical fields, no private notes', (tester) async {
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(authorId: 'doc9', content: {'chiefComplaint': 'Cough', 'history': '', 'diagnosis': '', 'plan': '', 'prescriptions': <dynamic>[]}),
        'POST /encounters/e1/observations': (_) => obsJson('o9', kind: 'heart_rate', value: 80, role: 'nurse'),
      });
      await openEnc(tester, api, 'nurse', nursePerms);
      expect(find.byKey(const ValueKey('sign-encounter')), findsNothing);
      expect(find.byKey(const ValueKey('rx-add')), findsNothing);
      expect(find.widgetWithText(TextField, 'Private notes'), findsNothing);
      expect(tester.widget<TextField>(field('Chief complaint')).readOnly, isTrue);
      expect(find.textContaining('read-only for your role'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('vital-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Heart rate (bpm)').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('vital-value')), '80');
      await tester.tap(find.byKey(const ValueKey('vital-add')));
      await tester.pumpAndSettle();
      expect(api.bodies['POST /encounters/e1/observations'], {'kind': 'heart_rate', 'value': 80.0});
    });

    testWidgets('implausible vitals are rejected before the API', (tester) async {
      final api = FakeApi({'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'}, 'GET /encounters/e1': (_) => encounterJson()});
      await openEnc(tester, api, 'doctor', doctorPerms);
      await tester.enterText(find.byKey(const ValueKey('vital-value')), '700');
      await tester.tap(find.byKey(const ValueKey('vital-add')));
      await tester.pumpAndSettle();
      expect(find.textContaining('must be between'), findsOneWidget);
      expect(api.calls, isNot(contains('POST /encounters/e1/observations')));
    });

    testWidgets('unverified doctor sees a read-only banner and no editing', (tester) async {
      final api = FakeApi({'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'}, 'GET /encounters/e1': (_) => encounterJson()});
      await openEnc(tester, api, 'doctor', unverifiedDoctorPerms, doctorProfile: {'licenseNumber': 'X1', 'verificationStatus': 'pending'});
      expect(find.textContaining('Read-only'), findsOneWidget);
      expect(find.byKey(const ValueKey('sign-encounter')), findsNothing);
      expect(tester.widget<TextField>(field('Plan')).readOnly, isTrue);
      expect(find.byKey(const ValueKey('vital-add')), findsNothing); // no vitals.write either
    });

    testWidgets('only the author can amend; others can still publish when they can write', (tester) async {
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(status: 'signed', authorId: 'someone-else'),
        'GET /encounters/e1/versions': (_) => <dynamic>[],
      });
      await openEnc(tester, api, 'doctor', doctorPerms);
      expect(find.byKey(const ValueKey('amend')), findsNothing);
      expect(find.byKey(const ValueKey('publish')), findsOneWidget);
    });
  });

  group('signed encounters', () {
    final signedContent = {'chiefComplaint': 'Cough', 'history': '', 'diagnosis': 'Bronchitis', 'plan': 'Rest', 'privateNotes': 'secret', 'prescriptions': [
      {'medication': 'Amoxicillin', 'dose': '500 mg', 'frequency': 'tid', 'duration': '5 d', 'notes': ''}
    ]};

    testWidgets('amend sends only changed fields, the base version and a reason', (tester) async {
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(status: 'signed', content: signedContent),
        'GET /encounters/e1/versions': (_) => <dynamic>[],
        'POST /encounters/e1/amend': (_) => encounterJson(status: 'signed', version: 2, content: {...signedContent, 'plan': 'Rest and fluids'}, versionMeta: {
              'version': 2, 'authorName': 'Dr Test', 'createdAt': '2026-10-24T10:00:00Z', 'amendmentReason': 'Added fluids', 'changedFields': ['plan']
            }),
      });
      await openEnc(tester, api, 'doctor', doctorPerms);
      await tester.tap(find.byKey(const ValueKey('amend')));
      await tester.pumpAndSettle();
      expect(find.textContaining('creates version 2'), findsOneWidget);

      // Needs a reason and a change.
      await tester.tap(find.byKey(const ValueKey('save-amendment')));
      await tester.pumpAndSettle();
      expect(api.calls, isNot(contains('POST /encounters/e1/amend')));
      await tester.enterText(find.byKey(const ValueKey('amend-reason')), 'Added fluids');
      await tester.tap(find.byKey(const ValueKey('save-amendment')));
      await tester.pumpAndSettle();
      expect(find.text('Nothing was changed.'), findsOneWidget);

      await tester.enterText(field('Plan'), 'Rest and fluids');
      await tester.tap(find.byKey(const ValueKey('save-amendment')));
      await tester.pumpAndSettle();
      expect(api.bodies['POST /encounters/e1/amend'], {
        'baseVersion': 1,
        'reason': 'Added fluids',
        'changes': {'plan': 'Rest and fluids'},
      });
      expect(find.text('Signed · v2'), findsOneWidget);
    });

    testWidgets('publish then unpublish', (tester) async {
      var published = false;
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(status: 'signed', content: signedContent),
        'GET /encounters/e1/versions': (_) => <dynamic>[],
        'POST /encounters/e1/publish': (_) {
          published = true;
          return encounterJson(status: 'signed', published: 1, content: signedContent);
        },
        'POST /encounters/e1/unpublish': (_) {
          published = false;
          return encounterJson(status: 'signed', content: signedContent);
        },
      });
      await openEnc(tester, api, 'doctor', doctorPerms);
      expect(find.byKey(const ValueKey('unpublish')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('publish')));
      await tester.pumpAndSettle();
      expect(published, isTrue);
      expect(api.bodies['POST /encounters/e1/publish'], <String, dynamic>{});
      expect(find.text('Published v1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('unpublish')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('POST /encounters/e1/unpublish'));
      expect(find.byKey(const ValueKey('publish')), findsOneWidget);
    });

    testWidgets('version history picker and amendment banner', (tester) async {
      final v1 = {'version': 1, 'authorName': 'Dr Test', 'createdAt': '2026-10-24T09:00:00Z', 'amendmentReason': null, 'changedFields': <String>[], 'content': {...signedContent, 'plan': 'old plan'}};
      final v2 = {'version': 2, 'authorName': 'Dr Test', 'createdAt': '2026-10-24T10:00:00Z', 'amendmentReason': 'Fix plan', 'changedFields': ['plan'], 'content': signedContent};
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(status: 'signed', version: 2, content: signedContent, versionMeta: v2),
        'GET /encounters/e1/versions': (_) => [v1, v2],
      });
      await openEnc(tester, api, 'doctor', doctorPerms);
      expect(find.textContaining('amended by Dr Test: "Fix plan" - changed Plan'), findsOneWidget);
      expect(find.text('Rest'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('version-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('v1 ·').last);
      await tester.pumpAndSettle();
      expect(find.text('old plan'), findsOneWidget);
    });

    testWidgets('prescription sheet opens from a signed encounter with medications', (tester) async {
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(status: 'signed', content: signedContent),
        'GET /encounters/e1/versions': (_) => <dynamic>[],
        'GET /encounters/e1/prescription': (_) => {
              'clinic': 'Nile Clinic',
              'doctor': {'fullName': 'Dr Test', 'licenseNumber': 'L-1'},
              'patient': {'fullName': 'Salma Ali', 'dateOfBirth': '1990-05-01', 'patientNumber': 12},
              'date': '2026-10-24T09:30:00Z',
              'version': 1,
              'items': signedContent['prescriptions'],
            },
      });
      await openEnc(tester, api, 'doctor', doctorPerms);
      await tester.tap(find.byKey(const ValueKey('open-prescription')));
      await tester.pumpAndSettle();
      expect(find.text('Nile Clinic'), findsOneWidget);
      expect(find.text('Amoxicillin'), findsOneWidget);
      expect(find.textContaining('Licence L-1'), findsOneWidget);
    });
  });

  group('observations', () {
    testWidgets('void asks for a reason; nurses can void only their own entries', (tester) async {
      final api = FakeApi({
        'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'},
        'GET /encounters/e1': (_) => encounterJson(authorId: 'doc9', observations: [
              obsJson('mine', by: 'u1', role: 'nurse'),
              obsJson('theirs', kind: 'heart_rate', value: 90, by: 'other', role: 'nurse'),
              obsJson('gone', kind: 'spo2', value: 99, by: 'u1', voided: true),
            ]),
        'POST /encounters/e1/observations/mine/void': (_) => {'ok': true},
      });
      await openEnc(tester, api, 'nurse', nursePerms);
      expect(find.textContaining('1 voided entry'), findsOneWidget);
      final mine = find.byKey(const ValueKey('vital-mine'));
      final theirs = find.byKey(const ValueKey('vital-theirs'));
      expect(tester.widget<InputChip>(mine).onDeleted, isNotNull);
      expect(tester.widget<InputChip>(theirs).onDeleted, isNull);
      await tester.tap(find.descendant(of: mine, matching: find.byIcon(Icons.cancel_outlined)));
      await tester.pumpAndSettle();
      expect(api.calls, isNot(contains('POST /encounters/e1/observations/mine/void')));
      await tester.enterText(find.byType(TextField).last, 'typo');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Void entry'));
      await tester.pumpAndSettle();
      expect(api.bodies['POST /encounters/e1/observations/mine/void'], {'reason': 'typo'});
    });
  });

  group('models', () {
    test('changesFrom lists only differing fields and respects private notes', () {
      const before = EncContent(chiefComplaint: 'a', plan: 'p', privateNotes: 'x', prescriptions: [Rx(medication: 'M')]);
      final after = before.copyWith(plan: 'p2', privateNotes: 'y');
      expect(after.changesFrom(before, includePrivate: true), {'plan': 'p2', 'privateNotes': 'y'});
      expect(after.changesFrom(before, includePrivate: false), {'plan': 'p2'});
      expect(before.changesFrom(before, includePrivate: true), isEmpty);
    });

    test('draft json skips blank medication rows and omits private notes for non-doctors', () {
      const c = EncContent(chiefComplaint: 'a', privateNotes: 'x', prescriptions: [Rx(medication: ' '), Rx(medication: 'M', dose: '1')]);
      final j = c.toDraftJson(includePrivate: false);
      expect(j.containsKey('privateNotes'), isFalse);
      expect((j['prescriptions'] as List).length, 1);
      expect(c.hasIncompletePrescription, isFalse);
      expect(const EncContent(prescriptions: [Rx(dose: '1')]).hasIncompletePrescription, isTrue);
    });
  });
}
