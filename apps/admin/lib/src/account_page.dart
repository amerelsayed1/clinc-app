import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

class AccountPage extends StatelessWidget {
  const AccountPage({super.key, required this.auth, required this.kit});
  final AuthController auth;
  final NotificationsKit kit;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: auth,
        builder: (context, _) {
          final me = auth.me;
          if (me == null) return const SizedBox.shrink();
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: ListView(padding: const EdgeInsets.all(16), children: [
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.admin_panel_settings)),
                    title: Text(me.fullName ?? 'Administrator'),
                    subtitle: Text(me.phone),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _EditNamePage(auth: auth))),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: const Text('Security'),
                    subtitle: const Text('Devices, phone number, two-step verification'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SecurityScreen(controller: auth))),
                  ),
                ),
                if (AppLockScope.maybeOf(context) != null) ...[
                  const SizedBox(height: 8),
                  Card(child: AppLockTile(controller: AppLockScope.maybeOf(context)!)),
                ],
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.notifications_outlined),
                    title: Text(CareStrings.of(context).notifications),
                    subtitle: Text(CareStrings.of(context).notificationsSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NotificationPreferencesScreen(kit: kit))),
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
                        await kit.push.unregister();
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
