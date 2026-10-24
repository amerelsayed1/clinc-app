import 'package:clinic_core/clinic_core.dart';

/// ApiClient double: routes "METHOD /path" to canned responses and records calls.
class FakeApi extends ApiClient {
  FakeApi(this.routes, {bool signedIn = true})
      : super(baseUrl: 'http://fake', tokenStore: MemoryTokenStore(signedIn ? const TokenPair('a', 'r') : null));

  final Map<String, Object? Function(Object? body)> routes;
  final List<String> calls = [];

  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, bool auth = true}) async {
    final key = '$method $path';
    calls.add(key);
    final h = routes[key];
    if (h == null) throw ApiException(status: 404, code: 'not_found', message: 'No fake for $key');
    return h(body);
  }
}

Map<String, dynamic> me({String? fullName = 'Sara Ali'}) => {
      'id': 'u1',
      'phone': '+201000000001',
      'fullName': fullName,
      'isPlatformAdmin': false,
      'mfaEnabled': false,
      'mfaRequired': false,
      'doctorProfile': null,
      'memberships': [],
    };
