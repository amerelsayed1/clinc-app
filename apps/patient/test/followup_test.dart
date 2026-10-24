import 'package:carelink_patient/src/followup_models.dart';
import 'package:carelink_patient/src/followup_page.dart';
import 'package:carelink_patient/src/patient_repository.dart';
import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

/// FakeApi only covers JSON calls; uploads are recorded here.
class UploadFakeApi extends FakeApi {
  UploadFakeApi(super.routes);
  final List<Map<String, String>> uploads = [];

  @override
  Future<dynamic> postMultipart(String path, {Map<String, String> fields = const {}, required List<int> bytes, required String filename, String fileField = 'file'}) async {
    uploads.add({'path': path, 'filename': filename, ...fields});
    return {'id': 'doc-1'};
  }
}

String futureDate(int days) => formatDate(DateTime.now().add(Duration(days: days)));

Map<String, dynamic> planJson({String status = 'active', String? endDate, bool due = true}) => {
      'id': 'p1',
      'clinicName': 'Nile Clinic',
      'doctorName': 'Dr. Omar',
      'status': status,
      'nextVisitDate': '2026-12-01',
      'instructions': 'Measure at rest',
      'startDate': '2026-10-01',
      'endDate': endDate ?? futureDate(10),
      'measurements': [
        {'id': 'm1', 'kind': 'heart_rate', 'name': 'Heart rate', 'unit': 'bpm', 'frequency': 'daily', 'intervalDays': 1, 'active': true, 'lastSubmittedAt': null, 'dueAt': '2026-10-01T00:00:00Z', 'isDue': due},
        {'id': 'm2', 'kind': null, 'name': 'Pain score', 'unit': '/10', 'frequency': 'custom', 'intervalDays': 3, 'active': true, 'lastSubmittedAt': null, 'dueAt': null, 'isDue': false},
      ],
    };

Future<void> show(WidgetTester tester, FakeApi api, {AttachmentPicker? picker}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: FollowupPage(repository: PatientRepository(api), pickAttachment: picker ?? (_) async => null)),
  ));
  await tester.pump();
  await tester.pump();
}

