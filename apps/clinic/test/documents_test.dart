import 'package:carelink_clinic/src/features/documents/document_upload_page.dart';
import 'package:carelink_clinic/src/features/documents/documents_models.dart';
import 'package:carelink_clinic/src/features/documents/documents_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'clinical_tabs_helpers.dart';
import 'fake_api.dart';

Map<String, dynamic> doc(String id, {String source = 'clinician', String category = 'lab_result', String title = 'CBC', bool published = false, bool reviewed = false}) => {
      'id': id,
      'source': source,
      'provenance': source == 'patient' ? 'patient_submitted_unverified' : 'clinician_authored',
      'uploaderName': source == 'patient' ? 'Salma' : 'Dr Test',
      'uploaderRole': source == 'patient' ? 'patient' : 'doctor',
      'category': category,
      'title': title,
      'notes': '',
      'documentDate': '2026-03-01',
      'totalBytes': 204800,
      'published': published,
      'reviewed': reviewed,
      'createdAt': '2026-03-02T10:00:00Z',
      'pages': [
        {'page': 1, 'mime': 'image/jpeg', 'sizeBytes': 102400},
        {'page': 2, 'mime': 'image/jpeg', 'sizeBytes': 102400},
      ],
    };

class FakePicker implements PagePicker {
  int n = 0;
  @override
  Future<PickedPage?> camera() async => PickedPage(name: 'p${++n}.jpg', bytes: const [1, 2, 3]);
  @override
  Future<List<PickedPage>> gallery() async => [PickedPage(name: 'g${++n}.jpg', bytes: const [4, 5])];
}

void main() {
  var docs = <Map<String, dynamic>>[];
  late RecordingApi api;

  Future<void> pump(WidgetTester tester, String role, List<String> perms) async {
    api = RecordingApi({
      'GET /patients/p1/documents': (_) => docs,
      'GET /workspace/storage': (_) => {'usedBytes': 5 * 1024 * 1024, 'quotaBytes': 100 * 1024 * 1024},
      'POST /documents/d1/publish': (_) => {'ok': true},
      'POST /documents/d1/unpublish': (_) => {'ok': true},
      'POST /documents/d2/review': (_) => {'ok': true},
      'DELETE /documents/d1': (_) => {'ok': true},
    });
    final session = await sessionFor(api, role, perms);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentsTab(session: session, patientId: 'p1', picker: FakePicker()))));
    await tester.pumpAndSettle();
  }

  setUp(() => docs = [doc('d1'), doc('d2', source: 'patient', title: 'Old X-ray')]);

  testWidgets('doctor: list with provenance labels and storage quota', (tester) async {
    await pump(tester, 'doctor', doctorPerms);
    expect(find.text('CBC'), findsOneWidget);
    expect(find.text('Patient-submitted · unverified'), findsOneWidget);
    expect(find.textContaining('5.0 MB of 100 MB used'), findsOneWidget);
    expect(find.byKey(const ValueKey('add-document')), findsOneWidget);
    expect(find.byKey(const ValueKey('publish-d1')), findsOneWidget);
    expect(find.byKey(const ValueKey('review-d2')), findsOneWidget);
    // patient-submitted documents are never published or deleted from here
    expect(find.byKey(const ValueKey('publish-d2')), findsNothing);
    expect(find.byKey(const ValueKey('delete-d2')), findsNothing);
  });

  testWidgets('receptionist: can upload and delete but not publish/review; administrative only', (tester) async {
    docs = [doc('d1', category: 'administrative', title: 'ID copy')];
    await pump(tester, 'receptionist', receptionistPerms);
    expect(find.byKey(const ValueKey('add-document')), findsOneWidget);
    expect(find.byKey(const ValueKey('delete-d1')), findsOneWidget);
    expect(find.byKey(const ValueKey('publish-d1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('add-document')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('doc-category')));
    await tester.pumpAndSettle();
    expect(find.text('Administrative'), findsWidgets);
    expect(find.text('Lab result'), findsNothing);
  });

  testWidgets('read-only role: no upload, no storage, no actions', (tester) async {
    await pump(tester, 'nurse', ['patients.read', 'clinical.read']);
    expect(find.byKey(const ValueKey('add-document')), findsNothing);
    expect(find.byKey(const ValueKey('delete-d1')), findsNothing);
    expect(api.calls, isNot(contains('GET /workspace/storage')));
  });

  testWidgets('upload sends every page as a file part plus the form fields', (tester) async {
    await pump(tester, 'doctor', doctorPerms);
    api.uploadResponse = doc('d9');
    await tester.tap(find.byKey(const ValueKey('add-document')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('doc-submit'))).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('doc-camera')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('doc-camera')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('doc-gallery')));
    await tester.pumpAndSettle();
    expect(find.text('Page 3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('remove-page-0'))); // drops p1
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('doc-title')), 'Chest X-ray');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('doc-notes')), 200, scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.byKey(const ValueKey('doc-notes')), 'PA view');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('doc-submit')), 200, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.byKey(const ValueKey('doc-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('doc-submit')));
    await tester.pumpAndSettle();
    expect(api.uploads, hasLength(1));
    final u = api.uploads.single;
    expect(u.path, '/patients/p1/documents');
    expect(u.files, ['p2.jpg', 'g3.jpg']);
    expect(u.fields, {'category': 'lab_result', 'title': 'Chest X-ray', 'notes': 'PA view'});
    // popped back to the list, which reloads
    expect(find.byKey(const ValueKey('add-document')), findsOneWidget);
    expect(find.text('Document uploaded'), findsOneWidget);
  });

  testWidgets('show to patient asks first, then publishes; hide unpublishes', (tester) async {
    await pump(tester, 'doctor', doctorPerms);
    await tester.tap(find.byKey(const ValueKey('publish-d1')));
    await tester.pumpAndSettle();
    expect(find.text('Show to patient?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.calls, isNot(contains('POST /documents/d1/publish')));
    await tester.tap(find.byKey(const ValueKey('publish-d1')));
    await tester.pumpAndSettle();
    docs = [doc('d1', published: true), doc('d2', source: 'patient')];
    await tester.tap(find.widgetWithText(FilledButton, 'Show to patient'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /documents/d1/publish'));
    expect(find.text('Hide from patient'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('publish-d1')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /documents/d1/unpublish'));
  });

  testWidgets('delete needs a reason of at least 3 characters', (tester) async {
    await pump(tester, 'doctor', doctorPerms);
    await tester.tap(find.byKey(const ValueKey('delete-d1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('delete-reason')), 'ab');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('delete-confirm'))).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('delete-reason')), 'Wrong patient');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('delete-confirm')));
    await tester.pumpAndSettle();
    expect(api.bodies['DELETE /documents/d1'], {'reason': 'Wrong patient'});
  });

  testWidgets('mark reviewed calls the review endpoint', (tester) async {
    await pump(tester, 'doctor', doctorPerms);
    await tester.tap(find.byKey(const ValueKey('review-d2')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /documents/d2/review'));
  });

  testWidgets('shows an error with retry when the list fails', (tester) async {
    await pump(tester, 'doctor', doctorPerms);
    api.routes.remove('GET /patients/p1/documents');
    await tester.drag(find.byType(ListView).first, const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.textContaining('No fake for'), findsOneWidget);
  });
}
