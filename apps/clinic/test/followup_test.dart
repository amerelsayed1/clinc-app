import 'package:carelink_clinic/src/features/followup/followup_models.dart';
import 'package:carelink_clinic/src/features/followup/followup_tab.dart';
import 'package:carelink_clinic/src/features/followup/trend_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'clinical_tabs_helpers.dart';
import 'fake_api.dart';

Map<String, dynamic> plan({String status = 'active'}) => {
      'id': 'f1',
      'careRelationshipId': 'p1',
      'status': status,
      'currentVersion': 2,
      'nextVisitDate': '2026-04-01',
      'instructions': 'Measure before breakfast',
      'startDate': '2026-03-01',
      'endDate': null,
      'closedAt': null,
      'closeReason': null,
      'measurements': [
        {'id': 'm1', 'kind': 'glucose_mg_dl', 'name': 'Blood glucose', 'unit': 'mg/dL', 'frequency': 'daily', 'intervalDays': 1, 'active': true, 'normalMin': 70, 'normalMax': 140, 'overdue': true},
      ],
      'submissions': [
        {'id': 's1', 'measurementId': 'm1', 'measurementName': 'Blood glucose', 'unit': 'mg/dL', 'value': 180, 'measuredAt': '2026-03-05T08:00:00Z', 'note': 'after cake', 'documentId': null, 'source': 'patient', 'verified': false, 'outsideExpectedRange': true, 'flagLabel': 'x'},
        {'id': 's2', 'measurementId': 'm1', 'measurementName': 'Blood glucose', 'unit': 'mg/dL', 'value': 100, 'measuredAt': '2026-03-04T08:00:00Z', 'note': '', 'documentId': null, 'source': 'patient', 'verified': false, 'outsideExpectedRange': false, 'flagLabel': null},
      ],
    };

