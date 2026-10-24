import 'package:flutter/material.dart';

import 'patients_models.dart';

class _RxCtl {
  _RxCtl(Rx r)
      : medication = TextEditingController(text: r.medication),
        dose = TextEditingController(text: r.dose),
        frequency = TextEditingController(text: r.frequency),
        duration = TextEditingController(text: r.duration),
        notes = TextEditingController(text: r.notes);
  final TextEditingController medication, dose, frequency, duration, notes;
  Rx get value => Rx(medication: medication.text, dose: dose.text, frequency: frequency.text, duration: duration.text, notes: notes.text);
  void dispose() {
    for (final c in [medication, dose, frequency, duration, notes]) {
      c.dispose();
    }
  }
}

/// The clinical note fields + prescription rows. Owns its text controllers; reports every edit through
/// [onChanged] with the full content. Rebuild with a new `key` to load different [initial] content.
class EncounterContentForm extends StatefulWidget {
  const EncounterContentForm({super.key, required this.initial, required this.onChanged, required this.showPrivate, this.readOnly = false});
  final EncContent initial;
  final ValueChanged<EncContent> onChanged;

  /// Doctors see (and edit) their private notes; nobody else gets the field.
  final bool showPrivate;
  final bool readOnly;

  @override
  State<EncounterContentForm> createState() => _EncounterContentFormState();
}

class _EncounterContentFormState extends State<EncounterContentForm> {
  late final TextEditingController _complaint = TextEditingController(text: widget.initial.chiefComplaint);
  late final TextEditingController _history = TextEditingController(text: widget.initial.history);
  late final TextEditingController _diagnosis = TextEditingController(text: widget.initial.diagnosis);
  late final TextEditingController _plan = TextEditingController(text: widget.initial.plan);
  late final TextEditingController _private = TextEditingController(text: widget.initial.privateNotes ?? '');
  late final List<_RxCtl> _rx = [for (final r in widget.initial.prescriptions) _RxCtl(r)];

  @override
  void dispose() {
    for (final c in [_complaint, _history, _diagnosis, _plan, _private]) {
      c.dispose();
    }
    for (final r in _rx) {
      r.dispose();
    }
    super.dispose();
  }

  void _emit() => widget.onChanged(EncContent(
        chiefComplaint: _complaint.text,
        history: _history.text,
        diagnosis: _diagnosis.text,
        plan: _plan.text,
        privateNotes: widget.showPrivate ? _private.text : widget.initial.privateNotes,
        prescriptions: [for (final r in _rx) r.value],
      ));

  Widget _field(String label, TextEditingController c, {int minLines = 2, int? maxLines = 8, String? helper}) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: TextField(
          controller: c,
          readOnly: widget.readOnly,
          minLines: minLines,
          maxLines: maxLines,
          maxLength: 10000,
          buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: label, helperText: helper, helperMaxLines: 2, alignLabelWithHint: true, border: const OutlineInputBorder()),
          onChanged: (_) => _emit(),
        ),
      );

  Widget _line(String label, TextEditingController c) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          readOnly: widget.readOnly,
          maxLength: 200,
          buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
          onChanged: (_) => _emit(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _field('Chief complaint', _complaint, minLines: 2),
      _field('History', _history, minLines: 3),
      _field('Diagnosis', _diagnosis, minLines: 2),
      _field('Plan', _plan, minLines: 3),
      if (widget.showPrivate) _field('Private notes', _private, minLines: 2, helper: 'Only you can see these; never shared or shown to patients.'),
      Padding(padding: const EdgeInsets.only(top: 4, bottom: 8), child: Text('Prescription', style: Theme.of(context).textTheme.titleMedium)),
      if (_rx.isEmpty) Text('No medications.', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
      for (var i = 0; i < _rx.length; i++)
        Card(
          key: ObjectKey(_rx[i]),
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(children: [
                  _line('Medication', _rx[i].medication),
                  _line('Dose', _rx[i].dose),
                  _line('Frequency', _rx[i].frequency),
                  _line('Duration', _rx[i].duration),
                  _line('Notes', _rx[i].notes),
                ]),
              ),
              if (!widget.readOnly)
                IconButton(
                  key: ValueKey('rx-remove-$i'),
                  tooltip: 'Remove medication',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    final removed = _rx[i];
                    setState(() => _rx.removeAt(i));
                    WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
                    _emit();
                  },
                ),
            ]),
          ),
        ),
      if (!widget.readOnly)
        OutlinedButton.icon(
          key: const ValueKey('rx-add'),
          onPressed: () {
            setState(() => _rx.add(_RxCtl(const Rx())));
            _emit();
          },
          icon: const Icon(Icons.add),
          label: const Text('Add medication'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
    ]);
  }
}
