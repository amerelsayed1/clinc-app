import 'dart:async';

import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../permissions.dart';
import '../../session.dart';
import '../patients/encounter_page.dart';
import '../patients/patient_detail_page.dart';
import '../patients/patients_api.dart';
import '../patients/ui_bits.dart';
import 'appointments_api.dart';
import 'appointments_models.dart';
import 'appointments_slots.dart';
import 'booking_page.dart';
import 'clinic_clock.dart';

/// Day view: waiting list, in consultation, upcoming, closed. Booking, reschedule, check-in, no-show,
/// cancel, start/complete consultation. Port of the dashboard's AppointmentsPage.
class AppointmentsPage extends StatefulWidget {
  const AppointmentsPage({super.key, required this.session, this.refreshInterval = const Duration(seconds: 30)});
  final ClinicSession session;

  /// How often the list refreshes by itself (keeps the waiting list fresh); null disables it.
  final Duration? refreshInterval;

  @override
  State<AppointmentsPage> createState() => _AppointmentsPageState();
}

class _AppointmentsPageState extends State<AppointmentsPage> {
  late final AppointmentsApi _api = AppointmentsApi(widget.session.api);
  late final PatientsApi _patients = PatientsApi(widget.session.api);
  ClinicClock? _clock;
  String? _day; // null = today
  List<Appointment>? _items;
  String? _error;
  String? _actionError;
  final Set<String> _busy = {};
  Timer? _timer;

  ClinicSession get s => widget.session;
  String get day => _day ?? _clock?.today() ?? '';

