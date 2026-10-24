import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../permissions.dart';
import '../../session.dart';
import '../appointments/clinic_clock.dart';
import 'encounters_api.dart';
import 'patients_models.dart';
import 'ui_bits.dart';

/// Vitals recorded in this encounter, with entry (draft + vitals.write) and void (own entries, or any for doctors).
class VitalsCard extends StatefulWidget {
  const VitalsCard({super.key, required this.encounter, required this.session, required this.api, required this.clock, required this.onChanged});
  final Encounter encounter;
  final ClinicSession session;
  final EncountersApi api;
  final ClinicClock clock;
  final VoidCallback onChanged;

  @override
  State<VitalsCard> createState() => _VitalsCardState();
}

class _VitalsCardState extends State<VitalsCard> {
  String _kind = 'weight_kg';
  final _value = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final v = double.tryParse(_value.text.trim().replaceAll(',', '.'));
    final spec = vitalKinds[_kind]!;
    if (v == null) {
      setState(() => _error = 'Enter a number.');
      return;
    }
    if (v < spec.min || v > spec.max) {
      setState(() => _error = '${spec.label} must be between ${spec.min} and ${spec.max} ${spec.unit}.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.addObservation(widget.encounter.id, kind: _kind, value: v);
      _value.clear();
      widget.onChanged();
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _void(Observation o) async {
    final reason = await reasonDialog(context, title: 'Void ${o.label}?', label: 'Why is this entry wrong?', confirmLabel: 'Void entry');
    if (reason == null || !mounted) return;
    try {
      await widget.api.voidObservation(widget.encounter.id, o.id, reason);
      widget.onChanged();
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.encounter;
    final s = widget.session;
    final editable = e.isDraft && s.can(Perm.vitalsWrite);
    final active = e.observations.where((o) => !o.voided).toList();
    final voided = e.observations.length - active.length;
    final me = s.me?.id;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Vitals', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (active.isEmpty) const Text('No vitals recorded.'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final o in active)
              InputChip(
                key: ValueKey('vital-${o.id}'),
                label: Text('${o.label} ${o.valueText} ${o.unit} · ${o.recordedRole}'),
                tooltip: 'Recorded by ${o.recordedByName ?? 'unknown'}',
                onDeleted: editable && (o.recordedBy == me || s.isDoctor) ? () => _void(o) : null,
                deleteIcon: const Icon(Icons.cancel_outlined, semanticLabel: 'Void'),
                deleteButtonTooltipMessage: 'Void this entry',
              ),
          ]),
          if (voided > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('$voided voided ${voided == 1 ? 'entry' : 'entries'} kept on record.', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
            ),
          if (editable) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('vital-kind'),
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Measurement', border: OutlineInputBorder(), isDense: true),
              items: [for (final k in vitalKinds.entries) DropdownMenuItem(value: k.key, child: Text('${k.value.label} (${k.value.unit})'))],
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('vital-value'),
                  controller: _value,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Value', border: OutlineInputBorder(), isDense: true),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(key: const ValueKey('vital-add'), onPressed: _busy ? null : _add, style: FilledButton.styleFrom(minimumSize: const Size(72, 48)), child: const Text('Add')),
            ]),
          ],
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: ErrorBanner(_error)),
        ]),
      ),
    );
  }
}
