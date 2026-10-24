import 'dart:async';

import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'encounter_form.dart';
import 'encounters_api.dart';
import 'patients_models.dart';
import 'ui_bits.dart';

/// Delay after the last keystroke before a draft is saved. Tests shorten it.
Duration encounterAutosaveDelay = const Duration(milliseconds: 1200);

/// Delay before a failed save (offline, server error) is retried.
Duration encounterRetryDelay = const Duration(seconds: 6);

enum SaveState { saved, dirty, saving, conflict, offline }

/// Editable draft with autosave and optimistic concurrency (revision).
///
/// Offline-tolerant: a failed save keeps the text, shows "Not saved" and retries on a timer; nothing
/// the user typed is thrown away unless they choose "Reload the latest version" after a conflict.
class DraftEditor extends StatefulWidget {
  const DraftEditor({
    super.key,
    required this.encounter,
    required this.api,
    required this.showPrivate,
    required this.onSigned,
    required this.onDiscarded,
    required this.onReload,
  });

  final Encounter encounter;
  final EncountersApi api;
  final bool showPrivate;
  final ValueChanged<Encounter> onSigned;
  final VoidCallback onDiscarded;

  /// Re-fetch the encounter and rebuild this editor from it (drops local edits).
  final Future<void> Function() onReload;

  @override
  State<DraftEditor> createState() => DraftEditorState();
}

class DraftEditorState extends State<DraftEditor> {
  late EncContent _content = widget.encounter.content;
  late int _revision = widget.encounter.revision;
  SaveState _state = SaveState.saved;
  bool _dirty = false;
  bool _inFlight = false;
  bool _conflictShown = false;
  Timer? _timer;
  String? _signError;
  bool _signing = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool get hasUnsaved => _dirty || _state == SaveState.saving;

  void _change(EncContent c) {
    _content = c;
    _dirty = true;
    if (_state != SaveState.conflict) setState(() => _state = SaveState.dirty);
    _schedule(encounterAutosaveDelay);
  }

  void _schedule(Duration d) {
    _timer?.cancel();
    if (_state == SaveState.conflict) return;
    _timer = Timer(d, () async {
      if (_inFlight) return _schedule(encounterAutosaveDelay);
      await save();
    });
  }

