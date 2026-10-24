import 'package:carelink_clinic/src/clinic_repository.dart';
import 'package:carelink_clinic/src/session.dart';
import 'package:clinic_core/clinic_core.dart';

import 'fake_api.dart';

/// FakeApi that also records every query and multipart upload.
class RecordingApi extends FakeApi {
  RecordingApi(super.routes);
  final List<Map<String, String>?> allQueries = [];
  final List<({String path, Map<String, String> fields, List<String> files})> uploads = [];
  Object? uploadResponse;

  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, bool auth = true}) {
    allQueries.add(query);
    return super.request(method, path, body: body, query: query, auth: auth);
  }

  @override
  Future<dynamic> postMultipartFiles(String path, {Map<String, String> fields = const {}, required List<({String filename, List<int> bytes})> files, String fileField = 'file'}) async {
    calls.add('POST $path');
    uploads.add((path: path, fields: fields, files: [for (final f in files) f.filename]));
    return uploadResponse;
  }
}

Future<ClinicSession> sessionFor(FakeApi api, String role, List<String> perms) async {
  final auth = AuthController(api);
  api.routes['GET /me'] = (_) => me(member: membership(role, perms));
  await auth.bootstrap();
  return ClinicSession(auth: auth, repository: ClinicRepository(api), kit: NotificationsKit(api));
}
