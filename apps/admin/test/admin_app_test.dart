import 'package:carelink_admin/src/admin_repository.dart';
import 'package:carelink_admin/src/app.dart';
import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

Future<void> boot(WidgetTester tester, FakeApi api) async {
  final auth = AuthController(api);
  await auth.bootstrap();
  await tester.pumpWidget(AdminApp(auth: auth, repository: AdminRepository(api)));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('shows the phone login screen when signed out', (tester) async {
    await boot(tester, FakeApi({}, signedIn: false));
    expect(find.text('CareLink Admin'), findsOneWidget);
    expect(find.text('Send code'), findsOneWidget);
  });

  testWidgets('non-admins see Access denied with sign out', (tester) async {
    await boot(tester, FakeApi({'GET /me': (_) => me(admin: false)}));
    expect(find.text('Access denied'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign out'), findsOneWidget);
    expect(find.text('Doctor verification'), findsNothing);
  });

  testWidgets('admin without MFA is forced into enrolment', (tester) async {
    final api = FakeApi({
      'GET /me': (_) => me(mfaEnabled: false),
      'POST /auth/mfa/enroll': (_) => {'secret': 'JBSWY3DPEHPK3PXP', 'otpauthUrl': 'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP'},
    });
    await boot(tester, api);
    expect(find.text('Two-step verification'), findsOneWidget);
    expect(find.text('JBSWY3DPEHPK3PXP'), findsOneWidget);
    expect(find.text('Doctor verification'), findsNothing);
    expect(find.byType(BackButton), findsNothing);
  });

  testWidgets('verified admin sees the pending doctors', (tester) async {
    final api = FakeApi({
      'GET /me': (_) => me(),
      'GET /admin/doctors': (_) => [
            {'userId': 'd1', 'fullName': 'Dr. Omar', 'phone': '+201111111111', 'licenseNumber': 'LIC-123', 'status': 'pending', 'createdAt': '2026-10-01T10:00:00Z'},
          ],
    });
    await boot(tester, api);
    await tester.pump();
    expect(find.text('Doctor verification'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Dr. Omar'), findsWidgets);

    await tester.tap(find.text('Dr. Omar').first);
    await tester.pumpAndSettle();
    expect(find.text('Verify'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
  });
}
