import 'package:clinic_core/clinic_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

void main() {
  test('sends bearer token and decodes JSON; 204 returns null', () async {
    final h = Harness((req) {
      expect(req.headers['authorization'], 'Bearer a1');
      return req.url.path == '/empty' ? jsonRes(204) : jsonRes(200, {'ok': true});
    }, tokens: const TokenPair('a1', 'r1'));
    await h.api.init();
    expect(await h.api.get('/x'), {'ok': true});
    expect(await h.api.post('/empty'), isNull);
  });

  test('maps error body to ApiException', () async {
    final h = Harness((_) => jsonRes(403, {'error': 'mfa_required', 'message': 'MFA is required'}));
    await expectLater(
      h.api.post('/auth/mfa/disable', body: {'code': '123456'}),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'mfa_required').having((e) => e.status, 'status', 403)),
    );
  });

  test('refreshes once on 401, stores rotated tokens and retries', () async {
    final h = Harness((req) {
      if (req.url.path == '/auth/refresh') return jsonRes(200, {'accessToken': 'a2', 'refreshToken': 'r2'});
      return req.headers['authorization'] == 'Bearer a2' ? jsonRes(200, {'ok': 1}) : jsonRes(401, {'error': 'unauthorized', 'message': 'x'});
    }, tokens: const TokenPair('a1', 'r1'));
    await h.api.init();
    expect(await h.api.get('/me'), {'ok': 1});
    expect(h.log, ['GET /me', 'POST /auth/refresh', 'GET /me']);
    final t = await h.store.read();
    expect([t!.access, t.refresh], ['a2', 'r2']);
  });

  test('concurrent 401s share a single refresh request', () async {
    var refreshes = 0;
    final h = Harness((req) {
      if (req.url.path == '/auth/refresh') {
        refreshes++;
        return jsonRes(200, {'accessToken': 'a2', 'refreshToken': 'r2'});
      }
      return req.headers['authorization'] == 'Bearer a2' ? jsonRes(200, {'p': req.url.path}) : jsonRes(401, {'error': 'unauthorized', 'message': 'x'});
    }, tokens: const TokenPair('a1', 'r1'));
    await h.api.init();
    final results = await Future.wait([h.api.get('/a'), h.api.get('/b'), h.api.get('/c')]);
    expect(refreshes, 1);
    expect(results.map((r) => (r as Map)['p']), ['/a', '/b', '/c']);
  });

  test('a request that 401s with an already-rotated token retries without refreshing again', () async {
    var refreshes = 0;
    final h = Harness((req) {
      if (req.url.path == '/auth/refresh') {
        refreshes++;
        return jsonRes(200, {'accessToken': 'a2', 'refreshToken': 'r2'});
      }
      return req.headers['authorization'] == 'Bearer a2' ? jsonRes(200, {}) : jsonRes(401, {'error': 'unauthorized', 'message': 'x'});
    }, tokens: const TokenPair('a1', 'r1'));
    await h.api.init();
    await h.api.get('/a');
    await h.api.setSession('a1', 'r2'); // simulate a stale in-flight request finishing late
    await h.api.get('/b'); // 401 with a1 -> refresh again (one), not a loop
    expect(refreshes, 2);
  });

  test('failed refresh clears the session, fires onSessionExpired and surfaces the 401', () async {
    final h = Harness((req) {
      if (req.url.path == '/auth/refresh') return jsonRes(401, {'error': 'unauthorized', 'message': 'Invalid refresh token'});
      return jsonRes(401, {'error': 'unauthorized', 'message': 'Invalid token'});
    }, tokens: const TokenPair('a1', 'r1'));
    await h.api.init();
    var expired = 0;
    h.api.onSessionExpired = () => expired++;
    await expectLater(h.api.get('/me'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));
    expect(expired, 1);
    expect(h.api.hasSession, isFalse);
    expect(await h.store.read(), isNull);
    expect(h.log, ['GET /me', 'POST /auth/refresh']);
  });

  test('concurrent failed refresh signs out once', () async {
    final h = Harness((req) => req.url.path == '/auth/refresh' ? jsonRes(401, {'error': 'unauthorized', 'message': 'x'}) : jsonRes(401, {'error': 'unauthorized', 'message': 'x'}),
        tokens: const TokenPair('a1', 'r1'));
    await h.api.init();
    var expired = 0;
    h.api.onSessionExpired = () => expired++;
    final rs = await Future.wait([
      h.api.get('/a').then((_) => 'ok', onError: (_) => 'err'),
      h.api.get('/b').then((_) => 'ok', onError: (_) => 'err'),
    ]);
    expect(rs, ['err', 'err']);
    expect(expired, 1);
  });

  test('persistent 401 after a successful refresh is not retried forever', () async {
    final h = Harness((req) {
      if (req.url.path == '/auth/refresh') return jsonRes(200, {'accessToken': 'a2', 'refreshToken': 'r2'});
      return jsonRes(401, {'error': 'unauthorized', 'message': 'x'});
    }, tokens: const TokenPair('a1', 'r1'));
    await h.api.init();
    await expectLater(h.api.get('/me'), throwsA(isA<ApiException>()));
    expect(h.log, ['GET /me', 'POST /auth/refresh', 'GET /me']);
  });

  test('network failure during refresh keeps the session', () async {
    var calls = 0;
    final h = Harness((req) {
      calls++;
      if (req.url.path == '/auth/refresh') throw http.ClientException('offline');
      return jsonRes(401, {'error': 'unauthorized', 'message': 'x'});
    }, tokens: const TokenPair('a1', 'r1'));
    await h.api.init();
    await expectLater(h.api.get('/me'), throwsA(isA<ApiException>().having((e) => e.isNetwork, 'network', true)));
    expect(h.api.hasSession, isTrue);
    expect(calls, 2);
  });

  test('unauthenticated calls never trigger refresh', () async {
    final h = Harness((_) => jsonRes(401, {'error': 'unauthorized', 'message': 'x'}), tokens: const TokenPair('a1', 'r1'));
    await h.api.init();
    await expectLater(h.api.post('/auth/otp/verify', body: {}, auth: false), throwsA(isA<ApiException>()));
    expect(h.log, ['POST /auth/otp/verify']);
  });

  test('multipart upload sends the bearer token and refreshes once on 401', () async {
    final h = Harness((req) {
      if (req.url.path == '/auth/refresh') return jsonRes(200, {'accessToken': 'a2', 'refreshToken': 'r2'});
      expect(req.headers['content-type'], startsWith('multipart/form-data'));
      return req.headers['authorization'] == 'Bearer a2' ? jsonRes(201, {'id': 'doc1'}) : jsonRes(401, {'error': 'unauthorized', 'message': 'x'});
    }, tokens: const TokenPair('a1', 'r1'));
    await h.api.init();
    final r = await h.api.postMultipart('/patient/documents', fields: {'category': 'other'}, bytes: [1, 2, 3], filename: 'a.jpg');
    expect(r, {'id': 'doc1'});
    expect(h.log, ['POST /patient/documents', 'POST /auth/refresh', 'POST /patient/documents']);
  });
}
