import 'package:carelink_clinic/src/clinic_repository.dart';
import 'package:carelink_clinic/src/feature.dart';
import 'package:carelink_clinic/src/features/audit/audit_api.dart';
import 'package:carelink_clinic/src/features/audit/audit_feature.dart';
import 'package:carelink_clinic/src/features/audit/audit_models.dart';
import 'package:carelink_clinic/src/features/audit/audit_page.dart';
import 'package:carelink_clinic/src/features/data_requests/data_requests_api.dart';
import 'package:carelink_clinic/src/features/data_requests/data_requests_feature.dart';
import 'package:carelink_clinic/src/features/data_requests/data_requests_page.dart';
import 'package:carelink_clinic/src/features/shared_with_me/shared_api.dart';
import 'package:carelink_clinic/src/features/shared_with_me/shared_models.dart';
import 'package:carelink_clinic/src/features/shared_with_me/shared_with_me_feature.dart';
import 'package:carelink_clinic/src/features/shared_with_me/shared_with_me_page.dart';
import 'package:carelink_clinic/src/session.dart';
import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

Future<ClinicSession> sessionFor(FakeApi api, String role, List<String> perms) async {
  final auth = AuthController(api);
  api.routes['GET /me'] = (_) => me(member: membership(role, perms));
  await auth.bootstrap();
  return ClinicSession(auth: auth, repository: ClinicRepository(api), kit: NotificationsKit(api));
}

Map<String, dynamic> grantJson() => {
  'id': 'g1',
  'scope': {
    'categories': ['lab_result', 'imaging'],
    'from': '2026-01-01',
  },
  'purpose': 'Second opinion',
  'createdAt': '2026-10-01T10:00:00Z',
  'expiresAt': '2026-12-01T10:00:00Z',
  'patientName': 'Salma Hassan',
  'relationshipId': 'r1',
};

Map<String, dynamic> requestJson(String id, String status) => {
  'id': id,
  'status': status,
  'scope': {
    'categories': ['report'],
  },
  'purpose': 'Review prior work-up',
  'requestedDays': 30,
  'sensitive': false,
  'createdAt': '2026-10-02T10:00:00Z',
  'doctorName': 'Dr Test',
};