void main() {
  group('input handling', () {
    test('parses decimals including a decimal comma and rejects junk', () {
      expect(parseReading('72'), 72);
      expect(parseReading(' 36,6 '), 36.6);
      expect(parseReading('abc'), isNull);
      expect(parseReading(''), isNull);
      expect(parseReading('Infinity'), isNull);
    });

    test('validation catches bad numbers and future times', () {
      final now = DateTime(2026, 10, 24, 12);
      expect(validateReading(valueText: 'x', measuredAt: now, now: now), contains('number'));
      expect(validateReading(valueText: '70', measuredAt: now.add(const Duration(hours: 2)), now: now), contains('future'));
      expect(validateReading(valueText: '70', measuredAt: now, now: now), isNull);
    });

    test('server rejections map to plain-language messages', () {
      expect(followupErrorMessage(ApiException(status: 409, code: 'plan_closed', message: 'x')), contains('closed'));
      expect(followupErrorMessage(ApiException(status: 409, code: 'plan_ended', message: 'x')), contains('ended'));
    });

    test('plans stop accepting values when closed or past their end date', () {
      expect(FollowupPlan.fromJson(planJson()).acceptsValues, isTrue);
      expect(FollowupPlan.fromJson(planJson(status: 'closed')).acceptsValues, isFalse);
      expect(FollowupPlan.fromJson(planJson(endDate: '2020-01-01')).acceptsValues, isFalse);
      expect(FollowupPlan.fromJson(planJson()).dueCount, 1);
      expect(FollowupPlan.fromJson(planJson(endDate: '2020-01-01')).dueCount, 0);
    });
  });

  testWidgets('empty state explains what the tab is for', (tester) async {
    await show(tester, FakeApi({'GET /patient/followups': (_) => []}));
    expect(find.text('No follow-up requests'), findsOneWidget);
  });

  testWidgets('lists plans with a due count and never shows a range or verdict', (tester) async {
    await show(tester, FakeApi({'GET /patient/followups': (_) => [planJson()]}));
    expect(find.text('Dr. Omar'), findsOneWidget);
    expect(find.text('1 due'), findsOneWidget);
    expect(find.textContaining('outside'), findsNothing);
  });

  testWidgets('submits a value with a note and an attached photo through the document upload', (tester) async {
    Map<String, dynamic>? sent;
    final api = UploadFakeApi({
      'GET /patient/followups': (_) => [planJson()],
      'GET /patient/followups/p1/submissions': (_) => [],
      'POST /patient/followups/p1/submissions': (b) {
        sent = b as Map<String, dynamic>;
        return {'id': 's1', 'measurementName': 'Heart rate', 'unit': 'bpm', 'value': 72, 'measuredAt': sent!['measuredAt'], 'note': 'resting', 'documentId': 'doc-1', 'source': 'patient', 'verified': false};
      },
    });
    await show(tester, api, picker: (_) async => const PickedAttachment([1, 2, 3], 'bp.jpg'));
    await tester.tap(find.text('Dr. Omar'));
    await tester.pumpAndSettle();
    expect(find.text('Measure at rest'), findsOneWidget);
    expect(find.text('Nothing reported yet.'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Report'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Value'), '72,5');
    await tester.enterText(find.widgetWithText(TextField, 'Note (optional)'), 'resting');
    await tester.tap(find.text('Add a photo (optional)'));
    await tester.pumpAndSettle();
    expect(find.text('bp.jpg'), findsOneWidget);
    await tester.ensureVisible(find.text('Send to my doctor'));
    await tester.tap(find.text('Send to my doctor'));
    await tester.pumpAndSettle();

    expect(api.uploads.single, containsPair('path', '/patient/documents'));
    expect(api.uploads.single['category'], 'other');
    expect(sent, containsPair('measurementId', 'm1'));
    expect(sent, containsPair('value', 72.5));
    expect(sent, containsPair('documentId', 'doc-1'));
    expect(sent, containsPair('note', 'resting'));
    expect(DateTime.parse(sent!['measuredAt'] as String).isUtc, isTrue);
  });

  testWidgets('shows the server message when the plan was closed meanwhile', (tester) async {
    final api = FakeApi({
      'GET /patient/followups': (_) => [planJson()],
      'GET /patient/followups/p1/submissions': (_) => [],
      'POST /patient/followups/p1/submissions': (_) => throw ApiException(status: 409, code: 'plan_closed', message: 'closed'),
    });
    await show(tester, api);
    await tester.tap(find.text('Dr. Omar'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Report'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Value'), '70');
    await tester.ensureVisible(find.text('Send to my doctor'));
    await tester.tap(find.text('Send to my doctor'));
    await tester.pumpAndSettle();
    expect(find.textContaining('closed this follow-up plan'), findsOneWidget);
    expect(find.text('Report a value'), findsOneWidget); // still on the form
  });

  testWidgets('a closed plan offers history only, no reporting', (tester) async {
    final api = FakeApi({
      'GET /patient/followups': (_) => [planJson(status: 'closed', due: false)],
      'GET /patient/followups/p1/submissions': (_) => [
            {'id': 's1', 'measurementName': 'Heart rate', 'unit': 'bpm', 'value': 72, 'measuredAt': '2026-10-02T08:00:00Z', 'note': '', 'documentId': null, 'source': 'patient', 'verified': false},
          ],
    });
    await show(tester, api);
    await tester.tap(find.text('Dr. Omar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('closed this follow-up'), findsOneWidget);
    expect(find.text('Report a value'), findsNothing);
    expect(find.textContaining('Heart rate: 72 bpm'), findsOneWidget);
  });
}
