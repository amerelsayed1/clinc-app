import 'package:carelink_clinic/src/features/settings/settings_models.dart';
import 'package:carelink_clinic/src/features/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

Map<String, dynamic> settingsJson() => {
      'timezone': 'Africa/Cairo',
      'slotMinutes': 30,
      'workingHours': {
        'sat': [
          {'start': '09:00', 'end': '17:00'}
        ],
        'sun': <Object>[], 'mon': <Object>[], 'tue': <Object>[], 'wed': <Object>[], 'thu': <Object>[], 'fri': <Object>[],
      },
    };

void main() {
  test('withDay opens with defaults, edits the first range and closes', () {
    var s = ClinicSettings.fromJson(settingsJson());
    s = s.withDay('sun', open: true);
    expect(s.workingHours['sun']!.single.start, '09:00');
    s = s.withDay('sun', end: '13:00');
    expect(s.workingHours['sun']!.single.end, '13:00');
    s = s.withDay('sun', open: false);
    expect(s.workingHours['sun'], isEmpty);
  });

  test('validate catches what the server would reject', () {
    final s = ClinicSettings.fromJson(settingsJson());
    expect(s.validate(), isNull);
    expect(s.copyWith(slotMinutes: 2).validate(), contains('between 5 and 120'));
    expect(s.copyWith(timezone: ' ').validate(), isNotNull);
    expect(s.withDay('sat', start: '18:00').validate(), contains('Saturday'));
  });

  testWidgets('loads, toggles a day, saves the full settings body', (tester) async {
    final api = FakeApi({
      'GET /workspace/settings': (_) => settingsJson(),
      'PATCH /workspace/settings': (b) => b,
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsPage(api: api))));
    await tester.pumpAndSettle();
    expect(find.text('Africa/Cairo'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('day-sun')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Default appointment length (minutes)'), '45');
    await tester.scrollUntilVisible(find.text('Save settings'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Save settings'));
    await tester.pumpAndSettle();
    final body = api.bodies['PATCH /workspace/settings'] as Map<String, dynamic>;
    expect(body['slotMinutes'], 45);
    expect(body['timezone'], 'Africa/Cairo');
    expect((body['workingHours'] as Map)['sun'], [
      {'start': '09:00', 'end': '17:00'}
    ]);
    expect(find.text('Saved'), findsOneWidget);
  });
}
