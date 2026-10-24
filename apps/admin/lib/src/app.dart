import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'admin_repository.dart';
import 'admin_root.dart';

class AdminApp extends StatefulWidget {
  const AdminApp({super.key, required this.auth, required this.repository, this.kit, this.lock});
  final AuthController auth;
  final AdminRepository repository;

  /// Notifications (spec 10); same shared screens as the patient app. Defaults to no push provider.
  final NotificationsKit? kit;

  /// Optional app lock (F11-8); defaults to secure storage plus the device's biometrics / passcode.
  final AppLockController? lock;

  @override
  State<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends State<AdminApp> {
  late final NotificationsKit _kit = widget.kit ?? NotificationsKit(widget.repository.api);
  late final AppLockController _lock = widget.lock ?? AppLockController(store: SecureLockSettingsStore(namespace: 'carelink.admin'));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _kit.locale,
        builder: (context, _) => MaterialApp(
          title: 'CareLink Admin',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(seed: const Color(0xFF3F51B5)),
          darkTheme: buildTheme(seed: const Color(0xFF3F51B5), brightness: Brightness.dark),
          // Audit logs are clinical: no screenshots, masked app switcher, optional app lock on every route.
          builder: secureAppBuilder(widget.auth, _lock),
          locale: _kit.locale.locale,
          supportedLocales: CareStrings.supportedLocales,
          localizationsDelegates: CareStrings.delegates,
          home: AuthGate(
            controller: widget.auth,
            appName: 'CareLink Admin',
            tagline: 'Platform administration.',
            signedInBuilder: (context, me) => AdminRoot(auth: widget.auth, repository: widget.repository, kit: _kit),
          ),
        ),
      );
}
