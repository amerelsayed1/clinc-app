import 'package:carelink_admin/src/admin_repository.dart';
import 'package:carelink_admin/src/app.dart';
import 'package:clinic_core/clinic_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

void main() {
  testWidgets('admin Inbox tab reuses the shared inbox and opens the shared settings screen', (tester) async {
    final api = FakeApi({
      'GET /me': (_) => me(),
      'GET /admin/doctors': (_) => [],
      'GET /notification-preferences': (_) => {
            'locale': 'en',
            'localeExplicit': false,
            'channels': ['push', 'sms'],
            'quietHours': null,
            'timezone': 'Africa/Cairo',
            'disabledTypes': [],
            'types': [
              {'type': 'security_new_login', 'mandatory': true},
            ],
            'consent': {'required': false, 'push': null, 'sms': null},
          },
      'GET /notifications/unread-count': (_) => {'count': 2},
      'GET /notifications': (_) => {
            'items': [
              {'id': 'n1', 'type': 'security_new_login', 'title': 'New device sign-in', 'body': 'Your account was signed in on a new device.', 'data': {}, 'createdAt': '2026-10-01T10:00:00Z', 'read': false},
            ],
            'nextCursor': null,
          },
    });
    final auth = AuthController(api);
    await auth.bootstrap();
    await tester.pumpWidget(AdminApp(auth: auth, repository: AdminRepository(api)));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget); // unread badge
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    expect(find.text('New device sign-in'), findsOneWidget);
    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();
    expect(find.text('Notification settings'), findsOneWidget);
    expect(find.text('Always on'), findsOneWidget); // security notices are locked
  });
}