void main() {
  group('request body', () {
    test('category scope with optional dates', () {
      expect(buildAccessRequestBody(categories: ['lab_result'], purpose: ' Check ', days: 30, from: '2026-01-01', to: ''), {
        'scope': {
          'categories': ['lab_result'],
          'from': '2026-01-01',
        },
        'purpose': 'Check',
        'days': 30,
      });
    });
    test('consultations are sensitive: capped at 14 days; otherwise 90', () {
      expect(buildAccessRequestBody(categories: ['encounters', 'report'], purpose: 'abc', days: 60)['days'], 14);
      expect(buildAccessRequestBody(categories: ['report'], purpose: 'abc', days: 200)['days'], 90);
      expect(buildAccessRequestBody(categories: ['report'], purpose: 'abc', days: 0)['days'], 1);
    });
    test('scope text', () {
      expect(
        ShareScope.fromJson({
          'categories': ['lab_result'],
          'from': '2026-01-01',
        }).text,
        'Lab results (2026-01-01 to any)',
      );
      expect(
        ShareScope.fromJson({
          'items': [{}, {}],
        }).text,
        '2 selected records',
      );
    });
  });

  group('feature gating', () {
    test('permissions required per feature', () async {
      final api = FakeApi({});
      final doctor = await sessionFor(api, 'doctor', doctorPerms);
      final recep = await sessionFor(FakeApi({}), 'receptionist', receptionistPerms);
      final nurse = await sessionFor(FakeApi({}), 'nurse', roleDefaultsNurse);
      final reg = FeatureRegistry();
      registerSharedWithMe(reg);
      registerAudit(reg);
      registerDataRequests(reg);
      Set<String> ids(ClinicSession s) => reg.visibleFor(s).map((f) => f.id).toSet();
      expect(ids(doctor), {'shared', 'audit', 'data-requests'});
      expect(ids(recep), isEmpty);
      expect(ids(nurse), {'shared'});
    });
  });

  group('Shared with me', () {
    late FakeApi api;
    testWidgets('lists grants, opens items with banner and provenance badges', (tester) async {
      api = FakeApi({
        'GET /shared-with-me': (_) => [grantJson()],
        'GET /shared-with-me/g1/items': (_) => [
          {
            'type': 'document',
            'id': 'd1',
            'category': 'lab_result',
            'date': '2026-09-01',
            'title': 'CBC',
            'clinicName': null,
            'provenance': 'patient_submitted_unverified',
          },
          {
            'type': 'encounter',
            'id': 'e1',
            'category': 'encounters',
            'date': '2026-08-01',
            'title': 'Cardiology',
            'clinicName': 'Other Clinic',
            'provenance': 'clinician_authored',
          },
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SharedWithMePage(api: SharedApi(api))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Salma Hassan'), findsOneWidget);
      expect(find.textContaining('Second opinion'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('grant-g1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shared-banner')), findsOneWidget);
      expect(find.textContaining('Shared by patient Salma Hassan'), findsOneWidget);
      expect(find.text('Patient-submitted · unverified'), findsOneWidget);
      expect(find.text('Clinician-authored'), findsOneWidget);
    });

    testWidgets('revoked grant (404 on items) shows a graceful message', (tester) async {
      api = FakeApi({
        'GET /shared-with-me/g1/items': (_) => throw ApiException(status: 404, code: 'not_found', message: 'Shared record not found'),
      });
      final g = SharedGrant.fromJson(grantJson());
      await tester.pumpWidget(
        MaterialApp(
          home: SharedGrantPage(api: SharedApi(api), grant: g),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-gone')), findsOneWidget);
      expect(find.textContaining('revoked'), findsOneWidget);
    });

    testWidgets('revoked document/encounter (404) is graceful', (tester) async {
      api = FakeApi({
        'GET /shared-with-me/g1/encounters/e1': (_) => throw ApiException(status: 404, code: 'not_found', message: 'x'),
        'GET /shared-with-me/g1/documents/d1': (_) => throw ApiException(status: 404, code: 'not_found', message: 'x'),
      });
      final g = SharedGrant.fromJson(grantJson());
      await tester.pumpWidget(
        MaterialApp(
          home: SharedEncounterPage(api: SharedApi(api), grant: g, itemId: 'e1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-gone')), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: SharedDocumentPage(api: SharedApi(api), grant: g, itemId: 'd1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-gone')), findsOneWidget);
    });

    testWidgets('shared encounter shows banner and published summary', (tester) async {
      api = FakeApi({
        'GET /shared-with-me/g1/encounters/e1': (_) => {
          'id': 'e1',
          'provenance': 'clinician_authored',
          'encounterDate': '2026-08-01T00:00:00Z',
          'clinicName': 'Other Clinic',
          'doctorName': 'Dr X',
          'version': 2,
          'chiefComplaint': 'Chest pain',
          'diagnosis': 'Angina',
          'plan': 'Rest',
          'prescriptions': [
            {'medication': 'Aspirin', 'dose': '75mg', 'frequency': 'daily', 'duration': '30d', 'notes': ''},
          ],
          'vitals': [
            {'kind': 'heart_rate', 'value': 80, 'measuredAt': '2026-08-01T00:00:00Z'},
          ],
        },
      });
      final g = SharedGrant.fromJson(grantJson());
      await tester.pumpWidget(
        MaterialApp(
          home: SharedEncounterPage(api: SharedApi(api), grant: g, itemId: 'e1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shared-banner')), findsOneWidget);
      expect(find.text('Chest pain'), findsOneWidget);
      expect(find.textContaining('Aspirin · 75mg'), findsOneWidget);
      expect(find.text('heart rate: 80'), findsOneWidget);
    });

    testWidgets('shared document fetches a signed link per page', (tester) async {
      api = FakeApi({
        'GET /shared-with-me/g1/documents/d1': (_) => {
          'id': 'd1',
          'provenance': 'patient_submitted_unverified',
          'category': 'lab_result',
          'title': 'CBC',
          'notes': '',
          'documentDate': '2026-09-01',
          'createdAt': '2026-09-02T00:00:00Z',
          'pages': [
            {'page': 1, 'mime': 'application/pdf'},
            {'page': 2, 'mime': 'application/pdf'},
          ],
        },
        'GET /shared-with-me/g1/documents/d1/pages/1/link': (_) => {'path': '/files/t1'},
        'GET /shared-with-me/g1/documents/d1/pages/2/link': (_) => {'path': '/files/t2'},
      });
      final g = SharedGrant.fromJson(grantJson());
      await tester.pumpWidget(
        MaterialApp(
          home: SharedDocumentPage(api: SharedApi(api), grant: g, itemId: 'd1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        api.calls,
        containsAll(['GET /shared-with-me/g1/documents/d1/pages/1/link', 'GET /shared-with-me/g1/documents/d1/pages/2/link']),
      );
      expect(find.byKey(const ValueKey('shared-banner')), findsOneWidget);
      expect(find.textContaining('cannot be previewed'), findsNWidgets(2));
    });

    testWidgets('empty list message', (tester) async {
      api = FakeApi({'GET /shared-with-me': (_) => <Object>[]});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SharedWithMePage(api: SharedApi(api))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing is currently shared'), findsOneWidget);
    });
  });

  group('AccessRequestsPanel', () {
    testWidgets('doctor sends a request with sensitive cap and can cancel a pending one', (tester) async {
      final api = FakeApi({
        'GET /access-requests': (_) => [requestJson('q1', 'pending'), requestJson('q2', 'approved')],
        'POST /patients/r1/access-requests': (_) => requestJson('q3', 'pending'),
        'DELETE /access-requests/q1': (_) => {'ok': true},
      });
      final s = await sessionFor(api, 'doctor', doctorPerms);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccessRequestsPanel(s, relationshipId: 'r1', name: 'Salma'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Waiting for patient'), findsOneWidget);
      expect(find.text('Approved'), findsOneWidget);
      expect(find.byKey(const ValueKey('cancel-q2')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('request-access')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cat-encounters')));
      await tester.enterText(find.byKey(const ValueKey('purpose')), 'Review work-up');
      await tester.enterText(find.byKey(const ValueKey('days')), '60');
      await tester.pump();
      expect(find.textContaining('at most 14 days'), findsOneWidget);
      await tester.ensureVisible(find.text('Send request'));
      await tester.pump();
      await tester.tap(find.text('Send request'));
      await tester.pumpAndSettle();
      final body = api.bodies['POST /patients/r1/access-requests'] as Map;
      expect((body['scope'] as Map)['categories'], containsAll(['encounters', 'lab_result']));
      expect(body['days'], 14);
      expect(body['purpose'], 'Review work-up');

      await tester.tap(find.byKey(const ValueKey('cancel-q1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel request'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('DELETE /access-requests/q1'));
    });

    testWidgets('nurse (clinical.read only) sees the list but no request/cancel controls', (tester) async {
      final api = FakeApi({
        'GET /access-requests': (_) => [requestJson('q1', 'pending')],
      });
      final s = await sessionFor(api, 'nurse', roleDefaultsNurse);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccessRequestsPanel(s, relationshipId: 'r1', name: 'Salma'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Waiting for patient'), findsOneWidget);
      expect(find.byKey(const ValueKey('request-access')), findsNothing);
      expect(find.byKey(const ValueKey('cancel-q1')), findsNothing);
    });

    testWidgets('receptionist gets no data at all', (tester) async {
      final api = FakeApi({});
      final s = await sessionFor(api, 'receptionist', receptionistPerms);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccessRequestsPanel(s, relationshipId: 'r1', name: 'Salma'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.calls.where((c) => c.contains('access-requests')), isEmpty);
      expect(find.textContaining('do not have access'), findsOneWidget);
    });
  });

  group('Audit', () {
    test('filter query strings omit empty values', () {
      expect(const AuditFilters().toQuery(), isEmpty);
      expect(
        const AuditFilters(
          action: 'access.denied',
          result: 'denied',
          from: '2026-10-01',
          to: '2026-10-20',
          actor: 'u1',
          targetId: ' p1 ',
        ).toQuery(),
        {'action': 'access.denied', 'actor': 'u1', 'from': '2026-10-01', 'to': '2026-10-20', 'result': 'denied', 'targetId': 'p1'},
      );
    });

    Map<String, dynamic> entry(int seq, {String action = 'patient.viewed', String result = 'success', Map<String, dynamic>? meta}) => {
      'seq': seq,
      'action': action,
      'actorName': 'Dr Test',
      'actorRole': 'doctor',
      'result': result,
      'breakGlass': action.startsWith('breakglass.'),
      'metadata': meta ?? <String, dynamic>{},
      'createdAt': '2026-10-20T10:00:00Z',
      'ip': '1.2.3.4',
    };

    testWidgets('lists entries, highlights break-glass and denied, paginates with before=, verify and export', (tester) async {
      final page1 = [
        for (var i = 100; i > 50; i--)
          entry(
            i,
            action: i == 100 ? 'breakglass.granted' : 'patient.viewed',
            result: i == 99 ? 'denied' : 'success',
            meta: i == 100 ? {'justification': 'Support ticket 42'} : null,
          ),
      ];
      final page2 = [entry(50), entry(49)];
      String? shared;
      final api = FakeApi({
        'GET /workspace/audit': (_) => <Object>[],
        'GET /workspace/audit/verify': (_) => {'valid': true, 'checked': 102},
        'GET /workspace/audit/export': (_) => {
          'entries': [],
          'chain': {'valid': true},
        },
        'GET /workspace/members': (_) => [
          {'userId': 'u1', 'fullName': 'Dr Test', 'phone': '+201'},
        ],
      });
      var calls = 0;
      api.routes['GET /workspace/audit'] = (_) => ++calls == 1 ? page1 : page2;
      await tester.pumpWidget(
        MaterialApp(
          home: AuditPage(api: AuditApi(api), canListStaff: true, sharer: (n, j) async => shared = j),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('breakglass-banner')), findsOneWidget);
      expect(find.text('Reason: Support ticket 42'), findsOneWidget);
      expect(find.text('denied'), findsOneWidget);
      expect(api.queries['GET /workspace/audit'], {'limit': '50'});

      await tester.drag(find.byType(ListView), const Offset(0, -20000));
      await tester.pumpAndSettle();
      expect(api.queries['GET /workspace/audit'], {'limit': '50', 'before': '51'});
      await tester.scrollUntilVisible(find.text('End of log'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('End of log'), findsOneWidget);

      await tester.drag(find.byType(ListView), const Offset(0, 20000));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('verify')));
      await tester.pumpAndSettle();
      expect(find.text('Chain intact (102 entries)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('export')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('GET /workspace/audit/export'));
      expect(shared, contains('"chain"'));
    });

    testWidgets('applying filters reloads with the query string', (tester) async {
      final api = FakeApi({'GET /workspace/audit': (_) => <Object>[], 'GET /workspace/members': (_) => <Object>[]});
      await tester.pumpWidget(MaterialApp(home: AuditPage(api: AuditApi(api))));
      await tester.pumpAndSettle();
      expect(find.text('No entries match.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('filters')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('f-result')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Denied').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('f-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Documents').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('f-apply')));
      await tester.pumpAndSettle();
      expect(api.queries['GET /workspace/audit'], {'action': 'document.', 'result': 'denied', 'limit': '50'});
      expect(find.text('Filters (2)'), findsOneWidget);
    });

    testWidgets('detected tampering is reported', (tester) async {
      final api = FakeApi({
        'GET /workspace/audit': (_) => [entry(1)],
        'GET /workspace/audit/verify': (_) => {'valid': false, 'checked': 5, 'brokenAtSeq': 3},
      });
      await tester.pumpWidget(MaterialApp(home: AuditPage(api: AuditApi(api))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('verify')));
      await tester.pumpAndSettle();
      expect(find.text('Tampering detected at entry #3'), findsOneWidget);
    });
  });

  group('Data requests', () {
    Map<String, dynamic> dr(String id, {String status = 'open'}) => {
      'id': id,
      'status': status,
      'targetType': 'encounter',
      'targetId': 'e1',
      'targetLabel': '2026-09-01',
      'description': 'Wrong diagnosis recorded',
      'patient': {'id': 'r1', 'fullName': 'Salma Hassan', 'patientNumber': 7},
      'resolutionNote': status == 'open' ? null : 'Done',
      'createdAt': '2026-10-01T10:00:00Z',
    };
    final retention = {
      'policy': {'clinicalRecordYears': 10, 'auditLogYears': 7, 'legalHoldBlocksDeletion': true},
      'legalHolds': [
        {'patientId': 'r9', 'fullName': 'Omar Ali', 'patientNumber': 9, 'reason': 'Litigation', 'setAt': '2026-09-01T00:00:00Z'},
      ],
    };

    testWidgets('resolve and reject send the note; status filter is a query', (tester) async {
      final api = FakeApi({
        'GET /correction-requests': (_) => [dr('c1'), dr('c2')],
        'GET /workspace/retention': (_) => retention,
        'POST /correction-requests/c1/resolve': (_) => {'ok': true},
        'POST /correction-requests/c2/reject': (_) => {'ok': true},
        'PATCH /patients/r9/legal-hold': (_) => {'ok': true},
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DataRequestsPage(api: DataRequestsApi(api), canDecide: true, canLiftHold: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.queries['GET /correction-requests'], {'status': 'open'});
      expect(find.textContaining('Nothing changes automatically'), findsOneWidget);
      expect(find.text('Omar Ali'), findsOneWidget);
      expect(find.textContaining('10 years'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('resolve-c1')));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('note-submit'))).onPressed, isNull); // note required
      await tester.enterText(find.byKey(const ValueKey('note')), 'Amended the consultation');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('note-submit')));
      await tester.pumpAndSettle();
      expect(api.bodies['POST /correction-requests/c1/resolve'], {'note': 'Amended the consultation'});

      await tester.tap(find.byKey(const ValueKey('reject-c2')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('note')), 'Record is accurate');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('note-submit')));
      await tester.pumpAndSettle();
      expect(api.bodies['POST /correction-requests/c2/reject'], {'note': 'Record is accurate'});

      await tester.scrollUntilVisible(find.byKey(const ValueKey('lift-r9')), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byKey(const ValueKey('lift-r9')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lift hold'));
      await tester.pumpAndSettle();
      expect(api.bodies['PATCH /patients/r9/legal-hold'], {'hold': false});

      await tester.scrollUntilVisible(find.text('Resolved'), -200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Resolved'));
      await tester.pumpAndSettle();
      expect(api.queries['GET /correction-requests'], {'status': 'resolved'});
    });

    testWidgets('without clinical.write there are no decision buttons; without audit.read no retention call', (tester) async {
      final api = FakeApi({
        'GET /correction-requests': (_) => [dr('c1')],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DataRequestsPage(api: DataRequestsApi(api), canDecide: false, canViewRetention: false)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('resolve-c1')), findsNothing);
      expect(api.calls, isNot(contains('GET /workspace/retention')));
    });

    testWidgets('closed requests show the reply; load error is retryable', (tester) async {
      var fail = true;
      final api = FakeApi({
        'GET /correction-requests': (_) =>
            fail ? throw ApiException(status: 500, code: 'x', message: 'Server down') : [dr('c1', status: 'resolved')],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DataRequestsPage(api: DataRequestsApi(api), canDecide: true, canViewRetention: false)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Server down'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('resolved: Done'), findsOneWidget);
    });
  });
}

const roleDefaultsNurse = [
  'patients.read',
  'patients.write',
  'appointments.read',
  'vitals.write',
  'documents.upload',
  'documents.upload_clinical',
  'clinical.read',
];
