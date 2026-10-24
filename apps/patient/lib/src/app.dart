import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'patient_repository.dart';
import 'patient_root.dart';

class PatientApp extends StatefulWidget {
  const PatientApp({super.key, required this.auth, required this.repository, this.kit, this.lock});
  final AuthController auth;
  final PatientRepository repository;

  /// Notifications (spec 10). Defaults to a kit with no push provider; pass one with a real
  /// [PushRegistrar] (FCM/APNs) from main.dart to enable device push.
  final NotificationsKit? kit;

  /// Optional app lock (F11-8). Defaults to one backed by secure storage and the device's biometrics / passcode.
  final AppLockController? lock;

  @override
  State<PatientApp> createState() => _PatientAppState();
}

class _PatientAppState extends State<PatientApp> {
  late final NotificationsKit _kit = widget.kit ?? NotificationsKit(widget.repository.api);
  late final AppLockController _lock = widget.lock ?? AppLockController(store: SecureLockSettingsStore(namespace: 'carelink.patient'));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _kit.locale,
        builder: (context, _) => MaterialApp(
          title: 'CareLink',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          darkTheme: buildTheme(brightness: Brightness.dark),
          // Language is switchable at runtime (Notification settings); Arabic flips the layout to RTL.
          // Everything after sign-in is clinical: no screenshots, masked app switcher, optional app lock - on every route.
          builder: secureAppBuilder(widget.auth, _lock),
          locale: _kit.locale.locale,
          supportedLocales: CareStrings.supportedLocales,
          localizationsDelegates: CareStrings.delegates,
          home: AuthGate(
            controller: widget.auth,
            appName: 'CareLink',
            tagline: 'Your care team, in one place.',
            signedInBuilder: (context, me) => PatientRoot(auth: widget.auth, repository: widget.repository, kit: _kit),
          ),
        ),
      );
}
