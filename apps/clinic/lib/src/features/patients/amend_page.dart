import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'encounter_form.dart';
import 'encounters_api.dart';
import 'patients_models.dart';
import 'ui_bits.dart';

/// Amend a signed encounter: edit fields + a required reason; creates version N+1. Pops the updated encounter.
class AmendPage extends StatefulWidget {
  const AmendPage({super.key, required this.encounter, required this.api, required this.showPrivate});
  final Encounter encounter;
  final EncountersApi api;
  final bool showPrivate;

  @override
  State<AmendPage> createState() => _AmendPageState();
}

class _AmendPageState extends State<AmendPage> {
  late EncContent _content = widget.encounter.content;
  final _reason = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final e = widget.encounter;
    if (_reason.text.trim().length < 3) {
      setState(() => _error = 'Give a reason for the amendment (at least 3 characters).');
      return;
    }
    if (_content.chiefComplaint.trim().isEmpty) {
      setState(() => _error = 'Chief complaint cannot be empty.');
      return;
    }
    if (_content.hasIncompletePrescription) {
      setState(() => _error = 'A medication row has no medication name. Fill it in or remove it.');
      return;
    }
    final changes = _content.changesFrom(e.content, includePrivate: widget.showPrivate);
    if (changes.isEmpty) {
      setState(() => _error = 'Nothing was changed.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.amend(e.id, baseVersion: e.currentVersion, reason: _reason.text.trim(), changes: changes);
      if (mounted) Navigator.of(context).pop(r);
    } catch (err) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorMessage(err);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.encounter;
    return Scaffold(
      appBar: AppBar(title: const Text('Amend encounter')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          InfoBanner('Amending creates version ${e.currentVersion + 1}. The original stays on record and visible in the version history.'),
          EncounterContentForm(initial: e.content, showPrivate: widget.showPrivate, onChanged: (c) => _content = c),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('amend-reason'),
            controller: _reason,
            maxLength: 500,
            decoration: const InputDecoration(labelText: 'Reason for amendment (required)', border: OutlineInputBorder()),
          ),
          if (_error != null) ErrorBanner(_error),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('save-amendment'),
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save amendment'),
          ),
        ],
      ),
    );
  }
}
