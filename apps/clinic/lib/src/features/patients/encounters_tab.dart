import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../permissions.dart';
import '../../session.dart';
import '../appointments/clinic_clock.dart';
import 'encounter_page.dart';
import 'encounters_api.dart';
import 'patient_tabs.dart';
import 'patients_models.dart';
import 'ui_bits.dart';

/// The patient's encounters, newest first, with "New encounter" for clinical writers.
class EncountersTab extends StatefulWidget {
  const EncountersTab({super.key, required this.session, required this.patient});
  final ClinicSession session;
  final PatientRef patient;

  @override
  State<EncountersTab> createState() => _EncountersTabState();
}

class _EncountersTabState extends State<EncountersTab> {
  late final EncountersApi _api = EncountersApi(widget.session.api);
  ClinicClock _clock = ClinicClock();
  List<EncounterSummary>? _items;
  String? _error;
  bool _creating = false;
  String? _createError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final clockFuture = ClinicClock.load(widget.session.api);
    try {
      final items = await _api.forPatient(widget.patient.relationshipId);
      final clock = await clockFuture;
      if (mounted) {
        setState(() {
          _items = items;
          _clock = clock;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _createError = null;
    });
    try {
      final e = await _api.create(widget.patient.relationshipId);
      if (!mounted) return;
      setState(() => _creating = false);
      await openEncounter(context, widget.session, e.id);
      if (mounted) _load();
    } catch (e) {
      if (mounted) {
        setState(() {
          _creating = false;
          _createError = errorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCreate = widget.session.can(Perm.clinicalWrite) && !widget.patient.isEnded;
    final items = _items;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          if (canCreate)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const ValueKey('new-encounter'),
                onPressed: _creating ? null : _create,
                icon: const Icon(Icons.add),
                label: const Text('New encounter'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              ),
            ),
          if (_createError != null) Padding(padding: const EdgeInsets.only(top: 12), child: ErrorBanner(_createError)),
          const SizedBox(height: 8),
          if (_error != null) ErrorView(message: _error!, onRetry: _load),
          if (items == null && _error == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (items != null && items.isEmpty) const EmptyNote('No encounters yet.'),
          for (final e in items ?? const <EncounterSummary>[])
            Card(
              child: ListTile(
                key: ValueKey('encounter-${e.id}'),
                minVerticalPadding: 12,
                title: Text(e.chiefComplaint.isEmpty ? '(no complaint yet)' : e.chiefComplaint, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text([_clock.dateTime(e.encounterDate), if (e.diagnosis.isNotEmpty) e.diagnosis].join('\n')),
                isThreeLine: e.diagnosis.isNotEmpty,
                trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  StatusPill(e.status == 'signed' ? 'Signed v${e.currentVersion}' : 'Draft', tone: e.status == 'signed' ? PillTone.good : PillTone.warn),
                  if (e.published) const Padding(padding: EdgeInsets.only(top: 4), child: StatusPill('Published')),
                ]),
                onTap: () async {
                  await openEncounter(context, widget.session, e.id);
                  if (mounted) _load();
                },
              ),
            ),
        ],
      ),
    );
  }
}
