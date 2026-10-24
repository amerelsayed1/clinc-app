import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../auth/models.dart';
import 'change_phone_screen.dart';
import 'common.dart';
import 'mfa_enroll_screen.dart';

/// Account security: active sessions, two-step verification and phone number.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key, required this.controller});
  final AuthController controller;

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  List<SessionInfo>? _sessions;
  String? _error;
  bool _loading = true;

  AuthController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _sessions == null;
      _error = null;
    });
    try {
      final s = await c.sessions();
      if (mounted) setState(() => _sessions = s);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revoke(SessionInfo s) async {
    final ok = await confirmDialog(context,
        title: 'Sign out this device?', message: s.deviceName ?? 'Unknown device', confirmLabel: 'Sign out', destructive: true);
    if (!ok) return;
    try {
      await c.revokeSession(s.id);
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  Future<void> _revokeOthers() async {
    final ok = await confirmDialog(context,
        title: 'Sign out other devices?',
        message: 'Every device except this one will need to sign in again.',
        confirmLabel: 'Sign out others',
        destructive: true);
    if (!ok) return;
    try {
      final n = await c.revokeOtherSessions();
      if (mounted) showSnack(context, n == 1 ? '1 device signed out.' : '$n devices signed out.');
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  Future<void> _enableMfa() async {
    await Navigator.of(context).push(MaterialPageRoute<bool>(builder: (_) => MfaEnrollScreen(controller: c)));
  }

  Future<void> _disableMfa() async {
    final code = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Turn off two-step verification'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Enter the current 6-digit code from your authenticator app.'),
          const SizedBox(height: 12),
          CodeField(controller: code, label: 'Authenticator code', autofocus: true),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, code.text),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            child: const Text('Turn off'),
          ),
        ],
      ),
    );
    code.dispose();
    if (entered == null) return;
    if (entered.length != 6) {
      if (mounted) showSnack(context, 'Enter the 6-digit code.', error: true);
      return;
    }
    try {
      await c.disableMfa(entered);
      if (mounted) showSnack(context, 'Two-step verification is off.');
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  Future<void> _changePhone() async {
    await Navigator.of(context).push(MaterialPageRoute<bool>(builder: (_) => ChangePhoneScreen(controller: c)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final me = c.me;
          if (me == null) return const SizedBox.shrink();
          final t = Theme.of(context).textTheme;
          return RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Two-step verification', style: t.titleMedium),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: Icon(me.mfaEnabled ? Icons.verified_user : Icons.shield_outlined),
                    title: Text(me.mfaEnabled ? 'On' : 'Off'),
                    subtitle: Text(me.mfaRequired
                        ? 'Required for your account.'
                        : me.mfaEnabled
                            ? 'A code from your authenticator app is needed to sign in.'
                            : 'Add an authenticator app for extra protection.'),
                    trailing: me.mfaEnabled
                        ? (me.mfaRequired ? null : TextButton(onPressed: _disableMfa, child: const Text('Turn off')))
                        : TextButton(onPressed: _enableMfa, child: const Text('Turn on')),
                  ),
                ),
                const SizedBox(height: 24),
                Text('Phone number', style: t.titleMedium),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.phone),
                    title: Text(me.phone),
                    trailing: TextButton(onPressed: _changePhone, child: const Text('Change')),
                  ),
                ),
                const SizedBox(height: 24),
                Row(children: [
                  Expanded(child: Text('Signed-in devices', style: t.titleMedium)),
                  if ((_sessions?.length ?? 0) > 1) TextButton(onPressed: _revokeOthers, child: const Text('Sign out other devices')),
                ]),
                const SizedBox(height: 8),
                if (_loading)
                  const Padding(padding: EdgeInsets.all(24), child: LoadingView())
                else if (_error != null)
                  SizedBox(height: 160, child: ErrorView(message: _error!, onRetry: _load))
                else
                  for (final s in _sessions ?? const <SessionInfo>[])
                    Card(
                      child: ListTile(
                        leading: Icon(s.current ? Icons.smartphone : Icons.devices_other),
                        title: Text('${s.deviceName ?? 'Unknown device'}${s.current ? ' (this device)' : ''}'),
                        subtitle: Text([
                          if (s.ip != null) s.ip!,
                          if (s.lastUsedAt != null) 'Last active ${formatDateTime(s.lastUsedAt)}',
                        ].join(' - ')),
                        trailing: s.current
                            ? null
                            : IconButton(tooltip: 'Sign out this device', icon: const Icon(Icons.logout), onPressed: () => _revoke(s)),
                      ),
                    ),
              ],
            ),
          );
        },
      ),
    );
  }
}
