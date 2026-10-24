import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../permissions.dart';
import '../../session.dart';
import 'patient_form_page.dart';
import 'patient_tabs.dart';
import 'patients_api.dart';
import 'patients_models.dart';
import 'patients_page.dart' show statusTone;
import 'ui_bits.dart';

/// Opens a patient (care relationship) full screen.
Future<void> openPatient(BuildContext context, ClinicSession session, String relationshipId) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PatientDetailPage(session: session, patientId: relationshipId)));

/// Detail shell: header, edit / end relationship, and a TabBar built from [patientTabs] filtered by permission.
class PatientDetailPage extends StatefulWidget {
  const PatientDetailPage({super.key, required this.session, required this.patientId, this.tabs});
  final ClinicSession session;
  final String patientId;

  /// Overrides [patientTabs] (tests).
  final List<PatientTab>? tabs;

  @override
  State<PatientDetailPage> createState() => _PatientDetailPageState();
}

class _PatientDetailPageState extends State<PatientDetailPage> {
  late final PatientsApi _api = PatientsApi(widget.session.api);
  Patient? _patient;
  String? _error;
  String? _actionError;

  ClinicSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await _api.get(widget.patientId);
      if (mounted) {
        setState(() {
          _patient = p;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && _patient == null) setState(() => _error = errorMessage(e));
    }
  }

  Future<void> _edit() async {
    final p = await Navigator.of(context).push<Patient>(MaterialPageRoute(builder: (_) => PatientFormPage(api: _api, editing: _patient)));
    if (p != null && mounted) {
      setState(() => _patient = p);
      showSnack(context, 'Patient updated');
    }
  }

  Future<void> _end() async {
    final p = _patient!;
    final ok = await confirmAction(
      context,
      title: 'End care relationship?',
      message: 'End your care relationship with ${p.fullName}? You will lose access to this patient going forward and their open appointments are cancelled.',
      confirmLabel: 'End relationship',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await _api.end(p.id);
      await _load();
      if (mounted) setState(() => _actionError = null);
    } catch (e) {
      if (mounted) setState(() => _actionError = errorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _patient;
    if (p == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Patient')),
        body: _error != null ? ErrorView(message: _error!, onRetry: _load) : const LoadingView(),
      );
    }
    final ref = PatientRef.fromPatient(p);
    final tabs = [for (final t in widget.tabs ?? patientTabs) if (s.canAll(t.requiredPermissions)) t];
    final canEdit = !p.isEnded && s.can(Perm.patientsWrite);
    final canEnd = !p.isEnded && s.can(Perm.relationshipsManage);
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(p.fullName),
          actions: [
            if (canEdit || canEnd)
              PopupMenuButton<String>(
                key: const ValueKey('patient-menu'),
                onSelected: (v) => v == 'edit' ? _edit() : _end(),
                itemBuilder: (_) => [
                  if (canEdit) const PopupMenuItem(value: 'edit', child: Text('Edit details')),
                  if (canEnd) const PopupMenuItem(value: 'end', child: Text('End relationship')),
                ],
              ),
          ],
          bottom: tabs.length > 1 ? TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [for (final t in tabs) Tab(text: t.label)]) : null,
        ),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(children: [
              StatusPill(statusLabel(p.status), tone: statusTone(p.status)),
              const SizedBox(width: 10),
              Expanded(child: Text('${patientNo(p.patientNumber)} · ${p.phone}', overflow: TextOverflow.ellipsis)),
            ]),
          ),
          if (_actionError != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: ErrorBanner(_actionError)),
          Expanded(
            child: tabs.isEmpty
                ? const Center(child: Text('Nothing to show for your role.'))
                : TabBarView(
                    children: [for (final t in tabs) Builder(key: ValueKey('tab-${t.label}'), builder: (c) => t.builder(c, s, ref))],
                  ),
          ),
        ]),
      ),
    );
  }
}