  @override
  void initState() {
    super.initState();
    _init();
    final every = widget.refreshInterval;
    if (every != null) _timer = Timer.periodic(every, (_) => _clock == null ? null : _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    final clock = await ClinicClock.load(s.api);
    if (!mounted) return;
    setState(() => _clock = clock);
    await _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (_clock == null) return;
    final requested = day;
    try {
      final r = await _api.day(requested);
      if (!mounted || requested != day) return;
      setState(() {
        _items = r;
        _error = null;
      });
    } catch (e) {
      if (mounted && !silent) setState(() => _error = errorMessage(e));
    }
  }

  void _setDay(String? d) {
    setState(() {
      _day = d;
      _items = null;
    });
    _load();
  }

  String _shift(int days) {
    final d = DateTime.parse('${day}T12:00:00').add(Duration(days: days));
    return formatDate(d);
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(context: context, initialDate: DateTime.tryParse(day) ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (d != null) _setDay(formatDate(d) == _clock!.today() ? null : formatDate(d));
  }

  Future<void> _book() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => BookingPage(api: _api, patients: _patients, clock: _clock!, initialDay: day),
    ));
    if (ok == true) _load();
  }

  Future<void> _reschedule(Appointment a) async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => BookingPage(api: _api, patients: _patients, clock: _clock!, initialDay: day, editing: a),
    ));
    if (ok == true) _load();
  }

  Future<void> _act(Appointment a, String action) async {
    String? reason;
    if (action == 'cancel') {
      final r = await reasonDialog(context, title: 'Cancel appointment?', label: 'Reason (optional)', confirmLabel: 'Cancel appointment', required: false);
      if (r == null || !mounted) return;
      reason = r;
    }
    setState(() {
      _busy.add(a.id);
      _actionError = null;
    });
    try {
      final r = await _api.act(a.id, action, reason: reason);
      if (!mounted) return;
      await _load();
      if (action == 'start' && r.encounterId != null && mounted) {
        await openEncounter(context, s, r.encounterId!);
        if (mounted) _load();
      }
    } catch (e) {
      if (mounted) setState(() => _actionError = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy.remove(a.id));
    }
  }

  List<Widget> _actions(Appointment a) {
    final manage = s.can(Perm.appointmentsManage);
    final busy = _busy.contains(a.id);
    Widget btn(String key, String label, VoidCallback f, {bool primary = false, bool danger = false}) {
      final style = ButtonStyle(minimumSize: const WidgetStatePropertyAll(Size(48, 44)), foregroundColor: danger ? WidgetStatePropertyAll(Theme.of(context).colorScheme.error) : null);
      return primary
          ? FilledButton(key: ValueKey('$key-${a.id}'), onPressed: busy ? null : f, style: style, child: Text(label))
          : OutlinedButton(key: ValueKey('$key-${a.id}'), onPressed: busy ? null : f, style: style, child: Text(label));
    }

    return [
      if (a.status == 'scheduled' && manage) btn('checkin', 'Check in', () => _act(a, 'check-in'), primary: true),
      if (a.status == 'checked_in' && s.can(Perm.clinicalWrite)) btn('start', 'Start consultation', () => _act(a, 'start'), primary: true),
      if (a.status == 'in_consultation' && a.encounterId != null && s.can(Perm.clinicalRead)) btn('open', 'Open encounter', () => openEncounter(context, s, a.encounterId!), primary: true),
      if (a.status == 'in_consultation' && s.can(Perm.clinicalWrite)) btn('complete', 'Complete', () => _act(a, 'complete')),
      if (a.status == 'scheduled' && manage && !a.scheduledAt.isAfter(DateTime.now())) btn('noshow', 'No-show', () => _act(a, 'no-show')),
      if (a.status == 'scheduled' && manage) btn('reschedule', 'Reschedule', () => _reschedule(a)),
      if ((a.status == 'scheduled' || a.status == 'checked_in') && manage) btn('cancel', 'Cancel', () => _act(a, 'cancel'), danger: true),
    ];
  }

  Widget _card(Appointment a, int index) {
    final clock = _clock!;
    final tone = switch (a.status) {
      'checked_in' => PillTone.warn,
      'in_consultation' => PillTone.good,
      'scheduled' => PillTone.neutral,
      'completed' => PillTone.good,
      _ => PillTone.bad,
    };
    final actions = _actions(a);
    return Card(
      key: ValueKey('appt-${a.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 56, child: Text(a.status == 'checked_in' ? '#${index + 1}' : clock.time(a.scheduledAt), style: Theme.of(context).textTheme.titleMedium)),
            Expanded(
              child: InkWell(
                onTap: s.can(Perm.patientsRead) ? () => openPatient(context, s, a.patient.id) : null,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.patient.fullName, style: Theme.of(context).textTheme.titleSmall),
                  Wrap(spacing: 6, children: [
                    Text('${a.durationMinutes} min', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
                    if (a.isWalkIn) const Text('· Walk-in'),
                    if (a.isFollowUp) const Text('· Follow-up'),
                  ]),
                  if ((a.reason ?? '').isNotEmpty) Text(a.reason!),
                  if ((a.cancelReason ?? '').isNotEmpty) Text('Cancelled: ${a.cancelReason}'),
                ]),
              ),
            ),
            StatusPill(appointmentStatusLabel(a.status), tone: tone),
          ]),
          if (actions.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Wrap(spacing: 8, runSpacing: 8, children: actions)),
        ]),
      ),
    );
  }

  List<Widget> _section(String title, List<Appointment> rows, {String? empty, bool alwaysShow = false}) {
    if (rows.isEmpty && !alwaysShow) return const [];
    return [
      SectionTitle(title),
      if (rows.isEmpty && empty != null) EmptyNote(empty),
      for (var i = 0; i < rows.length; i++) _card(rows[i], i),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final clock = _clock;
    final canBook = s.can(Perm.appointmentsManage);
    final all = _items ?? const <Appointment>[];
    final waiting = all.where((a) => a.status == 'checked_in').toList()..sort((a, b) => (a.checkedInAt ?? a.scheduledAt).compareTo(b.checkedInAt ?? b.scheduledAt));
    final inRoom = all.where((a) => a.status == 'in_consultation').toList();
    final upcoming = all.where((a) => a.status == 'scheduled').toList();
    final closed = all.where((a) => const ['completed', 'cancelled', 'no_show'].contains(a.status)).toList();
    final isToday = clock != null && day == clock.today();
    return Scaffold(
      floatingActionButton: canBook && clock != null
          ? FloatingActionButton.extended(key: const ValueKey('new-appointment'), onPressed: _book, icon: const Icon(Icons.add), label: const Text('Book'))
          : null,
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(children: [
            IconButton(key: const ValueKey('day-prev'), tooltip: 'Previous day', icon: const Icon(Icons.chevron_left), onPressed: clock == null ? null : () => _setDay(_shift(-1))),
            Expanded(
              child: TextButton.icon(
                key: const ValueKey('day-pick'),
                onPressed: clock == null ? null : _pickDay,
                icon: const Icon(Icons.calendar_today_outlined, size: 18),
                label: Text(clock == null ? '…' : (isToday ? 'Today · $day' : day)),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              ),
            ),
            IconButton(key: const ValueKey('day-next'), tooltip: 'Next day', icon: const Icon(Icons.chevron_right), onPressed: clock == null ? null : () => _setDay(_shift(1))),
            if (!isToday && clock != null) TextButton(onPressed: () => _setDay(null), child: const Text('Today')),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(),
            child: _error != null && _items == null
                ? ListView(children: [SizedBox(height: 360, child: ErrorView(message: _error!, onRetry: _load))])
                : _items == null
                    ? ListView(children: const [SizedBox(height: 240, child: LoadingView())])
                    : ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                        children: [
                          for (final slot in appointmentHeaderSlots) slot(context, s),
                          if (_actionError != null) Padding(padding: const EdgeInsets.only(top: 8), child: ErrorBanner(_actionError)),
                          ..._section('Waiting (${waiting.length})', waiting, empty: 'Nobody is waiting.', alwaysShow: true),
                          ..._section('In consultation', inRoom),
                          ..._section('Upcoming (${upcoming.length})', upcoming, empty: 'No upcoming appointments for this day.', alwaysShow: true),
                          ..._section('Closed', closed),
                        ],
                      ),
          ),
        ),
      ]),
    );
  }
}
