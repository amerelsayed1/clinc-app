import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'clinic_repository.dart';
import 'clinic_root.dart';
import 'feature.dart';
import 'features.dart';
import 'session.dart';

class ClinicApp extends StatefulWidget {
  const ClinicApp({super.key, required this.auth, required this.repository, this.kit, this.lock, this.registry});
  final AuthController auth;
  final ClinicRepository repository;

  /// Notifications (spec 10). Defaults to a kit with no push provider; pass one with a real
  /// [PushRegistrar] (FCM/APNs) from main.dart to enable device push.
  final NotificationsKit? kit;

  /// Optional app lock (F11-8). Defaults to secure storage plus the device's biometrics / passcode.
  final AppLockController? lock;

  /// Screens to show; defaults to [buildFeatureRegistry] (tests may inject their own).
  final FeatureRegistry? registry;

  @override
  State<ClinicApp> createState() => _ClinicAppState();
}

class _ClinicAppState extends State<ClinicApp> {
  late final NotificationsKit _kit = widget.kit ?? NotificationsKit(widget.repository.api);
  late final AppLockController _lock = widget.lock ?? AppLockController(store: SecureLockSettingsStore(namespace: 'carelink.clinic'));
  late final ClinicSession _session = ClinicSession(auth: widget.auth, repository: widget.repository, kit: _kit);
  late final FeatureRegistry _registry = widget.registry ?? buildFeatureRegistry();

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _kit.locale,
        builder: (context, _) => MaterialApp(
          title: 'CareLink Clinic',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          darkTheme: buildTheme(brightness: Brightness.dark),
          // Everything after sign-in is clinical: no screenshots, masked app switcher, optional app lock.
          builder: secureAppBuilder(widget.auth, _lock),
          locale: _kit.locale.locale,
          supportedLocales: CareStrings.supportedLocales,
          localizationsDelegates: CareStrings.delegates,
          home: AuthGate(
            controller: widget.auth,
            appName: 'CareLink Clinic',
            tagline: 'Your clinic, in your pocket.',
            signedInBuilder: (context, me) => ClinicRoot(session: _session, registry: _registry),
          ),
        ),
      );
}
