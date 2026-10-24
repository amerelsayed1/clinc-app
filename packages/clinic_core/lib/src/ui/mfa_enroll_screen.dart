import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../auth/models.dart';
import 'common.dart';

/// Authenticator-app enrolment: shows the secret, verifies a code, then shows recovery codes once.
/// With [forced] the screen cannot be dismissed (admins/doctors must enrol) and offers sign-out.
class MfaEnrollScreen extends StatefulWidget {
  const MfaEnrollScreen({super.key, required this.controller, this.forced = false});
  final AuthController controller;
  final bool forced;

  @override
  State<MfaEnrollScreen> createState() => _MfaEnrollScreenState();
}

class _MfaEnrollScreenState extends State<MfaEnrollScreen> {
  final _code = TextEditingController();
  MfaEnrollment? _enrollment;
  List<String>? _recoveryCodes;
  bool _loading = true;
  bool _busy = false;
  bool _saved = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final e = await widget.controller.enrollMfa();
      if (mounted) setState(() => _enrollment = e);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _activate() async {
    if (_code.text.length != 6) {
      setState(() => _error = 'Enter the 6-digit code from your authenticator app.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final codes = await widget.controller.activateMfa(_code.text);
      if (mounted) setState(() => _recoveryCodes = codes);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    try {
      await widget.controller.reloadMe(); // in forced mode this swaps this screen for the app
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (Navigator.of(context).canPop()) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return PopScope(
      canPop: !widget.forced && _recoveryCodes == null,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Two-step verification'),
          automaticallyImplyLeading: !widget.forced && _recoveryCodes == null,
          actions: [
            if (widget.forced && _recoveryCodes == null)
              TextButton(onPressed: widget.controller.signOut, child: const Text('Sign out')),
          ],
        ),
        body: _loading
            ? const LoadingView()
            : _recoveryCodes != null
                ? _recovery(t)
                : _enrollment == null
                    ? ErrorView(message: _error ?? 'Could not start enrolment.', onRetry: _start)
                    : _setup(t),
      ),
    );
  }

  Widget _setup(TextTheme t) {
    final e = _enrollment!;
    return FormPage(children: [
      if (widget.forced) const DevCodeNote('Two-step verification is required for your account. Set it up to continue.'),
      Text('1. Add the account to your authenticator app', style: t.titleMedium),
      const SizedBox(height: 8),
      const Text('In an authenticator app (Google Authenticator, Authy, 1Password...), add an account by entering this key manually.'),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SelectableText(e.secret, style: const TextStyle(fontFamily: 'monospace', fontSize: 18, letterSpacing: 2)),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [
        OutlinedButton.icon(
          onPressed: () => copyToClipboard(context, e.secret, label: 'Key copied'),
          icon: const Icon(Icons.copy),
          label: const Text('Copy key'),
        ),
        OutlinedButton.icon(
          onPressed: () => copyToClipboard(context, e.otpauthUrl, label: 'Setup link copied'),
          icon: const Icon(Icons.link),
          label: const Text('Copy setup link'),
        ),
      ]),
      const SizedBox(height: 24),
      Text('2. Enter the 6-digit code', style: t.titleMedium),
      const SizedBox(height: 12),
      ErrorBanner(_error),
      CodeField(controller: _code, label: 'Authenticator code', onSubmitted: (_) => _activate()),
      const SizedBox(height: 24),
      BusyButton(label: 'Turn on', busy: _busy, onPressed: _activate),
    ]);
  }

  Widget _recovery(TextTheme t) {
    final codes = _recoveryCodes!;
    return FormPage(children: [
      Text('Save your recovery codes', style: t.titleLarge),
      const SizedBox(height: 8),
      const Text(
          'If you lose access to your authenticator app, each of these codes lets you sign in once. They are shown only now - store them somewhere safe.'),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final c in codes) SelectableText(c, style: const TextStyle(fontFamily: 'monospace', fontSize: 18, height: 1.6))],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => copyToClipboard(context, codes.join('\n'), label: 'Recovery codes copied'),
          icon: const Icon(Icons.copy),
          label: const Text('Copy all'),
        ),
      ),
      const SizedBox(height: 16),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _saved,
        onChanged: (v) => setState(() => _saved = v ?? false),
        title: const Text('I saved these codes'),
      ),
      const SizedBox(height: 8),
      ErrorBanner(_error),
      BusyButton(label: 'Done', busy: _busy, onPressed: _saved ? _finish : null),
    ]);
  }
}
