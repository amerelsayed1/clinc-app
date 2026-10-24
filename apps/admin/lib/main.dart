import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/admin_repository.dart';
import 'src/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = ApiClient(tokenStore: SecureTokenStore(namespace: 'carelink.admin'));
  final auth = AuthController(api, deviceName: 'CareLink admin (${defaultTargetPlatform.name})');
  auth.bootstrap();
  runApp(AdminApp(auth: auth, repository: AdminRepository(api)));
}
