import 'package:flutter/material.dart';

import '../ui/common.dart';
import 'app_lock.dart';

/// Settings switch for the optional app lock (F11-8). Turning it on or off asks the user to authenticate first.
class AppLockTile extends StatelessWidget {
  const AppLockTile({super.key, required this.controller});
  final AppLockController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => SwitchListTile(
          secondary: const Icon(Icons.fingerprint),
          title: const Text('App lock'),
          subtitle: const Text('Ask for fingerprint, face or your device passcode when the app opens or returns from the background.'),
          value: controller.enabled,
          onChanged: (on) async {
            final ok = on ? await controller.enable() : await controller.disable();
            if (!ok && context.mounted) {
              showSnack(context, on ? 'App lock needs a screen lock or biometrics set up on this device.' : 'Could not confirm it is you.', error: true);
            }
          },
        ),
      );
}
