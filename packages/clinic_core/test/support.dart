import 'dart:convert';

import 'package:clinic_core/clinic_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

typedef Handler = http.Response Function(http.Request req);

http.Response jsonRes(int status, [Object? body]) =>
    http.Response(body == null ? '' : jsonEncode(body), status, headers: {'content-type': 'application/json'});

class Harness {
  Harness(Handler handler, {TokenPair? tokens}) : store = MemoryTokenStore(tokens) {
    client = MockClient((req) async {
      log.add('${req.method} ${req.url.path}');
      return handler(req);
    });
    api = ApiClient(baseUrl: 'http://test', httpClient: client, tokenStore: store);
  }
  final MemoryTokenStore store;
  final List<String> log = [];
  late final MockClient client;
  late final ApiClient api;
}

const meJson = {
  'id': 'u1',
  'phone': '+201000000001',
  'fullName': 'Test User',
  'isPlatformAdmin': false,
  'mfaEnabled': false,
  'mfaRequired': false,
  'doctorProfile': null,
  'memberships': [],
};
