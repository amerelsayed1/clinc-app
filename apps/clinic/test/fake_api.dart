import 'package:clinic_core/clinic_core.dart';

/// ApiClient double: routes "METHOD /path" to canned responses and records calls and bodies.
class FakeApi extends ApiClient {
  FakeApi(this.routes, {bool signedIn = true})
      : super(baseUrl: 'http://fake', tokenStore: MemoryTokenStore(signedIn ? const TokenPair('a', 'r') : null));

  final Map<String, Object? Function(Object? body)> routes;
  final List<String> calls = [];
  final Map<String, Object?> bodies = {};
  final Map<String, Map<String, String>?> queries = {};

  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, bool auth = true}) async {
    final key = '$method $path';
    calls.add(key);
    bodies[key] = body;
    queries[key] = query;
    final h = routes[key];
    if (h == null) throw ApiException(status: 404, code: 'not_found', message: 'No fake for $key');
    return h(body);
  }
}

Map<String, dynamic> membership(String role, List<String> permissions, {String name = 'Nile Clinic'}) =>
    {'id': 'm1', 'workspaceId': 'w1', 'workspaceName': name, 'role': role, 'permissions': permissions};

const doctorPerms = [
  'patients.read', 'patients.write', 'appointments.read', 'appointments.manage', 'vitals.write', 'documents.upload',
  'documents.upload_clinical', 'clinical.read', 'clinical.write', 'followups.write', 'relationships.manage', 'staff.manage', 'audit.read',
];
const receptionistPerms = ['patients.read', 'patients.write', 'appointments.read', 'appointments.manage', 'documents.upload'];

Map<String, dynamic> me({
  Map<String, dynamic>? member,
  bool mfaEnabled = true,
  bool mfaRequired = false,
  Map<String, dynamic>? doctorProfile,
}) =>
    {
      'id': 'u1',
      'phone': '+201000000001',
      'fullName': 'Dr Test',
      'isPlatformAdmin': false,
      'mfaEnabled': mfaEnabled,
      'mfaRequired': mfaRequired,
      'doctorProfile': doctorProfile,
      'memberships': member == null ? [] : [member],
    };
