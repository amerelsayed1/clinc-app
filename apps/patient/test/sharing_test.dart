import 'package:carelink_patient/src/app.dart';
import 'package:carelink_patient/src/patient_repository.dart';
import 'package:carelink_patient/src/sharing_models.dart';
import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

AccessRequest req({Map<String, dynamic>? scope, int days = 30, bool sensitive = false}) => AccessRequest.fromJson({
      'id': 'q1',
      'status': 'pending',
      'scope': scope ?? {'categories': ['lab_result', 'imaging']},
      'purpose': 'Second opinion',
      'requestedDays': days,
      'sensitive': sensitive,
      'expiresAt': DateTime.now().add(const Duration(days: 5)).toIso8601String(),
      'clinicName': 'Nile Clinic',
      'doctorName': 'Dr. Omar',
    });

Map<String, dynamic> grantJson({String status = 'active', bool soon = false}) => {
      'id': 'g1',
      'scope': {'categories': ['lab_result']},
      'purpose': 'Follow up',
      'createdAt': '2026-10-01T10:00:00Z',
      'expiresAt': DateTime.now().add(const Duration(days: 2)).toIso8601String(),
      'revokedAt': null,
      'status': status,
      'expiresSoon': soon,
      'recipient': {'workspaceId': 'w1', 'clinicName': 'Nile Clinic', 'doctorName': 'Dr. Omar'},
    };

