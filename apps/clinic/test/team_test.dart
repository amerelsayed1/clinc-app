import 'package:carelink_clinic/src/features/team/team_api.dart';
import 'package:carelink_clinic/src/features/team/team_models.dart';
import 'package:carelink_clinic/src/features/team/team_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

Map<String, dynamic> member(String id, String role, {List<String> denied = const [], String status = 'active', String? name}) => {
      'id': id,
      'userId': 'u$id',
      'fullName': name ?? 'Person $id',
      'phone': '+2010000000$id',
      'role': role,
      'status': status,
      'deniedPermissions': denied,
      'permissions': <String>[],
    };

void main() {
  test('deniedAfterToggle adds/removes without duplicates', () {
    final m = Member.fromJson(member('2', 'receptionist', denied: ['patients.write']));
    expect(m.deniedAfterToggle('patients.write', allowed: true), isEmpty);
    expect(m.deniedAfterToggle('patients.write', allowed: false), ['patients.write']);
    expect(m.deniedAfterToggle('documents.upload', allowed: false), ['patients.write', 'documents.upload']);
  });

  test('grantable permissions are the role defaults; owner has none to toggle', () {
    expect(Member.fromJson(member('1', 'doctor')).grantable, isEmpty);
    final r = Member.fromJson(member('2', 'receptionist')).grantable;
    expect(r, contains('appointments.manage'));
    expect(r, isNot(contains('staff.manage')));
    expect(Member.fromJson(member('3', 'nurse')).grantable, contains('vitals.write'));
  });

  group('TeamPage', () {
    late FakeApi api;
    var members = <Map<String, dynamic>>[];
    var invites = <Map<String, dynamic>>[];

    Future<void> pump(WidgetTester tester) async {
      members = [member('1', 'doctor', name: 'Dr Owner'), member('2', 'receptionist', name: 'Rana')];
      invites = [
        {'id': 'i1', 'phone': '+201555555555', 'role': 'nurse', 'expiresAt': '2026-12-01T10:00:00Z'},
      ];
      api = FakeApi({
        'GET /workspace/members': (_) => members,
        'GET /workspace/invitations': (_) => invites,
        'PATCH /workspace/members/2': (_) => {'ok': true},
        'DELETE /workspace/members/2': (_) => null,
        'DELETE /workspace/invitations/i1': (_) => null,
        'POST /workspace/invitations': (_) => {'id': 'i2', 'code': 'ABCD2345', 'expiresAt': '2026-12-01T10:00:00Z'},
      });
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: TeamPage(api: TeamApi(api)))));
      await tester.pumpAndSettle();
    }

    testWidgets('lists members with role and status and pending invitations', (tester) async {
      await pump(tester);
      expect(find.text('Dr Owner'), findsOneWidget);
      expect(find.text('Rana'), findsOneWidget);
      expect(find.textContaining('Receptionist'), findsWidgets);
      expect(find.text('Pending invitations'), findsOneWidget);
      expect(find.text('+201555555555'), findsOneWidget);
    });

    testWidgets('toggling a permission off sends the deny list', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Rana'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('perm-2-appointments.manage')));
      await tester.pumpAndSettle();
      expect(api.bodies['PATCH /workspace/members/2'], {'deniedPermissions': ['appointments.manage']});
    });

    testWidgets('suspend and confirmed remove', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Rana'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('status-2')));
      await tester.tap(find.byKey(const ValueKey('status-2')));
      await tester.pumpAndSettle();
      expect(api.bodies['PATCH /workspace/members/2'], {'status': 'suspended'});

      await tester.ensureVisible(find.byKey(const ValueKey('remove-2')));
      await tester.tap(find.byKey(const ValueKey('remove-2')));
      await tester.pumpAndSettle();
      expect(api.calls, isNot(contains('DELETE /workspace/members/2'))); // not until confirmed
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('DELETE /workspace/members/2'));
    });

    testWidgets('revokes an invitation', (tester) async {
      await pump(tester);
      await tester.ensureVisible(find.text('Revoke'));
      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('DELETE /workspace/invitations/i1'));
    });

    testWidgets('invites by phone + role and shows the one-time code', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Invite staff'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Phone number'), '+201001234567');
      await tester.tap(find.text('Nurse'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send invitation'));
      await tester.pumpAndSettle();
      expect(api.bodies['POST /workspace/invitations'], {'phone': '+201001234567', 'role': 'nurse'});
      expect(find.text('Invitation code'), findsOneWidget);
      expect(find.text('ABCD2345'), findsOneWidget);
    });

    testWidgets('rejects an invalid phone before calling the API', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Invite staff'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Phone number'), '123');
      await tester.tap(find.text('Send invitation'));
      await tester.pumpAndSettle();
      expect(api.calls, isNot(contains('POST /workspace/invitations')));
      expect(find.textContaining('international format'), findsOneWidget);
    });
  });
}
