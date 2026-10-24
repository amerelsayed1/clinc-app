import 'dart:convert';

import 'package:clinic_core/clinic_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  const session = {
    'accessToken': 'a1',
    'refreshToken': 'r1',
    'user': {'id': 'u1', 'phone': '+201000000001', 'fullName': 'Test User'},
  };

  test('bootstrap without tokens -> signedOut', () async {
    final h = Harness((_) => jsonRes(500));
    final c = AuthController(h.api);
    expect(c.state, AuthState.loading);
    await c.bootstrap();
    expect(c.state, AuthState.signedOut);
    expect(h.log, isEmpty);
  });

  test('bootstrap with stored tokens loads /me -> signedIn', () async {
    final h = Harness((_) => jsonRes(200, meJson), tokens: const TokenPair('a', 'r'));
    final c = AuthController(h.api);
    await c.bootstrap();
    expect(c.state, AuthState.signedIn);
    expect(c.me!.fullName, 'Test User');
  });

  test('bootstrap with rejected tokens clears them -> signedOut', () async {
    final h = Harness((_) => jsonRes(401, {'error': 'unauthorized', 'message': 'x'}), tokens: const TokenPair('a', 'r'));
    final c = AuthController(h.api);
    await c.bootstrap();
    expect(c.state, AuthState.signedOut);
    expect(await h.store.read(), isNull);
  });

  test('bootstrap offline keeps tokens and reports the error', () async {
    final h2 = Harness((_) => jsonRes(503, {'error': 'x', 'message': 'down'}), tokens: const TokenPair('a', 'r'));
    final c2 = AuthController(h2.api);
    await c2.bootstrap();
    expect(c2.state, AuthState.signedOut);
    expect(c2.bootstrapError, 'down');
    expect(await h2.store.read(), isNotNull);
  });

  test('OTP login without MFA -> signedIn and stores tokens', () async {
    final h = Harness((req) {
      switch (req.url.path) {
        case '/auth/otp/request':
          return jsonRes(200, {'devCode': '123456'});
        case '/auth/otp/verify':
          final b = jsonDecode(req.body) as Map;
          expect(b['phone'], '+201000000001');
          expect(b['deviceName'], 'Phone');
          return jsonRes(200, session);
        case '/me':
          expect(req.headers['authorization'], 'Bearer a1');
          return jsonRes(200, meJson);
      }
      return jsonRes(404);
    });
    final c = AuthController(h.api, deviceName: 'Phone');
    await c.bootstrap();
    expect(await c.requestOtp('+201000000001'), '123456');
    await c.verifyOtp('+201000000001', '123456');
    expect(c.state, AuthState.signedIn);
    expect((await h.store.read())!.refresh, 'r1');
  });

  test('requestOtp returns null on 204', () async {
    final h = Harness((_) => jsonRes(204));
    expect(await AuthController(h.api).requestOtp('+201000000001'), isNull);
  });

  test('OTP -> needsMfa -> verifyMfa -> signedIn', () async {
    final h = Harness((req) {
      switch (req.url.path) {
        case '/auth/otp/verify':
          return jsonRes(200, {'mfaRequired': true, 'mfaToken': 'tok-123456789'});
        case '/auth/mfa/verify':
          final b = jsonDecode(req.body) as Map;
          expect(b['mfaToken'], 'tok-123456789');
          return b['recoveryCode'] == 'BAD' ? jsonRes(400, {'error': 'invalid_code', 'message': 'Invalid or expired code'}) : jsonRes(200, session);
        case '/me':
          return jsonRes(200, meJson);
      }
      return jsonRes(404);
    });
    final c = AuthController(h.api);
    await c.bootstrap();
    await c.verifyOtp('+201000000001', '123456');
    expect(c.state, AuthState.needsMfa);
    expect(h.api.hasSession, isFalse);
    await expectLater(c.verifyMfa(recoveryCode: 'BAD'), throwsA(isA<ApiException>()));
    expect(c.state, AuthState.needsMfa);
    await c.verifyMfa(code: '654321');
    expect(c.state, AuthState.signedIn);
  });

  test('cancelMfa returns to signedOut', () async {
    final h = Harness((_) => jsonRes(200, {'mfaRequired': true, 'mfaToken': 'tok-123456789'}));
    final c = AuthController(h.api);
    await c.bootstrap();
    await c.verifyOtp('+201000000001', '123456');
    expect(c.state, AuthState.needsMfa);
    c.cancelMfa();
    expect(c.state, AuthState.signedOut);
  });

  test('wrong OTP keeps signedOut and throws', () async {
    final h = Harness((_) => jsonRes(400, {'error': 'invalid_code', 'message': 'Invalid or expired code'}));
    final c = AuthController(h.api);
    await c.bootstrap();
    await expectLater(c.verifyOtp('+201000000001', '000000'), throwsA(isA<ApiException>()));
    expect(c.state, AuthState.signedOut);
  });

  test('signOut calls logout, clears tokens even if the call fails', () async {
    final h = Harness((req) => req.url.path == '/me' ? jsonRes(200, meJson) : jsonRes(500), tokens: const TokenPair('a', 'r'));
    final c = AuthController(h.api);
    await c.bootstrap();
    await c.signOut();
    expect(c.state, AuthState.signedOut);
    expect(c.me, isNull);
    expect(h.log, contains('POST /auth/logout'));
    expect(await h.store.read(), isNull);
  });

  test('refresh failure mid-session signs the controller out', () async {
    final h = Harness((req) {
      if (req.url.path == '/auth/refresh') return jsonRes(401, {'error': 'unauthorized', 'message': 'x'});
      if (req.url.path == '/me' && req.headers['authorization'] == 'Bearer a') {
        return h0.log.where((l) => l == 'GET /me').length > 1 ? jsonRes(401, {'error': 'unauthorized', 'message': 'x'}) : jsonRes(200, meJson);
      }
      return jsonRes(401, {'error': 'unauthorized', 'message': 'x'});
    }, tokens: const TokenPair('a', 'r'));
    h0 = h;
    final c = AuthController(h.api);
    await c.bootstrap();
    expect(c.state, AuthState.signedIn);
    await expectLater(c.reloadMe(), throwsA(isA<ApiException>()));
    expect(c.state, AuthState.signedOut);
  });

  test('activateMfa returns recovery codes without changing me until reloadMe', () async {
    var enabled = false;
    final h = Harness((req) {
      switch (req.url.path) {
        case '/auth/mfa/activate':
          enabled = true;
          return jsonRes(200, {'recoveryCodes': ['AAAA-BBBB', 'CCCC-DDDD']});
        case '/me':
          return jsonRes(200, {...meJson, 'mfaEnabled': enabled});
      }
      return jsonRes(404);
    }, tokens: const TokenPair('a', 'r'));
    final c = AuthController(h.api);
    await c.bootstrap();
    expect(await c.activateMfa('123456'), ['AAAA-BBBB', 'CCCC-DDDD']);
    expect(c.me!.mfaEnabled, isFalse);
    await c.reloadMe();
    expect(c.me!.mfaEnabled, isTrue);
  });
}

late Harness h0;