void main() {
  group('scope building', () {
    test('categories keep canonical order and dates', () {
      final s = buildScope(byItems: false, categories: {'imaging', 'lab_result'}, from: '2026-01-01')!;
      expect(s.toJson(), {'categories': ['lab_result', 'imaging'], 'from': '2026-01-01'});
    });
    test('items scope never carries dates; empty selections give null', () {
      expect(buildScope(byItems: true, items: {const ItemRef('document', 'd1')}, from: '2026-01-01')!.toJson(), {
        'items': [{'type': 'document', 'id': 'd1'}]
      });
      expect(buildScope(byItems: true), isNull);
      expect(buildScope(byItems: false), isNull);
    });
    test('consultations are sensitive and cap the duration at 14 days', () {
      expect(buildScope(byItems: false, categories: {'encounters'})!.sensitive, isTrue);
      expect(buildScope(byItems: true, items: {const ItemRef('encounter', 'e1')})!.sensitive, isTrue);
      expect(buildScope(byItems: false, categories: {'report'})!.sensitive, isFalse);
      expect(maxDaysFor(buildScope(byItems: false, categories: {'encounters'})), 14);
      expect(maxDaysFor(buildScope(byItems: false, categories: {'report'})), 90);
    });
  });

  group('validation and error mapping', () {
    final ok = buildScope(byItems: false, categories: {'report'});
    test('requires the retention acknowledgement', () {
      expect(validateShare(scope: ok, days: 30, hasRecipient: true, ackRetention: false, ackSensitive: false), contains('acknowledge'));
      expect(validateShare(scope: ok, days: 30, hasRecipient: true, ackRetention: true, ackSensitive: false), isNull);
    });
    test('sensitive scopes need their own confirmation and 14 days', () {
      final s = buildScope(byItems: false, categories: {'encounters'});
      expect(validateShare(scope: s, days: 14, hasRecipient: true, ackRetention: true, ackSensitive: false), contains('consultation'));
      expect(validateShare(scope: s, days: 30, hasRecipient: true, ackRetention: true, ackSensitive: true), contains('1 and 14'));
      expect(validateShare(scope: s, days: 14, hasRecipient: true, ackRetention: true, ackSensitive: true), isNull);
    });
    test('maps API error codes', () {
      String m(String code, [int status = 400]) => shareErrorMessage(ApiException(status: status, code: code, message: 'raw'));
      expect(m('retention_ack_required'), contains('kept after you revoke'));
      expect(m('sensitive_ack_required'), contains('sensitive'));
      expect(m('duration_too_long'), contains('14 days'));
      expect(m('invalid_scope'), contains('can no longer be shared'));
      expect(m('scope_widened'), contains('narrow'));
      expect(m('not_found', 404), contains('verified doctor'));
      expect(m('whatever'), 'raw');
    });
  });

  group('approval can only narrow', () {
    test('categories offered are exactly the requested ones; body omits scope until narrowed', () {
      final d = ApprovalDraft(req());
      expect(d.offeredCategories, ['lab_result', 'imaging']);
      expect(d.body(ackRetention: true, ackSensitive: false), {'days': 30, 'acknowledgeRetention': true});
      d.categories.remove('imaging');
      expect(d.body(ackRetention: true, ackSensitive: false)['scope'], {'categories': ['lab_result']});
    });
    test('days can only be shortened and sensitive requests stay within 14', () {
      final d = ApprovalDraft(req(days: 20));
      d.setDays(60);
      expect(d.days, 20);
      d.setDays(5);
      expect(d.days, 5);
      final s = ApprovalDraft(req(days: 14, sensitive: true, scope: {'categories': ['encounters']}));
      expect(s.maxDays, 14);
      expect(s.body(ackRetention: true, ackSensitive: true)['acknowledgeSensitive'], isTrue);
    });
    test('narrowing a request with a date range keeps the range', () {
      final d = ApprovalDraft(req(scope: {'categories': ['report', 'other'], 'from': '2026-01-01', 'to': '2026-06-30'}));
      d.categories.remove('other');
      expect(d.body(ackRetention: true, ackSensitive: false)['scope'], {'categories': ['report'], 'from': '2026-01-01', 'to': '2026-06-30'});
    });
    test('needs acknowledgements and at least one thing selected', () {
      final d = ApprovalDraft(req());
      expect(d.validate(ackRetention: false, ackSensitive: false), contains('acknowledge'));
      d.categories.clear();
      expect(d.validate(ackRetention: true, ackSensitive: false), contains('at least one'));
    });
  });

  Future<FakeApi> boot(WidgetTester tester, Map<String, Object? Function(Object?)> extra) async {
    final api = FakeApi({'GET /me': (_) => me(), 'POST /patient/claim': (_) => [], 'GET /patient/access-log': (_) => [], ...extra});
    final auth = AuthController(api);
    await auth.bootstrap();
    await tester.pumpWidget(PatientApp(auth: auth, repository: PatientRepository(api)));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('Sharing tab shows a badge for pending requests and the inbox details', (tester) async {
    await boot(tester, {
      'GET /patient/grants': (_) => [grantJson(soon: true)],
      'GET /patient/access-requests': (_) => [
            {
              'id': 'q1', 'status': 'pending', 'scope': {'categories': ['encounters']}, 'purpose': 'Second opinion', 'requestedDays': 14, 'sensitive': true,
              'expiresAt': DateTime.now().add(const Duration(days: 5)).toIso8601String(), 'clinicName': 'Nile Clinic', 'doctorName': 'Dr. Omar'
            }
          ],
    });
    expect(find.text('1'), findsOneWidget); // nav badge
    await tester.tap(find.text('Sharing'));
    await tester.pumpAndSettle();
    expect(find.text('Expires soon'), findsOneWidget);
    expect(find.text('Revoke'), findsOneWidget);
    await tester.tap(find.text('Requests'));
    await tester.pumpAndSettle();
    expect(find.text('Purpose: Second opinion'), findsOneWidget);
    expect(find.textContaining('sensitive'), findsOneWidget);
    expect(find.text('For: 14 days'), findsOneWidget);
  });

  testWidgets('revoking asks for confirmation and calls DELETE', (tester) async {
    final api = await boot(tester, {
      'GET /patient/grants': (_) => [grantJson()],
      'GET /patient/access-requests': (_) => [],
      'DELETE /patient/grants/g1': (_) => {'ok': true},
    });
    await tester.tap(find.text('Sharing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke access?'), findsOneWidget);
    expect(find.textContaining('keeps that copy'), findsOneWidget);
    expect(api.calls, isNot(contains('DELETE /patient/grants/g1')));
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke access'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('DELETE /patient/grants/g1'));
  });

  testWidgets('share form blocks submit until the retention acknowledgement is ticked', (tester) async {
    final api = await boot(tester, {
      'GET /patient/grants': (_) => [],
      'GET /patient/access-requests': (_) => [],
      'GET /patient/relationships': (_) => [
            {'id': 'r1', 'status': 'active', 'workspaceName': 'Nile Clinic', 'doctorName': 'Dr. Omar'}
          ],
      'GET /patient/shareable': (_) => [],
      'POST /patient/grants': (_) => grantJson(),
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 2400);
    addTearDown(tester.view.reset);
    await tester.tap(find.text('Sharing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share records'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Doctor by phone'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '+201000000009');
    await tester.tap(find.text('Reports'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Share'));
    await tester.pump();
    expect(find.textContaining('acknowledge'), findsWidgets);
    expect(api.calls, isNot(contains('POST /patient/grants')));
    await tester.tap(find.byKey(const Key('ack-retention')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Share'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /patient/grants'));
  });
}
