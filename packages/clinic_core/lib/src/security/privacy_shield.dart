import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_controller.dart';
import 'app_lock.dart';

/// Android FLAG_SECURE (blocks screenshots, screen recording and the recent-apps thumbnail) through a tiny platform
/// channel implemented in each Android runner (`MainActivity`). Reference counted so nested screens do not fight.
/// Platforms without the channel (iOS, tests, web) are a no-op; iOS relies on [PrivacyShield] for the app switcher.
class SecureScreen {
  SecureScreen._();
  static const channel = MethodChannel('carelink/secure_screen');
  static int _holders = 0;

  /// Visible for tests.
  static int get holders => _holders;

  static Future<void> acquire() async {
    if (_holders++ == 0) await _set(true);
  }

  static Future<void> release() async {
    if (_holders > 0 && --_holders == 0) await _set(false);
  }

  static Future<void> _set(bool secure) async {
    try {
      await channel.invokeMethod<void>('setSecure', {'secure': secure});
    } on MissingPluginException {
      // not an Android runner
    } on PlatformException {
      // best effort
    }
  }
}

/// Hides everything under it from screenshots / screen recording for as long as it is mounted.
class SecureScreenScope extends StatefulWidget {
  const SecureScreenScope({super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;

  @override
  State<SecureScreenScope> createState() => _SecureScreenScopeState();
}

class _SecureScreenScopeState extends State<SecureScreenScope> {
  bool _held = false;

  void _sync() {
    if (widget.enabled && !_held) {
      _held = true;
      SecureScreen.acquire();
    } else if (!widget.enabled && _held) {
      _held = false;
      SecureScreen.release();
    }
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(SecureScreenScope old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    if (_held) SecureScreen.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Replaces the app's contents with an opaque, blurred cover whenever the app is not in the foreground, so the
/// task-switcher snapshot on iOS and Android never contains clinical data.
class PrivacyShield extends StatefulWidget {
  const PrivacyShield({super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;

  @override
  State<PrivacyShield> createState() => _PrivacyShieldState();
}

class _PrivacyShieldState extends State<PrivacyShield> with WidgetsBindingObserver {
  bool _covered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final covered = state != AppLifecycleState.resumed;
    if (covered != _covered) setState(() => _covered = covered);
  }

  @override
  Widget build(BuildContext context) => Stack(textDirection: TextDirection.ltr, children: [
        Positioned.fill(child: widget.child),
        if (_covered && widget.enabled)
          Positioned.fill(
            child: ExcludeSemantics(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: ColoredBox(
                  key: const ValueKey('privacy-cover'),
                  color: Theme.of(context).colorScheme.surface,
                  child: Center(child: Icon(Icons.lock_outline, size: 64, color: Theme.of(context).colorScheme.primary)),
                ),
              ),
            ),
          ),
      ]);
}

/// Gives settings screens access to the app lock without threading it through every constructor.
class AppLockScope extends InheritedWidget {
  const AppLockScope({super.key, required this.controller, required super.child});
  final AppLockController controller;

  static AppLockController? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppLockScope>()?.controller;

  @override
  bool updateShouldNotify(AppLockScope old) => old.controller != controller;
}

/// Everything a signed-in clinical app needs in one wrapper: optional app lock, app-switcher masking and
/// screenshot blocking. [active] is false while nobody is signed in (login screens are not clinical).
/// The widget tree has the same shape either way, so toggling [active] never rebuilds the navigator below.
class SecureShell extends StatelessWidget {
  const SecureShell({super.key, required this.lock, required this.child, this.active = true});
  final AppLockController lock;
  final Widget child;
  final bool active;

  @override
  Widget build(BuildContext context) => AppLockScope(
        controller: lock,
        child: PrivacyShield(enabled: active, child: SecureScreenScope(enabled: active, child: AppLockGate(controller: lock, active: active, child: child))),
      );
}

/// `MaterialApp.builder` that secures every route (including pushed ones) once a user is signed in.
TransitionBuilder secureAppBuilder(AuthController auth, AppLockController lock) => (context, child) => ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        final signedIn = auth.state == AuthState.signedIn;
        if (auth.state == AuthState.signedOut) lock.onSignedOut();
        return SecureShell(lock: lock, active: signedIn, child: child ?? const SizedBox.shrink());
      },
    );
