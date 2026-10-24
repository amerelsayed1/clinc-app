import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/patient_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = ApiClient(tokenStore: SecureTokenStore(namespace: 'carelink.patient'));
  final auth = AuthController(api, deviceName: 'CareLink patient (${defaultTargetPlatform.name})');
  auth.bootstrap();
  runApp(PatientApp(auth: auth, repository: PatientRepository(api)));
}