  /// Saves pending edits. Returns true when nothing is left unsaved.
  Future<bool> save() async {
    while (_inFlight) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    if (!_dirty) return true;
    _inFlight = true;
    _dirty = false;
    if (mounted) setState(() => _state = SaveState.saving);
    try {
      final r = await widget.api.saveDraft(widget.encounter.id, revision: _revision, content: _content, includePrivate: widget.showPrivate);
      _revision = r.revision;
      if (mounted) setState(() => _state = _dirty ? SaveState.dirty : SaveState.saved);
      if (_dirty) _schedule(encounterAutosaveDelay);
      return !_dirty;
    } catch (e) {
      _dirty = true;
      final conflict = e is ApiException && e.code == 'revision_conflict';
      if (mounted) {
        setState(() => _state = conflict ? SaveState.conflict : SaveState.offline);
        if (conflict) {
          _conflictDetails = e.details;
          if (!_conflictShown) {
            _conflictShown = true;
            WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _conflictDialog() : null);
          }
        } else {
          _schedule(encounterRetryDelay);
        }
      }
      return false;
    } finally {
      _inFlight = false;
    }
  }

  Object? _conflictDetails;

  Future<void> _conflictDialog() async {
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Draft changed elsewhere'),
        content: const Text('This draft was changed in another window or device, so your latest edits were not saved. Reload the latest version, or keep your text and overwrite the other change.'),
        actions: [
          TextButton(key: const ValueKey('conflict-overwrite'), onPressed: () => Navigator.pop(ctx, 'overwrite'), child: const Text('Keep mine')),
          FilledButton(key: const ValueKey('conflict-reload'), onPressed: () => Navigator.pop(ctx, 'reload'), child: const Text('Reload latest')),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'reload') {
      _dirty = false;
      _timer?.cancel();
      await widget.onReload();
    } else if (choice == 'overwrite') {
      final d = _conflictDetails;
      final rev = d is Map ? (d['revision'] as num?)?.toInt() : null;
      if (rev != null) _revision = rev;
      _conflictShown = false;
      setState(() => _state = SaveState.dirty);
      _dirty = true;
      await save();
    }
  }

  Future<void> _sign() async {
    if (_content.chiefComplaint.trim().isEmpty) {
      setState(() => _signError = 'Add a chief complaint before signing.');
      return;
    }
    if (_content.hasIncompletePrescription) {
      setState(() => _signError = 'A medication row has no medication name. Fill it in or remove it.');
      return;
    }
    final ok = await confirmAction(context,
        title: 'Sign this encounter?', message: 'After signing it can only be changed by a recorded amendment.', confirmLabel: 'Sign');
    if (!ok || !mounted) return;
    setState(() {
      _signing = true;
      _signError = null;
    });
    _timer?.cancel();
    try {
      if (!await save()) throw StateError('unsaved');
      final signed = await widget.api.sign(widget.encounter.id, revision: _revision);
      if (mounted) widget.onSigned(signed);
    } catch (e) {
      if (mounted) {
        setState(() => _signError = e is ApiException ? e.message : 'Could not save your latest changes. Check your connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _signing = false);
    }
  }

  Future<void> _discard() async {
    final ok = await confirmAction(context, title: 'Discard this draft?', message: 'The draft will be removed. This cannot be undone.', confirmLabel: 'Discard', destructive: true);
    if (!ok || !mounted) return;
    try {
      await widget.api.discard(widget.encounter.id);
      _dirty = false;
      _timer?.cancel();
      if (mounted) widget.onDiscarded();
    } catch (e) {
      if (mounted) setState(() => _signError = errorMessage(e));
    }
  }

  (String, IconData) get _stateLabel => switch (_state) {
        SaveState.saved => ('All changes saved', Icons.cloud_done_outlined),
        SaveState.dirty => ('Unsaved changes…', Icons.edit_note),
        SaveState.saving => ('Saving…', Icons.sync),
        SaveState.conflict => ('Conflict - not saved', Icons.error_outline),
        SaveState.offline => ('Not saved - will retry', Icons.cloud_off_outlined),
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (label, icon) = _stateLabel;
    final warn = _state == SaveState.conflict || _state == SaveState.offline;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_state == SaveState.conflict)
        InfoBanner(
          'This draft was changed elsewhere. Your latest edits were not saved.',
          error: true,
          action: TextButton(onPressed: _conflictDialog, child: const Text('Resolve')),
        ),
      EncounterContentForm(initial: widget.encounter.content, showPrivate: widget.showPrivate, onChanged: _change),
      const SizedBox(height: 8),
      Row(children: [
        Icon(icon, size: 18, color: warn ? cs.error : cs.outline),
        const SizedBox(width: 6),
        Expanded(child: Text(label, key: const ValueKey('save-state'), style: TextStyle(color: warn ? cs.error : cs.outline))),
        if (warn)
          TextButton(
            key: const ValueKey('retry-save'),
            onPressed: _state == SaveState.offline ? save : _conflictDialog,
            child: Text(_state == SaveState.offline ? 'Retry now' : 'Resolve'),
          ),
      ]),
      if (_signError != null) ErrorBanner(_signError),
      const SizedBox(height: 8),
      Row(children: [
        OutlinedButton(
          key: const ValueKey('discard-draft'),
          onPressed: _signing ? null : _discard,
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: cs.error),
          child: const Text('Discard'),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            key: const ValueKey('sign-encounter'),
            onPressed: (_signing || _state == SaveState.conflict) ? null : _sign,
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            child: _signing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Sign encounter'),
          ),
        ),
      ]),
    ]);
  }
}
