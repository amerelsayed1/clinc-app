import 'package:carelink_clinic/src/features/appointments/appointments_models.dart';
import 'package:carelink_clinic/src/features/appointments/appointments_page.dart';
import 'package:carelink_clinic/src/features/appointments/clinic_clock.dart';
import 'package:carelink_clinic/src/session.dart';
import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';
import 'patients_helpers.dart';

final _today = ClinicClock('Africa/Cairo').today();

Future<void> openAppts(WidgetTester tester, ClinicSession session) async {
  await tester.binding.setSurfaceSize(const Size(800, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: AppointmentsPage(session: session, refreshInterval: null))));
  await tester.pumpAndSettle();
}

Map<String, Object? Function(Object?)> baseRoutes(List<Map<String, dynamic>> appts) => {
      'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo', 'slotMinutes': 20, 'workingHours': <String, dynamic>{}},
      'GET /appointments': (_) => appts,
    };

void main() {
  final list = [
    apptJson('w1', 'checked_in', name: 'Waiting Wendy', checkedInAt: '2026-10-24T07:00:00Z'),
    apptJson('w2', 'checked_in', name: 'Waiting Walid', checkedInAt: '2026-10-24T06:00:00Z', walkIn: true),
    apptJson('c1', 'in_consultation', name: 'In Room Ines', encounterId: 'e1'),
    apptJson('s1', 'scheduled', name: 'Later Laila', at: '2099-01-01T10:00:00Z', reason: 'Checkup'),
    apptJson('s2', 'scheduled', name: 'Late Lamia', at: '2020-01-01T10:00:00Z'),
    apptJson('d1', 'completed', name: 'Done Dina'),
  ];

  group('day view', () {
    testWidgets('groups into waiting (by arrival), in consultation, upcoming and closed', (tester) async {
      final api = QueryApi(baseRoutes(list));
      await openAppts(tester, await clinicSession(api, 'doctor', doctorPerms));
      expect(api.lastQuery['GET /appointments']!['date'], _today);
      expect(find.text('Waiting (2)'), findsOneWidget);
      expect(find.text('Upcoming (2)'), findsOneWidget);
      expect(find.text('In consultation'), findsWidgets);
      expect(find.text('Closed'), findsOneWidget);
      // Earliest arrival is #1.
      final first = tester.getTopLeft(find.text('Waiting Walid')).dy;
      final second = tester.getTopLeft(find.text('Waiting Wendy')).dy;
      expect(first, lessThan(second));
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('Checkup'), findsOneWidget);
    });

    testWidgets('empty day shows empty states', (tester) async {
      await openAppts(tester, await clinicSession(QueryApi(baseRoutes([])), 'doctor', doctorPerms));
      expect(find.text('Nobody is waiting.'), findsOneWidget);
      expect(find.text('No upcoming appointments for this day.'), findsOneWidget);
    });

    testWidgets('load failure shows retry', (tester) async {
      final api = QueryApi({'GET /workspace/settings': (_) => {'timezone': 'Africa/Cairo'}});
      await openAppts(tester, await clinicSession(api, 'doctor', doctorPerms));
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('next day reloads with the new date', (tester) async {
      final api = QueryApi(baseRoutes([]));
      await openAppts(tester, await clinicSession(api, 'doctor', doctorPerms));
      await tester.tap(find.byKey(const ValueKey('day-next')));
      await tester.pumpAndSettle();
      expect(api.lastQuery['GET /appointments']!['date'], isNot(_today));
      expect(find.text('Today'), findsOneWidget);
    });
  });

  group('actions by role', () {
    testWidgets('receptionist can check in / reschedule / cancel / no-show but not start consultations', (tester) async {
      final api = QueryApi(baseRoutes(list));
      await openAppts(tester, await clinicSession(api, 'receptionist', receptionistPerms));
      expect(find.byKey(const ValueKey('checkin-s1')), findsOneWidget);
      expect(find.byKey(const ValueKey('reschedule-s1')), findsOneWidget);
      expect(find.byKey(const ValueKey('cancel-w1')), findsOneWidget);
      expect(find.byKey(const ValueKey('noshow-s2')), findsOneWidget); // past start time
      expect(find.byKey(const ValueKey('noshow-s1')), findsNothing); // future: no-show not offered
      expect(find.byKey(const ValueKey('start-w1')), findsNothing);
      expect(find.byKey(const ValueKey('complete-c1')), findsNothing);
      expect(find.byKey(const ValueKey('open-c1')), findsNothing); // no clinical.read
      expect(find.byKey(const ValueKey('new-appointment')), findsOneWidget);
    });

    testWidgets('doctor starts/completes consultations but a read-only role cannot book', (tester) async {
      final api = QueryApi(baseRoutes(list));
      await openAppts(tester, await clinicSession(api, 'doctor', doctorPerms));
      expect(find.byKey(const ValueKey('start-w1')), findsOneWidget);
      expect(find.byKey(const ValueKey('complete-c1')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-c1')), findsOneWidget);

      final api2 = QueryApi(baseRoutes(list));
      await openAppts(tester, await clinicSession(api2, 'nurse', nursePerms));
      expect(find.byKey(const ValueKey('new-appointment')), findsNothing);
      expect(find.byKey(const ValueKey('checkin-s1')), findsNothing);
      expect(find.byKey(const ValueKey('start-w1')), findsNothing);
      expect(find.byKey(const ValueKey('open-c1')), findsOneWidget);
    });
  });

  group('transitions', () {
    testWidgets('check in posts and refreshes', (tester) async {
      final api = QueryApi({...baseRoutes(list), 'POST /appointments/s1/check-in': (_) => apptJson('s1', 'checked_in')});
      await openAppts(tester, await clinicSession(api, 'receptionist', receptionistPerms));
      await tester.tap(find.byKey(const ValueKey('checkin-s1')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('POST /appointments/s1/check-in'));
      expect(api.calls.where((c) => c == 'GET /appointments').length, 2);
    });

    testWidgets('start consultation opens the new encounter', (tester) async {
      final api = QueryApi({
        ...baseRoutes(list),
        'POST /appointments/w1/start': (_) => apptJson('w1', 'in_consultation', encounterId: 'e1'),
        'GET /encounters/e1': (_) => encounterJson(),
      });
      await openAppts(tester, await clinicSession(api, 'doctor', doctorPerms));
      await tester.tap(find.byKey(const ValueKey('start-w1')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('POST /appointments/w1/start'));
      expect(api.calls, contains('GET /encounters/e1'));
      expect(find.text('Encounter'), findsOneWidget);
      expect(find.text('Chief complaint'), findsOneWidget);
    });

    testWidgets('cancel asks for confirmation and an optional reason', (tester) async {
      final api = QueryApi({...baseRoutes(list), 'POST /appointments/s1/cancel': (_) => apptJson('s1', 'cancelled')});
      await openAppts(tester, await clinicSession(api, 'receptionist', receptionistPerms));
      await tester.tap(find.byKey(const ValueKey('cancel-s1')));
      await tester.pumpAndSettle();
      expect(api.calls, isNot(contains('POST /appointments/s1/cancel')));
      await tester.enterText(find.byType(TextField).last, 'patient called');
      await tester.tap(find.widgetWithText(FilledButton, 'Cancel appointment'));
      await tester.pumpAndSettle();
      expect(api.bodies['POST /appointments/s1/cancel'], {'reason': 'patient called'});
    });

    testWidgets('no-show and complete', (tester) async {
      final api = QueryApi({
        ...baseRoutes(list),
        'POST /appointments/s2/no-show': (_) => apptJson('s2', 'no_show'),
        'POST /appointments/c1/complete': (_) => apptJson('c1', 'completed'),
      });
      await openAppts(tester, await clinicSession(api, 'doctor', doctorPerms));
      await tester.tap(find.byKey(const ValueKey('noshow-s2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('complete-c1')));
      await tester.pumpAndSettle();
      expect(api.calls, containsAll(['POST /appointments/s2/no-show', 'POST /appointments/c1/complete']));
    });

    testWidgets('a rejected transition shows the server message', (tester) async {
      final api = QueryApi({...baseRoutes(list), 'POST /appointments/s1/check-in': (_) => throw ApiException(status: 409, code: 'invalid_state', message: 'Cannot check-in an appointment that is cancelled')});
      await openAppts(tester, await clinicSession(api, 'receptionist', receptionistPerms));
      await tester.tap(find.byKey(const ValueKey('checkin-s1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Cannot check-in'), findsOneWidget);
    });
  });

  group('booking', () {
    Map<String, Object? Function(Object?)> bookingRoutes() => {
          ...baseRoutes([]),
          'GET /patients': (_) => [patientJson(), patientJson(id: 'p2', name: 'Sami Mahmoud', number: 14)],
        };

    Future<void> startBooking(WidgetTester tester, QueryApi api) async {
      await openAppts(tester, await clinicSession(api, 'receptionist', receptionistPerms));
      await tester.tap(find.byKey(const ValueKey('new-appointment')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('booking-search')), 'sal');
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('pick-p1')));
      await tester.pumpAndSettle();
    }

    testWidgets('books with the clinic wall-clock start, type and reason', (tester) async {
      final api = QueryApi({...bookingRoutes(), 'POST /appointments': (_) => apptJson('n1', 'scheduled')});
      await startBooking(tester, api);
      expect(api.lastQuery['GET /patients']!['q'], 'sal');
      await tester.enterText(find.byKey(const ValueKey('reason')), 'Follow up on labs');
      await tester.tap(find.text('Follow-up'));
      await tester.enterText(find.byKey(const ValueKey('duration')), '30');
      await tester.tap(find.byKey(const ValueKey('submit-booking')));
      await tester.pumpAndSettle();
      expect(api.bodies['POST /appointments'], {
        'patientId': 'p1',
        'localStart': '${_today}T10:00',
        'type': 'follow_up',
        'reason': 'Follow up on labs',
        'durationMinutes': 30,
      });
      expect(find.byKey(const ValueKey('submit-booking')), findsNothing); // back on the list
    });

    testWidgets('requires a patient', (tester) async {
      final api = QueryApi({...bookingRoutes(), 'POST /appointments': (_) => apptJson('n1', 'scheduled')});
      await openAppts(tester, await clinicSession(api, 'receptionist', receptionistPerms));
      await tester.tap(find.byKey(const ValueKey('new-appointment')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('submit-booking')));
      await tester.pumpAndSettle();
      expect(find.text('Choose a patient first.'), findsOneWidget);
      expect(api.calls, isNot(contains('POST /appointments')));
    });

    testWidgets('slot conflict offers "Book anyway" which re-sends with override', (tester) async {
      var n = 0;
      final api = QueryApi({
        ...bookingRoutes(),
        'POST /appointments': (b) {
          n++;
          if (n == 1) {
            throw ApiException(status: 409, code: 'slot_conflict', message: 'overlap', details: {
              'conflicts': [apptJson('x', 'scheduled', name: 'Existing Eman', at: '2026-10-24T08:00:00Z')],
            });
          }
          return apptJson('n1', 'scheduled');
        },
      });
      await startBooking(tester, api);
      await tester.tap(find.byKey(const ValueKey('submit-booking')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Existing Eman'), findsOneWidget);
      expect((api.bodies['POST /appointments'] as Map).containsKey('override'), isFalse);
      await tester.tap(find.byKey(const ValueKey('book-anyway')));
      await tester.pumpAndSettle();
      expect((api.bodies['POST /appointments'] as Map)['override'], true);
    });

    testWidgets('outside working hours also offers an override', (tester) async {
      final api = QueryApi({...bookingRoutes(), 'POST /appointments': (_) => throw ApiException(status: 409, code: 'outside_working_hours', message: 'outside', details: {'override': true})});
      await startBooking(tester, api);
      await tester.tap(find.byKey(const ValueKey('submit-booking')));
      await tester.pumpAndSettle();
      expect(find.textContaining('outside the clinic working hours'), findsOneWidget);
      expect(find.byKey(const ValueKey('book-anyway')), findsOneWidget);
    });

    testWidgets('walk-in joins the waiting list without a time', (tester) async {
      final api = QueryApi({...bookingRoutes(), 'POST /appointments/walk-in': (_) => apptJson('n2', 'checked_in', walkIn: true)});
      await startBooking(tester, api);
      await tester.tap(find.byKey(const ValueKey('walk-in')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pick-time')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('submit-booking')));
      await tester.pumpAndSettle();
      expect(api.bodies['POST /appointments/walk-in'], {'patientId': 'p1', 'type': 'new'});
    });

    testWidgets('reschedule PATCHes the new start; past/too-short values are the server\'s call', (tester) async {
      final api = QueryApi({
        ...baseRoutes([apptJson('s1', 'scheduled', at: '2099-01-01T10:00:00Z', reason: 'Checkup')]),
        'PATCH /appointments/s1': (_) => apptJson('s1', 'scheduled'),
      });
      await openAppts(tester, await clinicSession(api, 'receptionist', receptionistPerms));
      await tester.tap(find.byKey(const ValueKey('reschedule-s1')));
      await tester.pumpAndSettle();
      // Pre-filled with the current clinic-local time (Cairo is UTC+2 in January).
      expect(find.text('2099-01-01'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('submit-booking')));
      await tester.pumpAndSettle();
      expect(api.bodies['PATCH /appointments/s1'], {'localStart': '2099-01-01T12:00', 'type': 'new', 'reason': 'Checkup'});
    });
  });

  test('ClinicClock formats in the clinic zone', () {
    final c = ClinicClock('Africa/Cairo');
    final winter = DateTime.utc(2026, 1, 15, 22, 30); // 00:30 next day in Cairo (UTC+2)
    expect(c.date(winter), '2026-01-16');
    expect(c.time(winter), '00:30');
    expect(ClinicClock('Not/AZone').zone, 'Not/AZone'); // falls back to Cairo rules instead of throwing
  });

  test('SlotProblem parses conflict details', () {
    final p = SlotProblem.from(ApiException(status: 409, code: 'slot_conflict', message: 'x', details: {'conflicts': [apptJson('a', 'scheduled')]}))!;
    expect(p.conflicts.single.patient.fullName, 'Salma Ali');
    expect(SlotProblem.from(ApiException(status: 400, code: 'in_the_past', message: 'x')), isNull);
  });
}
