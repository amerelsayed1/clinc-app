import 'package:carelink_clinic/src/app.dart';
import 'package:carelink_clinic/src/clinic_repository.dart';
import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

Future<(FakeApi, AuthController)> boot(WidgetTester tester, Map<String, Object? Function(Object? body)> routes, {bool signedIn = true}) async {
  final api = FakeApi(routes, signedIn: signedIn);
  final auth = AuthController(api);
  await auth.bootstrap();
  await tester.pumpWidget(ClinicApp(auth: auth, repository: ClinicRepository(api)));
  await tester.pumpAndSettle();
  return (api, auth);
}

void main() {
  testWidgets('shows the phone login screen when signed out', (tester) async {
    await boot(tester, {}, signedIn: false);
    expect(find.text('CareLink Clinic'), findsOneWidget);
    expect(find.text('Send code'), findsOneWidget);
  });

  testWidgets('doctor sees clinic tabs; Team and Settings live under More', (tester) async {
    await boot(tester, {'GET /me': (_) => me(member: membership('doctor', doctorPerms))});
    for (final k in ['appointments', 'patients', 'notifications']) {
      expect(find.byKey(ValueKey('nav-$k')), findsOneWidget);
    }
    expect(find.text('Nile Clinic'), findsWidgets);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    for (final k in ['shared', 'team', 'settings', 'audit', 'data-requests', 'account']) {
      expect(find.byKey(ValueKey('more-$k')), findsOneWidget, reason: k);
    }
  });

  testWidgets('receptionist does not see Team, Settings, Audit, Shared or Data requests', (tester) async {
    await boot(tester, {'GET /me': (_) => me(member: membership('receptionist', receptionistPerms))});
    expect(find.byKey(const ValueKey('nav-appointments')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-patients')), findsOneWidget);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('more-account')), findsOneWidget);
    for (final k in ['team', 'settings', 'audit', 'shared', 'data-requests']) {
      expect(find.byKey(ValueKey('more-$k')), findsNothing, reason: k);
    }
    expect(find.text('Team'), findsNothing);
  });

  testWidgets('sets the x-workspace-id header from the first membership', (tester) async {
    final (api, _) = await boot(tester, {'GET /me': (_) => me(member: membership('doctor', doctorPerms))});
    expect(api.extraHeaders['x-workspace-id'], 'w1');
  });

  testWidgets('mandatory MFA: doctor without MFA is forced into enrolment', (tester) async {
    await boot(tester, {
      'GET /me': (_) => me(member: membership('doctor', doctorPerms), mfaEnabled: false, mfaRequired: true),
      'POST /auth/mfa/enroll': (_) => {'secret': 'JBSWY3DPEHPK3PXP', 'otpauthUrl': 'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP'},
    });
    expect(find.text('Two-step verification'), findsOneWidget);
    expect(find.text('JBSWY3DPEHPK3PXP'), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-patients')), findsNothing);
    expect(find.byType(BackButton), findsNothing);
  });

  testWidgets('licence banner: pending for doctors', (tester) async {
    await boot(tester, {
      'GET /me': (_) => me(member: membership('doctor', doctorPerms), doctorProfile: {'licenseNumber': 'L1', 'verificationStatus': 'pending'}),
    });
    expect(find.text('Your licence is awaiting verification. Clinical features unlock once it is approved.'), findsOneWidget);
  });

  testWidgets('licence banner: rejected shows the note', (tester) async {
    await boot(tester, {
      'GET /me': (_) => me(member: membership('doctor', doctorPerms), doctorProfile: {'licenseNumber': 'L1', 'verificationStatus': 'rejected', 'verificationNote': 'Blurry scan'}),
    });
    expect(find.text('Your licence verification was rejected: Blurry scan.'), findsOneWidget);
  });

  testWidgets('licence banner: hidden once verified', (tester) async {
    await boot(tester, {
      'GET /me': (_) => me(member: membership('doctor', doctorPerms), doctorProfile: {'licenseNumber': 'L1', 'verificationStatus': 'verified'}),
    });
    expect(find.byKey(const ValueKey('verification-banner')), findsNothing);
  });

  group('onboarding (no membership)', () {
    testWidgets('doctor registers then creates a workspace', (tester) async {
      var registered = false;
      final (api, _) = await boot(tester, {
        'GET /me': (_) => registered ? me(member: membership('doctor', doctorPerms), doctorProfile: {'licenseNumber': 'L1', 'verificationStatus': 'pending'}) : me(),
        'POST /doctors/register': (_) => {'verificationStatus': 'pending'},
        'POST /workspaces': (_) {
          registered = true;
          return {'id': 'w1'};
        },
      });
      expect(find.text("I'm a doctor"), findsOneWidget);
      expect(find.text('I have an invitation'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Medical licence number'), 'LIC-123');
      await tester.enterText(find.widgetWithText(TextField, 'Clinic name (optional)'), 'Nile Clinic');
      await tester.tap(find.text('Create my workspace'));
      await tester.pumpAndSettle();
      expect(api.bodies['POST /doctors/register'], {'fullName': 'Dr Test', 'licenseNumber': 'LIC-123'});
      expect(api.bodies['POST /workspaces'], {'name': 'Nile Clinic'});
      expect(find.byKey(const ValueKey('nav-patients')), findsOneWidget);
    });

    testWidgets('staff accepts an invitation code', (tester) async {
      var joined = false;
      final (api, _) = await boot(tester, {
        'GET /me': (_) => joined ? me(member: membership('receptionist', receptionistPerms)) : me(),
        'POST /invitations/accept': (_) {
          joined = true;
          return {'workspaceId': 'w1', 'role': 'receptionist'};
        },
      });
      await tester.tap(find.text('I have an invitation'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Invitation code'), 'abcd2345');
      await tester.tap(find.text('Join clinic'));
      await tester.pumpAndSettle();
      expect(api.bodies['POST /invitations/accept'], {'code': 'ABCD2345'});
      expect(find.byKey(const ValueKey('nav-appointments')), findsOneWidget);
    });

    testWidgets('a rejected code shows the server message', (tester) async {
      await boot(tester, {
        'GET /me': (_) => me(),
        'POST /invitations/accept': (_) => throw ApiException(status: 400, code: 'invalid_invitation', message: 'Invitation is invalid, expired, or not for this phone number'),
      });
      await tester.tap(find.text('I have an invitation'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Invitation code'), 'ZZZZ9999');
      await tester.tap(find.text('Join clinic'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Invitation is invalid'), findsOneWidget);
    });
  });

  testWidgets('the first tab is the real appointments day view', (tester) async {
    await boot(tester, {
      'GET /me': (_) => me(member: membership('doctor', doctorPerms)),
      'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo', 'slotMinutes': 20, 'workingHours': <String, dynamic>{}},
      'GET /appointments': (_) => <dynamic>[],
    });
    expect(find.text('Coming soon'), findsNothing);
    expect(find.text('Nobody is waiting.'), findsOneWidget);
  });
}
