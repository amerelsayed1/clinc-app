import 'dart:async';

import 'repository.dart';

class PushToken {
  const PushToken(this.token, this.platform);
  final String token;
  final String platform; // android | ios | web
}

/// Platform push boundary. The default [NoopPushRegistrar] never produces a token, so the apps run
/// (and notifications still arrive in the inbox) without any push provider.
///
/// To plug in FCM/APNs, implement this interface in the app (not here, to keep this package free of
/// Firebase) and pass it to `NotificationsKit(api, registrar: MyFcmRegistrar())`:
///
/// ```dart
/// class FcmRegistrar implements PushRegistrar {
///   @override
///   Future<PushToken?> requestToken() async {
///     final settings = await FirebaseMessaging.instance.requestPermission();
///     if (settings.authorizationStatus == AuthorizationStatus.denied) return null;
///     final t = await FirebaseMessaging.instance.getToken();
///     return t == null ? null : PushToken(t, Platform.isIOS ? 'ios' : 'android');
///   }
///   @override
///   Stream<String> get onTokenRefresh => FirebaseMessaging.instance.onTokenRefresh;
///   @override
///   Future<void> deleteToken() => FirebaseMessaging.instance.deleteToken();
/// }
/// ```
/// The server only ever sends the generic message plus an opaque `nid`; on tap, open the inbox.
abstract class PushRegistrar {
  /// Asks the OS for permission (if needed) and returns the device token, or null if unavailable/denied.
  Future<PushToken?> requestToken();
  Stream<String> get onTokenRefresh;
  Future<void> deleteToken();
}

class NoopPushRegistrar implements PushRegistrar {
  const NoopPushRegistrar();
  @override
  Future<PushToken?> requestToken() async => null;
  @override
  Stream<String> get onTokenRefresh => const Stream.empty();
  @override
  Future<void> deleteToken() async {}
}

/// Keeps the server's device-token list in step with the OS token. Never asks the OS for permission
/// before the user has consented in [NotificationConsentPrompt] (F10-5).
class PushRegistration {
  PushRegistration(this._repo, [PushRegistrar? registrar]) : _registrar = registrar ?? const NoopPushRegistrar();
  final NotificationsRepository _repo;
  final PushRegistrar _registrar;
  String? _registered;
  String _platform = 'android';
  StreamSubscription<String>? _refresh;

  String? get registeredToken => _registered;

  /// Registers the current token when the user has consented to push. Failures are swallowed: push is best effort.
  Future<void> sync({required bool pushConsented}) async {
    if (!pushConsented) return;
    try {
      final t = await _registrar.requestToken();
      if (t == null) return;
      _platform = t.platform;
      await _register(t.token);
      _refresh ??= _registrar.onTokenRefresh.listen((tok) => _register(tok).catchError((Object _) {}));
    } catch (_) {}
  }

  Future<void> _register(String token) async {
    if (token == _registered) return;
    await _repo.registerDevice(token, _platform);
    _registered = token;
  }

  /// Call before sign-out so this device stops receiving the previous user's notices.
  Future<void> unregister() async {
    final t = _registered;
    await _refresh?.cancel();
    _refresh = null;
    _registered = null;
    try {
      if (t != null) await _repo.unregisterDevice(t);
      await _registrar.deleteToken();
    } catch (_) {}
  }
}
