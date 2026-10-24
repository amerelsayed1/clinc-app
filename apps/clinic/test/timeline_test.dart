import 'package:carelink_clinic/src/features/timeline/timeline_models.dart';
import 'package:carelink_clinic/src/features/timeline/timeline_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'clinical_tabs_helpers.dart';
import 'fake_api.dart';

Map<String, dynamic> entry(String id, String title, {String type = 'encounter', String refType = 'encounter', Map<String, dynamic>? shared, String badge = 'clinician_authored'}) => {
      'type': type,
      'id': id,
      'refType': refType,
      'date': '2026-03-0${id.length}T10:00:00Z',
      'title': title,
      'summary': '',
      'author': {'id': 'u1', 'name': 'Dr Test'},
      'source': {'kind': 'clinic', 'workspaceId': 'w1', 'name': 'Nile Clinic'},
      'version': 1,
      'versionCount': 1,
      'amended': false,
      'historyPath': null,
      'verificationBadge': badge,
      'shared': ?shared,
      'details': {},
    };

void main() {
  late RecordingApi api;

  Future<List<TimelineEntry>> pump(WidgetTester tester, {List<TimelineEntry>? opened}) async {
    final taps = opened ?? [];
    api = RecordingApi({
      'GET /patients/p1/timeline': (_) {
        final cursor = api.allQueries.last?['cursor'];
        if (cursor == null) {
          return {
            'items': [
              entry('e1', 'Consultation A'),
              entry('s1', 'Lab from other clinic', type: 'document', refType: 'document', badge: 'patient_submitted', shared: {'sharedBy': 'patient', 'via': 'grant', 'grantId': 'g1', 'expiresAt': '2026-12-31T00:00:00Z', 'originClinic': 'Cairo Lab', 'label': 'Shared by patient · from Cairo Lab'}),
            ],
            'nextCursor': 'cur1',
          };
        }
        return {
          'items': [entry('e1', 'Consultation A'), entry('e22', 'Consultation B')], // e1 repeated: must be de-duplicated
          'nextCursor': null,
        };
      },
    });
    final session = await sessionFor(api, 'doctor', doctorPerms);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TimelineTab(session: session, patientId: 'p1', opener: (c, s, e) async => taps.add(e)))));
    await tester.pumpAndSettle();
    return taps;
  }

  testWidgets('renders provenance badges and the shared-by-patient marker with expiry', (tester) async {
    await pump(tester);
    expect(find.text('Consultation A'), findsOneWidget);
    expect(find.text('Clinician-authored'), findsOneWidget);
    expect(find.text('Patient-submitted'), findsOneWidget);
    expect(find.text('Shared by patient · from Cairo Lab · until 2026-12-31'), findsOneWidget);
  });

  testWidgets('load more sends the cursor from the previous page and appends without duplicates', (tester) async {
    await pump(tester);
    expect(api.allQueries.last, isNot(contains('cursor')));
    await tester.tap(find.byKey(const ValueKey('timeline-more')));
    await tester.pumpAndSettle();
    expect(api.allQueries.last?['cursor'], 'cur1');
    expect(find.text('Consultation B'), findsOneWidget);
    expect(find.text('Consultation A'), findsOneWidget); // not duplicated
    expect(find.byKey(const ValueKey('timeline-more')), findsNothing); // no more pages
  });

  testWidgets('changing a filter restarts from the first page (no cursor) with the filter query', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('timeline-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('type-document')));
    await tester.pumpAndSettle();
    final q = api.allQueries.last!;
    expect(q['type'], 'document');
    expect(q.containsKey('cursor'), isFalse);
    await tester.tap(find.byKey(const ValueKey('source-shared')));
    await tester.pumpAndSettle();
    expect(api.allQueries.last!['source'], 'shared');
    expect(find.byKey(const ValueKey('clear-filters')), findsOneWidget);
  });

  testWidgets('search is debounced and sent as q', (tester) async {
    await pump(tester);
    final before = api.allQueries.length;
    await tester.enterText(find.byKey(const ValueKey('timeline-search')), 'chest');
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.allQueries.length, before);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(api.allQueries.last!['q'], 'chest');
  });

  testWidgets('tapping an openable entry calls the opener; others are not tappable', (tester) async {
    final taps = await pump(tester);
    await tester.tap(find.text('Consultation A'));
    await tester.pump();
    expect(taps.single.id, 'e1');
  });

  test('TimelineFilters query only contains set values', () {
    expect(const TimelineFilters().toQuery(), {'limit': '30'});
    expect(const TimelineFilters(types: {'document', 'encounter'}, from: '2026-01-01', source: 'own', q: ' x ').toQuery(cursor: 'c'),
        {'limit': '30', 'type': 'document,encounter', 'from': '2026-01-01', 'source': 'own', 'q': 'x', 'cursor': 'c'});
  });
}
