import 'dart:async';

import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../patients/patients_api.dart';
import '../patients/patients_models.dart';
import '../patients/ui_bits.dart';
import 'appointments_api.dart';
import 'appointments_models.dart';
import 'clinic_clock.dart';

/// Book a new appointment / walk-in, or (with [editing]) reschedule a scheduled one. Pops true on success.
class BookingPage extends StatefulWidget {
  const BookingPage({
    super.key,
    required this.api,
    required this.patients,
    required this.clock,
    required this.initialDay,
    this.editing,
    this.patient,
    this.searchDebounce = const Duration(milliseconds: 300),
  });
  final AppointmentsApi api;
  final PatientsApi patients;
  final ClinicClock clock;

  /// `YYYY-MM-DD` the day view is showing.
  final String initialDay;
  final Appointment? editing;

  /// Pre-selected patient.
  final Patient? patient;
  final Duration searchDebounce;

  @override
  State<BookingPage> createState() => _BookingPageState();
}

class _BookingPageState extends State<BookingPage> {
  final _search = TextEditingController();
  late final _duration = TextEditingController();
  late final _reason = TextEditingController(text: widget.editing?.reason ?? '');
  Timer? _debounce;
  String? _patientId;
  String? _patientName;
  List<Patient> _found = const [];
  String? _searchError;
  late String _date = widget.editing == null ? widget.initialDay : widget.clock.date(widget.editing!.scheduledAt);
  late TimeOfDay _time = widget.editing == null
      ? const TimeOfDay(hour: 10, minute: 0)
      : () {
          final t = widget.clock.time(widget.editing!.scheduledAt).split(':');
          return TimeOfDay(hour: int.parse(t[0]), minute: int.parse(t[1]));
        }();
  late String _type = widget.editing?.type ?? 'new';
  bool _walkIn = false;
  bool _busy = false;
  String? _error;
  SlotProblem? _problem;

  bool get _isEdit => widget.editing != null;

  @override
  void initState() {
    super.initState();
    if (widget.editing != null) {
      _patientId = widget.editing!.patient.id;
      _patientName = widget.editing!.patient.fullName;
    } else if (widget.patient != null) {
      _patientId = widget.patient!.id;
      _patientName = widget.patient!.fullName;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _duration.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _onSearch(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() => _found = const []);
      return;
    }
    _debounce = Timer(widget.searchDebounce, () async {
      try {
        final r = await widget.patients.list(q: q, limit: 6);
        if (mounted) {
          setState(() {
            _found = r;
            _searchError = null;
          });
        }
      } catch (e) {
        if (mounted) setState(() => _searchError = errorMessage(e));
      }
    });
  }

  Future<void> _pickDate() async {
    final current = DateTime.tryParse(_date) ?? DateTime.now();
    final d = await showDatePicker(context: context, initialDate: current, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 730)));
    if (d != null) setState(() => _date = formatDate(d));
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: _time);
    if (t != null) setState(() => _time = t);
  }

  String get _localStart => '${_date}T${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';

  Future<void> _submit({bool override = false}) async {
    if (_patientId == null) {
      setState(() => _error = 'Choose a patient first.');
      return;
    }
    final minutes = _duration.text.trim().isEmpty ? null : int.tryParse(_duration.text.trim());
    if (_duration.text.trim().isNotEmpty && (minutes == null || minutes < 5 || minutes > 480)) {
      setState(() => _error = 'Duration must be between 5 and 480 minutes.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _problem = null;
    });
    try {
      if (_isEdit) {
        await widget.api.reschedule(widget.editing!.id, localStart: _localStart, type: _type, reason: _reason.text, durationMinutes: minutes, override: override);
      } else if (_walkIn) {
        await widget.api.walkIn(patientId: _patientId!, type: _type, reason: _reason.text);
      } else {
        await widget.api.book(patientId: _patientId!, localStart: _localStart, type: _type, reason: _reason.text, durationMinutes: minutes, override: override);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = SlotProblem.from(e);
        if (_problem == null) _error = errorMessage(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Reschedule' : 'New appointment')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_patientId != null && !_isEdit)
            Card(
              child: ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(_patientName ?? ''),
                trailing: widget.patient == null ? TextButton(onPressed: () => setState(() => _patientId = null), child: const Text('Change')) : null,
              ),
            )
          else if (_isEdit)
            ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.person_outline), title: Text(_patientName ?? ''))
          else ...[
            TextField(
              key: const ValueKey('booking-search'),
              controller: _search,
              onChanged: _onSearch,
              decoration: const InputDecoration(labelText: 'Patient', hintText: 'Search name, #number or exact phone', prefixIcon: Icon(Icons.search), border: OutlineInputBorder()),
            ),
            if (_searchError != null) ErrorBanner(_searchError),
            for (final p in _found)
              ListTile(
                key: ValueKey('pick-${p.id}'),
                title: Text(p.fullName),
                subtitle: Text('${patientNo(p.patientNumber)} · ${p.phone}'),
                onTap: () => setState(() {
                  _patientId = p.id;
                  _patientName = p.fullName;
                  _found = const [];
                }),
              ),
          ],
          const SizedBox(height: 8),
          if (!_isEdit)
            SwitchListTile(
              key: const ValueKey('walk-in'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Walk-in'),
              subtitle: const Text('Join the waiting list now'),
              value: _walkIn,
              onChanged: (v) => setState(() => _walkIn = v),
            ),
          if (!_walkIn) ...[
            Row(children: [
              Expanded(
                child: InkWell(
                  key: const ValueKey('pick-date'),
                  onTap: _pickDate,
                  child: InputDecorator(decoration: const InputDecoration(labelText: 'Date', border: OutlineInputBorder(), suffixIcon: Icon(Icons.calendar_today_outlined)), child: Text(_date)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  key: const ValueKey('pick-time'),
                  onTap: _pickTime,
                  child: InputDecorator(
                      decoration: InputDecoration(labelText: 'Time (${widget.clock.zone})', border: const OutlineInputBorder(), suffixIcon: const Icon(Icons.schedule)),
                      child: Text(_time.format(context))),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('duration'),
              controller: _duration,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Duration in minutes (optional)', helperText: 'Leave empty for the clinic default.', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
          ],
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: 'new', label: Text('New')), ButtonSegment(value: 'follow_up', label: Text('Follow-up'))],
            selected: {_type},
            onSelectionChanged: (v) => setState(() => _type = v.first),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('reason'),
            controller: _reason,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Reason (no diagnoses)', border: OutlineInputBorder()),
          ),
          if (_error != null) ErrorBanner(_error),
          if (problem != null)
            InfoBanner(
              problem.code == 'slot_conflict'
                  ? 'This time overlaps ${problem.conflicts.isEmpty ? 'another appointment' : problem.conflicts.map((c) => '${c.patient.fullName} (${widget.clock.time(c.scheduledAt)})').join(', ')}.'
                  : 'This time is outside the clinic working hours.',
              icon: Icons.warning_amber_outlined,
              action: TextButton(key: const ValueKey('book-anyway'), onPressed: _busy ? null : () => _submit(override: true), child: Text(_isEdit ? 'Reschedule anyway' : 'Book anyway')),
            ),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('submit-booking'),
            onPressed: _busy ? null : () => _submit(),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(_isEdit ? 'Save new time' : (_walkIn ? 'Add to waiting list' : 'Book')),
          ),
        ],
      ),
    );
  }
}
