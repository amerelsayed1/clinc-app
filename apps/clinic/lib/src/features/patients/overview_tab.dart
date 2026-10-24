import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../permissions.dart';
import '../../session.dart';
import '../appointments/appointments_api.dart';
import '../appointments/appointments_models.dart';
import '../appointments/clinic_clock.dart';
import 'encounters_api.dart';
import 'patient_tabs.dart';
import 'patients_models.dart';
import 'ui_bits.dart';

/// Demographics, the patient's appointment history and (clinical readers only) the vitals trend.
class OverviewTab extends StatefulWidget {
  const OverviewTab({super.key, required this.session, required this.patient});
  final ClinicSession session;
  final PatientRef patient;

  @override
  State<OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<OverviewTab> {
  ClinicClock _clock = ClinicClock();
  List<Appointment>? _appointments;
  String? _apptError;
  int _refreshes = 0;

  ClinicSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final clock = await ClinicClock.load(s.api);
    List<Appointment>? appts;
    String? err;
    if (s.can(Perm.appointmentsRead)) {
      try {
        appts = await AppointmentsApi(s.api).forPatient(widget.patient.relationshipId);
      } catch (e) {
        err = errorMessage(e);
      }
    }
    if (!mounted) return;
    setState(() {
      _clock = clock;
      _appointments = appts;
      _apptError = err;
      _refreshes++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.patient.patient;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                _row('Patient no.', p == null ? '—' : patientNo(p.patientNumber)),
                _row('Phone', p?.phone ?? '—'),
                _row('Date of birth', p?.dateOfBirth ?? '—'),
                _row('Sex', p?.sex == null ? '—' : '${p!.sex![0].toUpperCase()}${p.sex!.substring(1)}'),
                _row('Patient app', widget.patient.hasAccount ? 'Has an account' : 'Not yet signed up'),
                if (p?.createdAt != null) _row('Registered', formatDate(p!.createdAt)),
                if (p?.endedAt != null) _row('Ended', '${formatDate(p!.endedAt)} by ${p.endedBy ?? 'unknown'}'),
              ]),
            ),
          ),
          if (s.can(Perm.clinicalRead)) VitalsTrend(session: s, patientId: widget.patient.relationshipId, clock: _clock, key: ValueKey('trend$_refreshes')),
          if (s.can(Perm.appointmentsRead)) ...[
            const SectionTitle('Appointments'),
            if (_apptError != null) ErrorBanner(_apptError),
            if (_appointments == null && _apptError == null) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
            if (_appointments != null && _appointments!.isEmpty) const EmptyNote('No appointments yet.'),
            for (final a in _appointments ?? const <Appointment>[])
              Card(
                child: ListTile(
                  title: Text(_clock.dateTime(a.scheduledAt)),
                  subtitle: Text('${a.isFollowUp ? 'Follow-up' : 'New'}${a.isWalkIn ? ' · walk-in' : ''}'),
                  trailing: StatusPill(appointmentStatusLabel(a.status)),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 120, child: Text(k, style: TextStyle(color: Theme.of(context).colorScheme.outline))),
          Expanded(child: Text(v)),
        ]),
      );
}

/// One vital sign across all of this clinic's encounters for the patient (spec F05-8).
class VitalsTrend extends StatefulWidget {
  const VitalsTrend({super.key, required this.session, required this.patientId, required this.clock});
  final ClinicSession session;
  final String patientId;
  final ClinicClock clock;

  @override
  State<VitalsTrend> createState() => _VitalsTrendState();
}

class _VitalsTrendState extends State<VitalsTrend> {
  String _kind = 'weight_kg';
  List<TrendPoint>? _points;
  String _unit = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _points = null;
      _error = null;
    });
    try {
      final r = await EncountersApi(widget.session.api).trend(widget.patientId, _kind);
      if (mounted) {
        setState(() {
          _points = r.points;
          _unit = r.unit;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pts = _points;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionTitle(
        'Vitals trend',
        trailing: DropdownButton<String>(
          key: const ValueKey('trend-kind'),
          value: _kind,
          items: [for (final e in vitalKinds.entries) DropdownMenuItem(value: e.key, child: Text('${e.value.label} (${e.value.unit})'))],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _kind = v);
            _load();
          },
        ),
      ),
      if (_error != null) ErrorBanner(_error),
      if (pts == null && _error == null) const LinearProgressIndicator(),
      if (pts != null && pts.isEmpty) const EmptyNote('No measurements yet.'),
      if (pts != null && pts.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              SizedBox(height: 90, width: double.infinity, child: CustomPaint(painter: _TrendPainter([for (final p in pts) p.value], Theme.of(context).colorScheme.primary))),
              const Divider(),
              for (final p in pts.reversed.take(8))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Expanded(child: Text(widget.clock.dateTime(p.measuredAt))),
                    Text('${p.value == p.value.roundToDouble() ? p.value.toStringAsFixed(0) : p.value} $_unit', style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                ),
            ]),
          ),
        ),
    ]);
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.values, this.color);
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final lo = values.reduce((a, b) => a < b ? a : b);
    final hi = values.reduce((a, b) => a > b ? a : b);
    double x(int i) => values.length == 1 ? size.width / 2 : 8 + i * (size.width - 16) / (values.length - 1);
    double y(double v) => hi == lo ? size.height / 2 : size.height - 8 - (v - lo) / (hi - lo) * (size.height - 16);
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      i == 0 ? path.moveTo(x(i), y(values[i])) : path.lineTo(x(i), y(values[i]));
    }
    canvas.drawPath(path, line);
    final dot = Paint()..color = color;
    for (var i = 0; i < values.length; i++) {
      canvas.drawCircle(Offset(x(i), y(values[i])), 3.5, dot);
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.values != values || old.color != color;
}