Future<void> reveal(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

void main() {
  late RecordingApi api;
  var plans = <Map<String, dynamic>>[];

  Future<void> pump(WidgetTester tester, String role, List<String> perms) async {
    api = RecordingApi({
      'GET /patients/p1/followups': (_) => plans.map((p) => {'id': p['id']}).toList(),
      'GET /followups/f1': (_) => plans.first,
      'GET /followups/f1/measurements/m1/trend': (_) => {
            'points': [
              {'id': 's2', 'measuredAt': '2026-03-04T08:00:00Z', 'value': 100, 'outsideExpectedRange': false},
              {'id': 's1', 'measuredAt': '2026-03-05T08:00:00Z', 'value': 180, 'outsideExpectedRange': true},
            ],
          },
      'POST /patients/p1/followups': (_) => plan(),
      'PATCH /followups/f1': (_) => {'ok': true},
      'POST /followups/f1/close': (_) => {'ok': true},
      'GET /followups/f1/history': (_) => [
            {'version': 1, 'change': 'created', 'editedBy': 'Dr Test', 'at': '2026-03-01T09:00:00Z', 'snapshot': {'plan': {'instructions': 'First'}, 'measurements': [{'name': 'Blood glucose', 'active': true}]}},
          ],
    });
    final session = await sessionFor(api, role, perms);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: FollowupTab(session: session, patientId: 'p1'))));
    await tester.pumpAndSettle();
  }

  setUp(() => plans = [plan()]);

  testWidgets('shows patient-reported submissions with the required out-of-range wording only on flagged values', (tester) async {
    await pump(tester, 'doctor', doctorPerms);
    expect(find.text(followupFlagText), findsOneWidget);
    expect(followupFlagText, 'patient-reported, outside expected range');
    expect(find.textContaining('abnormal'), findsNothing);
    expect(find.textContaining('not verified findings'), findsOneWidget);
    expect(find.text('Blood glucose: 180 mg/dL'), findsOneWidget);
    expect(find.text('Overdue'), findsOneWidget);
    expect(find.byType(TrendChart), findsOneWidget);
  });

  testWidgets('without clinical.write there are no create/edit/close controls', (tester) async {
    await pump(tester, 'nurse', ['patients.read', 'clinical.read']);
    expect(find.byKey(const ValueKey('new-plan')), findsNothing);
    expect(find.byKey(const ValueKey('edit-f1')), findsNothing);
    expect(find.byKey(const ValueKey('close-f1')), findsNothing);
    expect(find.byKey(const ValueKey('history-f1')), findsOneWidget);
  });

  testWidgets('create plan posts instructions, dates and measurements', (tester) async {
    plans = [];
    await pump(tester, 'doctor', doctorPerms);
    expect(find.text('No follow-up plans.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('new-plan')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('plan-instructions')), 'Check glucose daily');
    await tester.enterText(find.byKey(const ValueKey('m0-min')), '70');
    await tester.enterText(find.byKey(const ValueKey('m0-max')), '140');
    await reveal(tester, find.byKey(const ValueKey('plan-save')));
    await tester.tap(find.byKey(const ValueKey('plan-save')));
    await tester.pumpAndSettle();
    expect(api.bodies['POST /patients/p1/followups'], {
      'instructions': 'Check glucose daily',
      'nextVisitDate': null,
      'endDate': null,
      'measurements': [
        {'kind': 'heart_rate', 'frequency': 'daily', 'normalMin': 70.0, 'normalMax': 140.0},
      ],
    });
  });

  testWidgets('edit sends the current version for optimistic concurrency', (tester) async {
    await pump(tester, 'doctor', doctorPerms);
    await reveal(tester, find.byKey(const ValueKey('edit-f1')));
    await tester.tap(find.byKey(const ValueKey('edit-f1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('plan-instructions')), 'New instructions');
    await reveal(tester, find.byKey(const ValueKey('plan-save')));
    await tester.tap(find.byKey(const ValueKey('plan-save')));
    await tester.pumpAndSettle();
    final b = api.bodies['PATCH /followups/f1'] as Map;
    expect(b['version'], 2);
    expect(b['instructions'], 'New instructions');
    expect((b['measurements'] as List).single['id'], 'm1');
  });

  testWidgets('close plan sends the reason; history lists versions', (tester) async {
    await pump(tester, 'doctor', doctorPerms);
    await reveal(tester, find.byKey(const ValueKey('close-f1')));
    await tester.tap(find.byKey(const ValueKey('close-f1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('close-reason')), 'Recovered');
    await tester.tap(find.byKey(const ValueKey('close-confirm')));
    await tester.pumpAndSettle();
    expect(api.bodies['POST /followups/f1/close'], {'reason': 'Recovered'});
    await reveal(tester, find.byKey(const ValueKey('history-f1')));
    await tester.tap(find.byKey(const ValueKey('history-f1')));
    await tester.pumpAndSettle();
    expect(find.text('v1 created by Dr Test'), findsOneWidget);
  });

  testWidgets('AttentionList lists overdue patients and hides when empty or not permitted', (tester) async {
    var rows = <Map<String, dynamic>>[
      {'careRelationshipId': 'p1', 'patientName': 'Salma Hassan', 'items': [{'planId': 'f1', 'measurementId': 'm1', 'measurementName': 'Blood glucose', 'dueAt': 'x', 'daysOverdue': 3, 'lastSubmittedAt': null}]},
    ];
    final a = RecordingApi({'GET /followups/attention': (_) => rows});
    final s = await sessionFor(a, 'doctor', doctorPerms);
    String? opened;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AttentionList(session: s, onOpenPatient: (id) => opened = id))));
    await tester.pumpAndSettle();
    expect(find.text('Follow-up needs attention (1)'), findsOneWidget);
    expect(find.text('Overdue: Blood glucose (3d)'), findsOneWidget);
    await tester.tap(find.text('Salma Hassan'));
    expect(opened, 'p1');

    final b = RecordingApi({'GET /followups/attention': (_) => rows});
    final s2 = await sessionFor(b, 'receptionist', receptionistPerms);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AttentionList(key: const ValueKey('b'), session: s2))));
    await tester.pumpAndSettle();
    expect(find.textContaining('needs attention'), findsNothing);
    expect(b.calls, isNot(contains('GET /followups/attention')));
  });

  test('trend painter lays points left to right, higher values higher up', () {
    final p = TrendPainter(
      points: [
        TrendPoint(measuredAt: DateTime.utc(2026, 3, 1), value: 100, outside: false),
        TrendPoint(measuredAt: DateTime.utc(2026, 3, 2), value: 180, outside: true),
      ],
      normalMin: 70,
      normalMax: 140,
      line: Colors.blue,
      flagged: Colors.amber,
      guide: Colors.grey,
      label: Colors.black,
    );
    final o = p.layout(const Size(300, 120));
    expect(o[1].dx, greaterThan(o[0].dx));
    expect(o[1].dy, lessThan(o[0].dy));
    expect(o.every((e) => e.dy >= 0 && e.dy <= 120 && e.dx >= 0 && e.dx <= 300), isTrue);
  });
}
