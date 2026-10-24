import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import 'common.dart';

/// Step 1: enter the phone number in international format.
class PhoneLoginScreen extends StatefulWidget {
  const PhoneLoginScreen({
    super.key,
    required this.controller,
    required this.appName,
    this.tagline,
    required this.onCodeSent,
    this.notice,
  });

  final AuthController controller;
  final String appName;
  final String? tagline;
  final String? notice;
  final void Function(String phone, String? devCode) onCodeSent;

  @override
  State<PhoneLoginScreen> createState() => _PhoneLoginScreenState();
}

class _PhoneLoginScreenState extends State<PhoneLoginScreen> {
  final _phone = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final phone = _phone.text.replaceAll(RegExp(r'[\s-]'), '');
    if (!isValidPhone(phone)) {
      setState(() => _error = 'Enter your number in international format, e.g. +201001234567.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dev = await widget.controller.requestOtp(phone);
      if (mounted) widget.onCodeSent(phone, dev);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: FormPage(children: [
        const SizedBox(height: 48),
        Icon(Icons.health_and_safety, size: 48, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text(widget.appName, style: t.headlineMedium),
        if (widget.tagline != null) ...[const SizedBox(height: 8), Text(widget.tagline!, style: t.bodyLarge)],
        const SizedBox(height: 32),
        if (widget.notice != null) ErrorBanner(widget.notice),
        ErrorBanner(_error),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          autofillHints: const [AutofillHints.telephoneNumber],
          decoration: const InputDecoration(labelText: 'Phone number', hintText: '+201001234567', prefixIcon: Icon(Icons.phone)),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 8),
        Text("We'll text you a 6-digit verification code.", style: t.bodySmall),
        const SizedBox(height: 24),
        BusyButton(label: 'Send code', busy: _busy, onPressed: _submit),
      ]),
    );
  }
}

/// Step 2: enter the SMS code.
class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key, required this.controller, required this.phone, this.devCode, required this.onBack});

  final AuthController controller;
  final String phone;
  final String? devCode;
  final VoidCallback onBack;

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _devCode;

  @override
  void initState() {
    super.initState();
    _devCode = widget.devCode;
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_code.text.length != 6) {
      setState(() => _error = 'Enter the 6-digit code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.verifyOtp(widget.phone, _code.text);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    try {
      final dev = await widget.controller.requestOtp(widget.phone);
      if (!mounted) return;
      setState(() => _devCode = dev);
      showSnack(context, 'A new code was sent.');
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: widget.onBack)),
      body: FormPage(children: [
        Text('Enter your code', style: t.headlineSmall),
        const SizedBox(height: 8),
        Text('We sent a 6-digit code to ${widget.phone}.', style: t.bodyLarge),
        const SizedBox(height: 24),
        if (_devCode != null) DevCodeNote('Development code: $_devCode'),
        ErrorBanner(_error),
        CodeField(controller: _code, autofocus: true, onSubmitted: (_) => _verify()),
        const SizedBox(height: 24),
        BusyButton(label: 'Verify', busy: _busy, onPressed: _verify),
        const SizedBox(height: 8),
        TextButton(onPressed: _resend, child: const Text('Resend code')),
      ]),
    );
  }
}

/// Step 3 (only for accounts with MFA): authenticator code or a recovery code.
class MfaChallengeScreen extends StatefulWidget {
  const MfaChallengeScreen({super.key, required this.controller});
  final AuthController controller;

  @override
  State<MfaChallengeScreen> createState() => _MfaChallengeScreenState();
}

class _MfaChallengeScreenState extends State<MfaChallengeScreen> {
  final _code = TextEditingController();
  final _recovery = TextEditingController();
  bool _useRecovery = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _recovery.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final recovery = _recovery.text.trim();
    if (_useRecovery ? recovery.length < 8 : _code.text.length != 6) {
      setState(() => _error = _useRecovery ? 'Enter a recovery code.' : 'Enter the 6-digit code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.verifyMfa(code: _useRecovery ? null : _code.text, recoveryCode: _useRecovery ? recovery : null);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: widget.controller.cancelMfa)),
      body: FormPage(children: [
        Text('Two-step verification', style: t.headlineSmall),
        const SizedBox(height: 8),
        Text(
          _useRecovery
              ? 'Enter one of the recovery codes you saved when you turned on two-step verification. Each code works once.'
              : 'Open your authenticator app and enter the 6-digit code.',
          style: t.bodyLarge,
        ),
        const SizedBox(height: 24),
        ErrorBanner(_error),
        if (_useRecovery)
          TextField(
            controller: _recovery,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Recovery code'),
            onSubmitted: (_) => _verify(),
          )
        else
          CodeField(controller: _code, autofocus: true, label: 'Authenticator code', onSubmitted: (_) => _verify()),
        const SizedBox(height: 24),
        BusyButton(label: 'Verify', busy: _busy, onPressed: _verify),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => setState(() {
            _useRecovery = !_useRecovery;
            _error = null;
          }),
          child: Text(_useRecovery ? 'Use authenticator code' : 'Use a recovery code'),
        ),
      ]),
    );
  }
}
