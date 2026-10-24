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
  await tester.pumpAndSettle();
}

Map<String, Object? Function(Object?)> base() => {
      'GET /me': (_) => me(),
      'GET /admin/doctors': (_) => [],
      'GET /notification-consent': (_) => {'required': false, 'push': false, 'sms': false},
      'GET /notification-preferences': (_) => {'locale': 'en', 'explicit': true, 'channels': {}, 'quietHours': null, 'timezone': 'UTC', 'disabledTypes': [], 'types': [], 'consent': {'required': false, 'push': false, 'sms': false}},
      'GET /notifications/unread-count': (_) => {'count': 0},
    };

void main() {
  testWidgets('audit integrity tab runs a verification and reports tampering', (tester) async {
    final history = <Map<String, dynamic>>[
      {'id': 'v0', 'ranAt': '2026-10-01T10:00:00Z', 'triggeredBy': 'job', 'chainsChecked': 2, 'entriesChecked': 40, 'valid': true, 'broken': []},
    ];
    final api = FakeApi({
      ...base(),
      'GET /admin/audit/verifications': (_) => history,
      'GET /admin/audit/verify': (_) {
        final run = {
          'id': 'v1',
          'ranAt': '2026-10-02T10:00:00Z',
          'valid': false,
          'chainsChecked': 3,
          'entriesChecked': 55,
          'chains': [
            {'chainKey': 'global', 'valid': true, 'checked': 10},
            {'chainKey': 'ws-1', 'valid': false, 'checked': 4, 'brokenAtSeq': 5},
          ],
        };
        history.insert(0, {'id': 'v1', 'ranAt': run['ranAt'], 'triggeredBy': 'admin', 'chainsChecked': 3, 'entriesChecked': 55, 'valid': false, 'broken': [{'chainKey': 'ws-1', 'valid': false, 'brokenAtSeq': 5}]});
        return run;
      },
    });
    await boot(tester, api);
    await tester.tap(find.text('Audit'));
    await tester.pumpAndSettle();
    expect(find.text('Audit integrity'), findsOneWidget);
    expect(find.text('Intact'), findsOneWidget);
    await tester.tap(find.text('Verify all audit chains'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('GET /admin/audit/verify'));
    expect(find.text('Tampering detected'), findsOneWidget);
    expect(find.textContaining('ws-1 (entry #5)'), findsWidgets);
  });

  testWidgets('break-glass needs a clinic and a justification of 15+ characters, then shows the clinic log', (tester) async {
    Map<String, dynamic>? granted;
    var access = <Map<String, dynamic>>[];
    final api = FakeApi({
      ...base(),
      'GET /admin/workspaces': (_) => [
            {'id': 'w1', 'name': 'Nile Clinic', 'ownerName': 'Dr. Omar', 'createdAt': '2026-09-01T10:00:00Z'},
          ],
      'GET /admin/break-glass': (_) => access,
      'POST /admin/break-glass': (b) {
        granted = b as Map<String, dynamic>;
        access = [
          {'id': 'g1', 'workspaceId': 'w1', 'workspaceName': 'Nile Clinic', 'justification': granted!['justification'], 'createdAt': '2026-10-24T10:00:00Z', 'expiresAt': DateTime.now().add(const Duration(minutes: 15)).toUtc().toIso8601String(), 'active': true},
        ];
        return {'id': 'g1', 'workspaceId': 'w1', 'expiresAt': access[0]['expiresAt']};
      },
      'GET /admin/workspaces/w1/audit': (_) => {
            'accessId': 'g1',
            'chain': {'valid': true, 'checked': 2},
            'entries': [
              {'seq': 2, 'action': 'breakglass.granted', 'actorName': 'Admin One', 'actorRole': 'platform_admin', 'result': 'success', 'createdAt': '2026-10-24T10:00:00Z', 'breakGlass': true},
              {'seq': 1, 'action': 'workspace.created', 'actorName': 'Dr. Omar', 'actorRole': 'doctor', 'result': 'success', 'createdAt': '2026-10-24T09:00:00Z', 'breakGlass': false},
            ],
          },
      'DELETE /admin/break-glass/g1': (_) {
        access = [];
        return null;
      },
    });
    await boot(tester, api);
    await tester.tap(find.text('Break-glass'));
    await tester.pumpAndSettle();
    final open = find.widgetWithText(FilledButton, 'Open break-glass access');
    expect(tester.widget<FilledButton>(open).onPressed, isNull);

    await tester.tap(find.byKey(const Key('clinic-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Nile Clinic').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'too short');
    await tester.pump();
    expect(tester.widget<FilledButton>(open).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Investigating a reported breach');
    await tester.pump();
    expect(tester.widget<FilledButton>(open).onPressed, isNotNull);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(granted, {'workspaceId': 'w1', 'justification': 'Investigating a reported breach', 'minutes': 30});
    expect(find.text('Active access'), findsOneWidget);

    ScaffoldMessenger.of(tester.element(find.text('Active access'))).clearSnackBars(); // the confirmation snack bar sits over the row actions
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('View audit log'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('View audit log'));
    await tester.pumpAndSettle();
    expect(find.text('breakglass.granted'), findsOneWidget);
    expect(find.text('workspace.created'), findsOneWidget);
    expect(api.calls, contains('GET /admin/workspaces/w1/audit'));
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byTooltip('End access'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('End access'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('DELETE /admin/break-glass/g1'));
    expect(find.textContaining('None.'), findsOneWidget);
  });

  testWidgets('app lock switch is available on the account tab', (tester) async {
    await boot(tester, FakeApi(base()));
    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    expect(find.text('App lock'), findsOneWidget);
  });
}
