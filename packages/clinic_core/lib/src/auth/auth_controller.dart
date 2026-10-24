import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import 'models.dart';

enum AuthState { loading, signedOut, needsMfa, signedIn }

/// Owns the authentication state machine and wraps the auth/session/MFA endpoints.
class AuthController extends ChangeNotifier {
  AuthController(this.api, {this.deviceName}) {
    api.onSessionExpired = _handleExpired;
  }

  final ApiClient api;
  final String? deviceName;

  AuthState _state = AuthState.loading;
  Me? _me;
  String? _mfaToken;
  String? _bootstrapError;

  AuthState get state => _state;
  Me? get me => _me;

  /// Set when startup could not reach the server although a stored session exists.
  String? get bootstrapError => _bootstrapError;

  void _set(AuthState s) {
    _state = s;
    notifyListeners();
  }

  void _handleExpired() {
    _me = null;
    _mfaToken = null;
    _set(AuthState.signedOut);
  }

  /// Restores a stored session, if any.
  Future<void> bootstrap() async {
    _bootstrapError = null;
    _set(AuthState.loading);
    await api.init();
    if (!api.hasSession) return _set(AuthState.signedOut);
    try {
      await _loadMe();
      _set(AuthState.signedIn);
    } on ApiException catch (e) {
      if (e.isNetwork || e.status >= 500) {
        _bootstrapError = e.message; // keep tokens; user can retry
      } else {
        await api.clearSession();
      }
      _set(AuthState.signedOut);
    }
  }

  Future<void> _loadMe() async {
    _me = Me.fromJson(await api.get('/me') as Map<String, dynamic>);
  }

  Future<void> reloadMe() async {
    await _loadMe();
    notifyListeners();
  }

  /// Sends the OTP. Returns the dev code when the server echoes it.
  Future<String?> requestOtp(String phone) async {
    final res = await api.post('/auth/otp/request', body: {'phone': phone}, auth: false);
    return res is Map<String, dynamic> ? res['devCode'] as String? : null;
  }

  Future<void> verifyOtp(String phone, String code) async {
    final res = await api.post('/auth/otp/verify',
        body: {'phone': phone, 'code': code, if (deviceName != null) 'deviceName': deviceName}, auth: false) as Map<String, dynamic>;
    await _acceptLogin(res);
  }

  Future<void> verifyMfa({String? code, String? recoveryCode}) async {
    final token = _mfaToken;
    if (token == null) throw ApiException(status: 400, code: 'invalid_code', message: 'Sign in again.');
    final res = await api.post('/auth/mfa/verify',
        body: {'mfaToken': token, 'code': ?code, 'recoveryCode': ?recoveryCode},
        auth: false) as Map<String, dynamic>;
    await _acceptLogin(res);
  }

  Future<void> _acceptLogin(Map<String, dynamic> res) async {
    if (res['mfaRequired'] == true) {
      _mfaToken = res['mfaToken'] as String;
      return _set(AuthState.needsMfa);
    }
    await api.setSession(res['accessToken'] as String, res['refreshToken'] as String);
    _mfaToken = null;
    try {
      await _loadMe();
    } catch (_) {
      await api.clearSession();
      rethrow;
    }
    _set(AuthState.signedIn);
  }

  /// Abandons a pending MFA challenge and returns to the phone screen.
  void cancelMfa() {
    _mfaToken = null;
    _set(AuthState.signedOut);
  }

  Future<void> updateName(String fullName) async {
    await api.patch('/me', body: {'fullName': fullName.trim()});
    await reloadMe();
  }

  Future<void> signOut() async {
    try {
      if (api.hasSession) await api.post('/auth/logout');
    } catch (_) {
      // Best effort: the local session is discarded either way.
    }
    await api.clearSession();
    _me = null;
    _mfaToken = null;
    _bootstrapError = null;
    _set(AuthState.signedOut);
  }

  // ---- Sessions ----
  Future<List<SessionInfo>> sessions() async =>
      (await api.get('/sessions') as List).cast<Map<String, dynamic>>().map(SessionInfo.fromJson).toList();

  Future<void> revokeSession(String id) => api.delete('/sessions/$id');

  Future<int> revokeOtherSessions() async {
    final res = await api.post('/sessions/revoke-others') as Map<String, dynamic>;
    return (res['revoked'] as num?)?.toInt() ?? 0;
  }

  // ---- MFA ----
  Future<MfaEnrollment> enrollMfa() async =>
      MfaEnrollment.fromJson(await api.post('/auth/mfa/enroll') as Map<String, dynamic>);

  /// Activates MFA; the returned recovery codes are shown only once. Does not reload [me]
  /// so the UI can display the codes first; call [reloadMe] afterwards.
  Future<List<String>> activateMfa(String code) async {
    final res = await api.post('/auth/mfa/activate', body: {'code': code}) as Map<String, dynamic>;
    return (res['recoveryCodes'] as List).cast<String>();
  }

  Future<void> disableMfa(String code) async {
    await api.post('/auth/mfa/disable', body: {'code': code});
    await reloadMe();
  }

  // ---- Phone change ----
  /// Returns dev codes `(old, new)` when the server echoes them, else nulls.
  Future<({String? oldCode, String? newCode})> requestPhoneChange(String newPhone) async {
    final res = await api.post('/auth/phone-change/request', body: {'newPhone': newPhone});
    if (res is Map<String, dynamic>) {
      return (oldCode: res['devOldCode'] as String?, newCode: res['devNewCode'] as String?);
    }
    return (oldCode: null, newCode: null);
  }

  Future<void> confirmPhoneChange({required String newPhone, required String oldCode, required String newCode}) async {
    await api.post('/auth/phone-change/confirm', body: {'newPhone': newPhone, 'oldCode': oldCode, 'newCode': newCode});
    await reloadMe();
  }
}
