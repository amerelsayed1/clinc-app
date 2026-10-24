import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../permissions.dart';
import '../../session.dart';

/// Profile, clinic/role, security (MFA, sessions, phone), app lock, notification preferences, sign out.
class AccountPage extends StatelessWidget {
  const AccountPage({super.key, required this.session});
  final ClinicSession session;

  AuthController get auth => session.auth;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final me = session.me;
          if (me == null) return const SizedBox.shrink();
          final lock = AppLockScope.maybeOf(context);
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: ListView(padding: const EdgeInsets.all(16), children: [
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.person)),
                    title: Text(me.hasName ? me.fullName! : me.phone),
                    subtitle: Text([
                      if (session.role != null) roleLabel(session.role!),
                      if (session.workspaceName != null) session.workspaceName!,
                      me.phone,
                    ].join(' · ')),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _EditNamePage(auth: auth))),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: const Text('Security'),
                    subtitle: Text(me.mfaEnabled ? 'Two-step verification is on' : 'Devices, phone number, two-step verification'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SecurityScreen(controller: auth))),
                  ),
                ),
                if (lock != null) ...[const SizedBox(height: 8), Card(child: AppLockTile(controller: lock))],
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.notifications_outlined),
                    title: Text(CareStrings.of(context).notifications),
                    subtitle: Text(CareStrings.of(context).notificationsSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NotificationPreferencesScreen(kit: session.kit))),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
                    title: const Text('Sign out'),
                    onTap: () async {
                      final ok = await confirmDialog(context, title: 'Sign out?', message: 'You will need a new code to sign in again.', confirmLabel: 'Sign out');
                      if (ok) {
                        await session.kit.push.unregister(); // stop pushes to this device before the session ends
                        await auth.signOut();
                      }
                    },
                  ),
                ),
              ]),
            ),
          );
        },
      );
}

class _EditNamePage extends StatelessWidget {
  const _EditNamePage({required this.auth});
  final AuthController auth;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Your name')),
        body: FormPage(children: [ProfileEditor(controller: auth, onSaved: () => Navigator.of(context).pop())]),
      );
}
