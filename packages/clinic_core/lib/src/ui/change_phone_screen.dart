import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import 'common.dart';

/// Change phone number: a code is sent to the old and the new number; both must be entered.
class ChangePhoneScreen extends StatefulWidget {
  const ChangePhoneScreen({super.key, required this.controller});
  final AuthController controller;

  @override
  State<ChangePhoneScreen> createState() => _ChangePhoneScreenState();
}

class _ChangePhoneScreenState extends State<ChangePhoneScreen> {
  final _phone = TextEditingController();
  final _oldCode = TextEditingController();
  final _newCode = TextEditingController();
  String? _newPhone;
  String? _devNote;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _oldCode.dispose();
    _newCode.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    final phone = _phone.text.replaceAll(RegExp(r'[\s-]'), '');
    if (!isValidPhone(phone)) {
      setState(() => _error = 'Enter the new number in international format, e.g. +201001234567.');
      return;
    }
    await _run(() async {
      final dev = await widget.controller.requestPhoneChange(phone);
      if (!mounted) return;
      setState(() {
        _newPhone = phone;
        _devNote = dev.oldCode != null ? 'Development codes - current number: ${dev.oldCode}, new number: ${dev.newCode}' : null;
      });
    });
  }

  Future<void> _confirm() async {
    if (_oldCode.text.length != 6 || _newCode.text.length != 6) {
      setState(() => _error = 'Enter both 6-digit codes.');
      return;
    }
    await _run(() async {
      await widget.controller.confirmPhoneChange(newPhone: _newPhone!, oldCode: _oldCode.text, newCode: _newCode.text);
      if (!mounted) return;
      showSnack(context, 'Phone number updated. Other devices were signed out.');
      Navigator.of(context).pop(true);
    });
  }

  Future<void> _run(Future<void> Function() fn) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final stepTwo = _newPhone != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Change phone number')),
      body: FormPage(children: [
        Text('Current number: ${widget.controller.me?.phone ?? ''}', style: t.bodyLarge),
        const SizedBox(height: 16),
        ErrorBanner(_error),
        if (!stepTwo) ...[
          const Text('We will send a code to your current number and another to the new one.'),
          const SizedBox(height: 16),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'New phone number', hintText: '+201001234567'),
            onSubmitted: (_) => _request(),
          ),
          const SizedBox(height: 24),
          BusyButton(label: 'Send codes', busy: _busy, onPressed: _request),
        ] else ...[
          if (_devNote != null) DevCodeNote(_devNote!),
          CodeField(controller: _oldCode, label: 'Code sent to current number'),
          const SizedBox(height: 16),
          CodeField(controller: _newCode, label: 'Code sent to $_newPhone', onSubmitted: (_) => _confirm()),
          const SizedBox(height: 24),
          BusyButton(label: 'Confirm change', busy: _busy, onPressed: _confirm),
          TextButton(
            onPressed: _busy ? null : () => setState(() => _newPhone = null),
            child: const Text('Use a different number'),
          ),
        ],
      ]),
    );
  }
}
