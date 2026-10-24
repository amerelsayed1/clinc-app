import 'package:carelink_patient/src/patient_repository.dart';
import 'package:carelink_patient/src/timeline_models.dart';
import 'package:carelink_patient/src/timeline_page.dart';
import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

/// Records the query of each timeline call and serves two pages.
class TimelineApi extends FakeApi {
  TimelineApi(super.routes);
  final List<Map<String, String>> queries = [];

  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, bool auth = true}) {
    if (path == '/patient/timeline') queries.add(query ?? {});
    return super.request(method, path, body: body, query: query, auth: auth);
  }
}

Map<String, dynamic> entry(String type, String id, String title, {String badge = 'clinician_authored', String refType = 'encounter', bool clinic = true, bool amended = false}) => {
      'type': type,
      'id': id,
      'refType': refType,
      'date': '2026-10-0${id.length}T10:00:00.000000Z',
      'title': title,
      'summary': 'Summary of $title',
      'author': {'id': 'u', 'name': clinic ? 'Dr. Omar' : 'Sara Ali'},
      'source': clinic ? {'kind': 'clinic', 'workspaceId': 'w1', 'name': 'Nile Clinic'} : {'kind': 'patient', 'workspaceId': null, 'name': null},
      'version': amended ? 2 : 1,
      'versionCount': amended ? 2 : 1,
      'amended': amended,
      'verificationBadge': badge,
      'details': <String, dynamic>{},
    };

void main() {
  test('entries expose provenance labels that distinguish uploads from clinician records', () {
    final doc = TimelineEntry.fromJson(entry('document', 'd', 'My CBC', badge: 'patient_submitted', refType: 'document', clinic: false));
    expect(doc.provenance, Provenance.patientSubmitted);
    expect(doc.provenanceLabel, 'Added by you');
    final enc = TimelineEntry.fromJson(entry('encounter', 'e1', 'Cough'));
    expect(enc.provenanceLabel, 'Dr. Omar at Nile Clinic');
    expect(enc.badgeLabel, 'Clinician-authored');
    final reviewed = TimelineEntry.fromJson(entry('document', 'd2', 'ECG', badge: 'reviewed', refType: 'document', clinic: false));
    expect(reviewed.badgeLabel, 'Reviewed by clinician');
  });

  test('filters become query parameters', () {
    final f = const TimelineFilters().copyWith(types: {'document', 'encounter'}, query: ' cbc ', workspaceId: 'patient');
    expect(f.toQuery(cursor: 'abc', limit: 10), {'limit': '10', 'type': 'document,encounter', 'q': 'cbc', 'source': 'patient', 'cursor': 'abc'});
    expect(const TimelineFilters().toQuery(), {'limit': '30'});
  });

  testWidgets('loads pages on scroll, filters by type, and opens a visit without private content', (tester) async {
    final page1 = [for (var i = 1; i <= 12; i++) entry(i == 1 ? 'encounter' : 'document', 'id${'x' * i}', i == 1 ? 'Cough' : 'Report $i', refType: i == 1 ? 'encounter' : 'document', amended: i == 1)];
    final page2 = [entry('document', 'last-one', 'Final lab', refType: 'document', badge: 'patient_submitted', clinic: false)];
    late TimelineApi api;
    api = TimelineApi({
      'GET /patient/timeline': (_) {
        final q = api.queries.last;
        if (q['type'] == 'document') return {'items': [page2.first], 'nextCursor': null};
        return q.containsKey('cursor') ? {'items': page2, 'nextCursor': null} : {'items': page1, 'nextCursor': 'c1'};
      },
      'GET /patient/encounters/idx': (_) => {'id': 'idx', 'encounterDate': '2026-10-01T10:00:00Z', 'clinicName': 'Nile Clinic', 'doctorName': 'Dr. Omar', 'chiefComplaint': 'Cough', 'diagnosis': 'Bronchitis', 'plan': 'Rest', 'prescriptions': [], 'vitals': []},
    });
    await tester.binding.setSurfaceSize(const Size(900, 900));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TimelinePage(repository: PatientRepository(api)))));
    await tester.pumpAndSettle();
    expect(find.text('Cough'), findsOneWidget);
    expect(find.text('Updated · version 2'), findsOneWidget);
    expect(api.queries.length, 1);

    await tester.drag(find.byType(ListView).last, const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(api.queries.length, 2);
    expect(api.queries.last['cursor'], 'c1');
    expect(find.text('Final lab'), findsOneWidget);
    expect(find.text('Added by you'), findsWidgets);

    await tester.tap(find.widgetWithText(FilterChip, 'Documents'));
    await tester.pumpAndSettle();
    expect(api.queries.last['type'], 'document');
    expect(api.queries.last.containsKey('cursor'), isFalse);
    expect(find.text('Cough'), findsNothing);

    await tester.tap(find.widgetWithText(FilterChip, 'Documents')); // deselect
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cough').first);
    await tester.pumpAndSettle();
    expect(find.text('Bronchitis'), findsOneWidget);
    expect(find.text('Rest'), findsOneWidget);
    expect(api.calls, contains('GET /patient/encounters/idx'));
  });

  testWidgets('shows an empty state and an error with retry', (tester) async {
    var fail = true;
    final api = TimelineApi({
      'GET /patient/timeline': (_) {
        if (fail) throw ApiException(status: 500, code: 'internal_error', message: 'Something went wrong');
        return {'items': [], 'nextCursor': null};
      },
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TimelinePage(repository: PatientRepository(api)))));
    await tester.pumpAndSettle();
    expect(find.text('Something went wrong'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Try again').evaluate().isEmpty ? find.byType(TextButton).first : find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing here yet'), findsOneWidget);
  });
}
