import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/clinic_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = ApiClient(tokenStore: SecureTokenStore(namespace: 'carelink.clinic'));
  final auth = AuthController(api, deviceName: 'CareLink clinic (${defaultTargetPlatform.name})');
  auth.bootstrap();
  runApp(ClinicApp(auth: auth, repository: ClinicRepository(api)));
}
