import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import 'common.dart';

/// Edits the user's full name (PATCH /me). Used for first-run name capture and the account page.
class ProfileEditor extends StatefulWidget {
  const ProfileEditor({super.key, required this.controller, this.submitLabel = 'Save', this.onSaved});
  final AuthController controller;
  final String submitLabel;
  final VoidCallback? onSaved;

  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.controller.me?.fullName ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.length < 2) {
      setState(() => _error = 'Enter your full name (at least 2 characters).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.updateName(name);
      if (mounted) {
        showSnack(context, 'Saved');
        widget.onSaved?.call();
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ErrorBanner(_error),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          autofillHints: const [AutofillHints.name],
          decoration: const InputDecoration(labelText: 'Full name'),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 16),
        BusyButton(label: widget.submitLabel, busy: _busy, onPressed: _save),
      ]);
}
