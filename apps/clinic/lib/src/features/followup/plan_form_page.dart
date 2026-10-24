import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'followup_api.dart';
import 'followup_models.dart';

/// Create (plan == null) or edit a follow-up plan. Pops `true` when saved.
class PlanFormPage extends StatefulWidget {
  const PlanFormPage({super.key, required this.api, required this.patientId, this.plan});
  final FollowupApi api;
  final String patientId;
  final FollowupPlan? plan;

  @override
  State<PlanFormPage> createState() => _PlanFormPageState();
}

class _PlanFormPageState extends State<PlanFormPage> {
  late final _instructions = TextEditingController(text: widget.plan?.instructions ?? '');
  late String? _next = widget.plan?.nextVisitDate;
  late String? _start = widget.plan?.startDate;
  late String? _end = widget.plan?.endDate;
  late final List<MeasurementDraft> _rows = widget.plan == null ? [MeasurementDraft()] : widget.plan!.activeMeasurements.map(MeasurementDraft.of).toList();
  final _key = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;

  bool get _editing => widget.plan != null;

  @override
  void dispose() {
    _instructions.dispose();
    super.dispose();
  }

  Future<String?> _pick(String? current, {DateTime? first}) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(current ?? '') ?? now,
      firstDate: first ?? DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    return d == null ? current : formatDate(d);
  }

  Future<void> _save() async {
    if (!_key.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final common = <String, dynamic>{
        'instructions': _instructions.text.trim(),
        'nextVisitDate': _next,
        'endDate': _end,
        'measurements': [for (final r in _rows) r.toJson()],
      };
      if (_editing) {
        await widget.api.edit(widget.plan!.id, {...common, 'version': widget.plan!.currentVersion});
      } else {
        await widget.api.create(widget.patientId, {...common, if (_start != null) 'startDate': _start});
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorMessage(e);
          _busy = false;
        });
      }
    }
  }

  Widget _dateButton(String label, String? value, ValueChanged<String?> onChanged, {Key? key, DateTime? first, bool clearable = true}) => Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            key: key,
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52), alignment: Alignment.centerLeft),
            onPressed: _busy ? null : () async => onChanged(await _pick(value, first: first)),
            icon: const Icon(Icons.event_outlined),
            label: Text(value == null ? label : '$label: $value'),
          ),
        ),
        if (clearable && value != null) IconButton(tooltip: 'Clear', onPressed: _busy ? null : () => onChanged(null), icon: const Icon(Icons.clear)),
      ]);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit follow-up plan' : 'New follow-up plan')),
      body: Form(
        key: _key,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(key: const ValueKey('plan-instructions'), controller: _instructions, maxLines: 4, maxLength: 2000, decoration: const InputDecoration(labelText: 'Instructions for the patient', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          _dateButton('Next visit', _next, (v) => setState(() => _next = v), key: const ValueKey('plan-next')),
          const SizedBox(height: 8),
          if (!_editing) ...[
            _dateButton('Start date (default today)', _start, (v) => setState(() => _start = v), key: const ValueKey('plan-start')),
            const SizedBox(height: 8),
          ],
          _dateButton('End date', _end, (v) => setState(() => _end = v), key: const ValueKey('plan-end')),
          const SizedBox(height: 20),
          Text('Requested measurements', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final (i, r) in _rows.indexed) _row(i, r),
          const SizedBox(height: 4),
          Text('The expected range only highlights values for you; patients never see it.', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          if (_rows.length < 10)
            OutlinedButton.icon(key: const ValueKey('add-measurement'), style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)), onPressed: _busy ? null : () => setState(() => _rows.add(MeasurementDraft())), icon: const Icon(Icons.add), label: const Text('Add measurement')),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: ErrorBanner(_error)),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('plan-save'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _busy ? null : _save,
            child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)) : Text(_editing ? 'Save changes' : 'Create plan'),
          ),
        ]),
      ),
    );
  }

  Widget _row(int i, MeasurementDraft r) {
    return Card(
      key: ObjectKey(r),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('m$i-kind'),
                initialValue: r.kind,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Measurement', border: OutlineInputBorder()),
                items: [for (final k in vitalKinds) DropdownMenuItem(value: k.$1, child: Text('${k.$2} (${k.$3})')), const DropdownMenuItem(value: '', child: Text('Custom…'))],
                onChanged: (v) => setState(() => r.kind = v ?? ''),
              ),
            ),
            IconButton(key: ValueKey('m$i-remove'), tooltip: 'Remove measurement', onPressed: _rows.length <= 1 ? null : () => setState(() => _rows.removeAt(i)), icon: const Icon(Icons.delete_outline)),
          ]),
          if (r.kind.isEmpty) ...[
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                flex: 3,
                child: TextFormField(key: ValueKey('m$i-name'), initialValue: r.name, maxLength: 80, onChanged: (v) => r.name = v, validator: (v) => (v ?? '').trim().isEmpty ? 'Name required' : null, decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder())),
              ),
              const SizedBox(width: 8),
              Expanded(child: TextFormField(key: ValueKey('m$i-unit'), initialValue: r.unit, maxLength: 20, onChanged: (v) => r.unit = v, decoration: const InputDecoration(labelText: 'Unit', border: OutlineInputBorder()))),
            ]),
          ],
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey('m$i-freq'),
            initialValue: r.frequency,
            decoration: const InputDecoration(labelText: 'How often', border: OutlineInputBorder()),
            items: const [DropdownMenuItem(value: 'daily', child: Text('Daily')), DropdownMenuItem(value: 'weekly', child: Text('Weekly')), DropdownMenuItem(value: 'custom', child: Text('Every N days'))],
            onChanged: (v) => setState(() => r.frequency = v ?? 'daily'),
          ),
          if (r.frequency == 'custom') ...[
            const SizedBox(height: 8),
            TextFormField(
              key: ValueKey('m$i-interval'),
              initialValue: r.intervalDays,
              keyboardType: TextInputType.number,
              onChanged: (v) => r.intervalDays = v,
              validator: (v) {
                final n = int.tryParse((v ?? '').trim());
                return n == null || n < 1 || n > 90 ? '1 to 90 days' : null;
              },
              decoration: const InputDecoration(labelText: 'Every N days (1-90)', border: OutlineInputBorder()),
            ),
          ],
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _numField(i, 'min', 'Expected min', r.normalMin, (v) => r.normalMin = v)),
            const SizedBox(width: 8),
            Expanded(child: _numField(i, 'max', 'Expected max', r.normalMax, (v) => r.normalMax = v, validator: (v) {
              final lo = double.tryParse(r.normalMin.trim()), hi = double.tryParse((v ?? '').trim());
              return lo != null && hi != null && hi < lo ? 'Below min' : null;
            })),
          ]),
        ]),
      ),
    );
  }

  Widget _numField(int i, String id, String label, String initial, ValueChanged<String> onChanged, {String? Function(String?)? validator}) => TextFormField(
        key: ValueKey('m$i-$id'),
        initialValue: initial,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        onChanged: onChanged,
        validator: (v) {
          final t = (v ?? '').trim();
          if (t.isNotEmpty && double.tryParse(t) == null) return 'Number';
          return validator?.call(v);
        },
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      );
}
