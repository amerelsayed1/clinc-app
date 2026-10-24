import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Verifies the person holding the device (biometrics, falling back to the device passcode).
/// Behind an interface so tests and unsupported platforms do not need the plugin.
abstract class DeviceAuthenticator {
  /// True when the device has a screen lock or biometrics that can be used.
  Future<bool> isAvailable();

  /// Prompts the user. Returns false on cancel or failure; never throws.
  Future<bool> authenticate(String reason);
}

class LocalAuthDeviceAuthenticator implements DeviceAuthenticator {
  LocalAuthDeviceAuthenticator([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();
  final LocalAuthentication _auth;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      // biometricOnly stays false so a device passcode also works (people without enrolled biometrics are not locked out).
      return await _auth.authenticate(localizedReason: reason, persistAcrossBackgrounding: true);
    } catch (_) {
      return false;
    }
  }
}

/// Stores the single "lock enabled" flag. The flag is not a secret, but secure storage keeps it out of backups.
abstract class LockSettingsStore {
  Future<bool> readEnabled();
  Future<void> writeEnabled(bool enabled);
}

class MemoryLockSettingsStore implements LockSettingsStore {
  MemoryLockSettingsStore([this._enabled = false]);
  bool _enabled;
  @override
  Future<bool> readEnabled() async => _enabled;
  @override
  Future<void> writeEnabled(bool enabled) async => _enabled = enabled;
}

class SecureLockSettingsStore implements LockSettingsStore {
  SecureLockSettingsStore({FlutterSecureStorage? storage, this.namespace = 'carelink'}) : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  final String namespace;
  String get _key => '$namespace.app_lock';

  @override
  Future<bool> readEnabled() async {
    try {
      return await _storage.read(key: _key) == '1';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> writeEnabled(bool enabled) async {
    try {
      if (enabled) {
        await _storage.write(key: _key, value: '1');
      } else {
        await _storage.delete(key: _key);
      }
    } catch (_) {
      // Storage unavailable: the in-memory state still applies for this run.
    }
  }
}

/// Optional app lock (F11-8). When enabled the app locks as soon as it goes to the background (after [gracePeriod])
/// and on a cold start, and stays locked until the device owner authenticates.
class AppLockController extends ChangeNotifier {
  AppLockController({
    DeviceAuthenticator? authenticator,
    LockSettingsStore? store,
    this.gracePeriod = Duration.zero,
    DateTime Function()? clock,
  })  : _authenticator = authenticator ?? LocalAuthDeviceAuthenticator(),
        _store = store ?? SecureLockSettingsStore(),
        _now = clock ?? DateTime.now;

  final DeviceAuthenticator _authenticator;
  final LockSettingsStore _store;
  final DateTime Function() _now;

  /// How long the app may stay in the background before it locks. Zero = lock on every background.
  final Duration gracePeriod;

  bool _enabled = false;
  bool _locked = false;
  bool _loaded = false;
  bool _authenticating = false;
  DateTime? _backgroundedAt;

  bool get enabled => _enabled;
  bool get locked => _enabled && _locked;
  bool get loaded => _loaded;
  bool get authenticating => _authenticating;
  Future<bool> get available => _authenticator.isAvailable();

  /// Reads the saved setting; a cold start with the lock enabled begins locked.
  Future<void> load() async {
    _enabled = await _store.readEnabled();
    _locked = _enabled;
    _loaded = true;
    notifyListeners();
  }

  /// Turns the lock on after the user proves they can unlock (so they cannot lock themselves out).
  Future<bool> enable({String reason = 'Confirm to turn on app lock'}) async {
    if (!await _authenticator.isAvailable()) return false;
    if (!await _authenticator.authenticate(reason)) return false;
    _enabled = true;
    _locked = false;
    await _store.writeEnabled(true);
    notifyListeners();
    return true;
  }

  Future<bool> disable({String reason = 'Confirm to turn off app lock'}) async {
    if (_enabled && !await _authenticator.authenticate(reason)) return false;
    _enabled = false;
    _locked = false;
    await _store.writeEnabled(false);
    notifyListeners();
    return true;
  }

  Future<bool> unlock({String reason = 'Unlock CareLink'}) async {
    if (!locked || _authenticating) return !locked;
    _authenticating = true;
    notifyListeners();
    final ok = await _authenticator.authenticate(reason);
    _authenticating = false;
    if (ok) _locked = false;
    notifyListeners();
    return ok;
  }

  void lockNow() {
    if (!_enabled) return;
    _locked = true;
    notifyListeners();
  }

  /// Feed from [AppLifecycleState] changes.
  void onLifecycle(AppLifecycleState state) {
    if (!_enabled) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _backgroundedAt ??= _now();
        if (gracePeriod == Duration.zero) lockNow();
      case AppLifecycleState.resumed:
        final since = _backgroundedAt;
        _backgroundedAt = null;
        if (since != null && _now().difference(since) >= gracePeriod) lockNow();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break; // inactive also fires for system dialogs (e.g. the biometric prompt itself); never lock on it
    }
  }

  /// Signing out drops the lock state; the setting itself stays with the device.
  void onSignedOut() {
    if (!_locked && _backgroundedAt == null) return;
    _locked = false;
    _backgroundedAt = null;
    notifyListeners();
  }
}

/// Covers its child with a lock screen while [controller] is locked. The child stays mounted (state survives)
/// but is not painted, hit-testable or exposed to accessibility services while locked.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.controller, required this.child, this.active = true});
  final AppLockController controller;
  final Widget child;

  /// False while nobody is signed in: the login screens are never locked.
  final bool active;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
    if (!widget.controller.loaded) widget.controller.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.active) widget.controller.onLifecycle(state);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final locked = widget.active && c.locked;
    // Until the saved setting is read (milliseconds; the session itself takes a network round trip to load) nothing is locked.
    return Stack(children: [
      Positioned.fill(
        child: Visibility(visible: !locked, maintainState: true, maintainAnimation: false, child: widget.child),
      ),
      if (locked) Positioned.fill(child: LockScreen(controller: c)),
    ]);
  }
}

class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.controller});
  final AppLockController controller;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  @override
  void initState() {
    super.initState();
    // Prompt straight away; the button remains for retries after a cancel.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.unlock();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_outline, size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('CareLink is locked', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('Confirm it is you to continue.', textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: widget.controller.authenticating ? null : widget.controller.unlock,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Unlock'),
              ),
            ]),
          ),
        ),
      );
}
