import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'patients_api.dart';
import 'patients_models.dart';
import 'ui_bits.dart';

/// Register a new patient, or (with [editing]) edit demographics. Pops the saved [Patient].
class PatientFormPage extends StatefulWidget {
  const PatientFormPage({super.key, required this.api, this.editing});
  final PatientsApi api;
  final Patient? editing;

  @override
  State<PatientFormPage> createState() => _PatientFormPageState();
}

class _PatientFormPageState extends State<PatientFormPage> {
  late final _name = TextEditingController(text: widget.editing?.fullName ?? '');
  late final _phone = TextEditingController(text: widget.editing?.phone ?? '+20');
  late String? _dob = widget.editing?.dateOfBirth;
  late String? _sex = widget.editing?.sex;
  bool _busy = false;
  bool _duplicate = false;
  String? _error;

  bool get _isEdit => widget.editing != null;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final initial = DateTime.tryParse(_dob ?? '') ?? DateTime(now.year - 30);
    final d = await showDatePicker(context: context, initialDate: initial, firstDate: DateTime(1900), lastDate: now, helpText: 'Date of birth');
    if (d != null) setState(() => _dob = formatDate(d));
  }

  Future<void> _submit({bool confirmNotDuplicate = false}) async {
    if (_name.text.trim().length < 2) {
      setState(() => _error = 'Enter the patient\'s full name.');
      return;
    }
    if (!_isEdit && !isValidPhone(_phone.text.trim())) {
      setState(() => _error = 'Enter the phone number in international format, e.g. +201001234567.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _duplicate = false;
    });
    try {
      final Patient p = _isEdit
          ? await widget.api.update(widget.editing!.id, fullName: _name.text, dateOfBirth: _dob, sex: _sex)
          : await widget.api.create(phone: _phone.text, fullName: _name.text, dateOfBirth: _dob, sex: _sex, confirmNotDuplicate: confirmNotDuplicate);
      if (mounted) Navigator.of(context).pop(p);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (e is ApiException && e.code == 'possible_duplicate') {
          _duplicate = true;
        } else {
          _error = errorMessage(e);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit patient' : 'Register patient')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            autofocus: !_isEdit,
            decoration: const InputDecoration(labelText: 'Full name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _phone,
            enabled: !_isEdit,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: 'Phone number', helperText: _isEdit ? 'The phone number cannot be changed.' : 'International format, e.g. +201001234567', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          InkWell(
            key: const ValueKey('dob-field'),
            onTap: _pickDob,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Date of birth (optional)',
                border: const OutlineInputBorder(),
                suffixIcon: _dob == null ? const Icon(Icons.calendar_today_outlined) : IconButton(icon: const Icon(Icons.clear), tooltip: 'Clear', onPressed: () => setState(() => _dob = null)),
              ),
              child: Text(_dob ?? 'Not set'),
            ),
          ),
          const SizedBox(height: 16),
          Text('Sex (optional)', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: 'female', label: Text('Female')), ButtonSegment(value: 'male', label: Text('Male'))],
            selected: _sex == null ? <String>{} : {_sex!},
            onSelectionChanged: (v) => setState(() => _sex = v.isEmpty ? null : v.first),
          ),
          const SizedBox(height: 24),
          if (_error != null) ErrorBanner(_error),
          if (_duplicate)
            InfoBanner(
              'A patient with this name and date of birth already exists in your clinic.',
              icon: Icons.warning_amber_outlined,
              action: TextButton(
                key: const ValueKey('register-anyway'),
                onPressed: _busy ? null : () => _submit(confirmNotDuplicate: true),
                child: const Text('This is a different person - register anyway'),
              ),
            ),
          FilledButton(
            key: const ValueKey('save-patient'),
            onPressed: _busy ? null : () => _submit(),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(_isEdit ? 'Save' : 'Register'),
          ),
        ],
      ),
    );
  }
}
