import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'token_store.dart';

/// JSON API client. Adds the bearer token, refreshes once on 401 (concurrent refreshes share one
/// request) and retries; if the refresh is rejected the session is cleared and [onSessionExpired] fires.
class ApiClient {
  ApiClient({
    String? baseUrl,
    http.Client? httpClient,
    TokenStore? tokenStore,
    this.timeout = const Duration(seconds: 20),
  })  : baseUrl = _trimSlash(baseUrl ?? defaultBaseUrl),
        _http = httpClient ?? http.Client(),
        _store = tokenStore ?? SecureTokenStore();

  static const defaultBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:3000');

  final String baseUrl;
  final Duration timeout;
  final http.Client _http;
  final TokenStore _store;

  /// Called when the refresh token was rejected and the local session was discarded.
  void Function()? onSessionExpired;

  TokenPair? _tokens;
  Future<bool>? _refreshing;

  static String _trimSlash(String s) => s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  bool get hasSession => _tokens != null;

  /// Loads persisted tokens. Call once at startup.
  Future<void> init() async {
    _tokens = await _store.read();
  }

  Future<void> setSession(String accessToken, String refreshToken) async {
    _tokens = TokenPair(accessToken, refreshToken);
    await _store.write(_tokens!);
  }

  Future<void> clearSession() async {
    _tokens = null;
    await _store.clear();
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) => request('GET', path, query: query);
  Future<dynamic> post(String path, {Object? body, bool auth = true}) => request('POST', path, body: body, auth: auth);
  Future<dynamic> patch(String path, {Object? body}) => request('PATCH', path, body: body);
  Future<dynamic> delete(String path) => request('DELETE', path);

  /// Returns the decoded JSON body, or null for empty (204) responses.
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, bool auth = true}) async {
    final sentWith = auth ? _tokens?.access : null;
    var res = await _send(method, path, body, query, sentWith);
    if (res.statusCode == 401 && auth && sentWith != null) {
      if (await _refreshAfter(sentWith)) {
        res = await _send(method, path, body, query, _tokens!.access);
      }
    }
    return _decode(res);
  }

  /// Uploads one file as multipart/form-data (e.g. a patient document). Same auth/refresh behaviour as [request].
  Future<dynamic> postMultipart(String path, {Map<String, String> fields = const {}, required List<int> bytes, required String filename, String fileField = 'file'}) async {
    Future<http.Response> send(String? token) async {
      final req = http.MultipartRequest('POST', Uri.parse('$baseUrl$path'))
        ..headers['accept'] = 'application/json'
        ..headers.addAll({if (token != null) 'authorization': 'Bearer $token'})
        ..fields.addAll(fields)
        ..files.add(http.MultipartFile.fromBytes(fileField, bytes, filename: filename));
      try {
        return await http.Response.fromStream(await _http.send(req).timeout(timeout));
      } on TimeoutException {
        throw ApiException.network('timeout');
      } on http.ClientException catch (e) {
        throw ApiException.network(e.message);
      }
    }

    final sentWith = _tokens?.access;
    var res = await send(sentWith);
    if (res.statusCode == 401 && sentWith != null && await _refreshAfter(sentWith)) {
      res = await send(_tokens!.access);
    }
    return _decode(res);
  }

  /// True when a usable session exists afterwards (refreshed by us or by a concurrent call).
  Future<bool> _refreshAfter(String staleAccess) {
    final current = _tokens;
    if (current == null) return Future.value(false);
    if (current.access != staleAccess) return Future.value(true); // already refreshed by someone else
    return _refreshing ??= _refresh(current.refresh).whenComplete(() => _refreshing = null);
  }

  Future<bool> _refresh(String refreshToken) async {
    final http.Response res;
    try {
      res = await _send('POST', '/auth/refresh', {'refreshToken': refreshToken}, null, null);
    } on ApiException {
      rethrow; // transport failure: keep the session, let the caller retry later
    }
    if (res.statusCode == 200) {
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      await setSession(json['accessToken'] as String, json['refreshToken'] as String);
      return true;
    }
    if (res.statusCode >= 400 && res.statusCode < 500) {
      await clearSession();
      onSessionExpired?.call();
      return false;
    }
    throw _error(res); // 5xx: temporary
  }

  Future<http.Response> _send(String method, String path, Object? body, Map<String, String>? query, String? token) async {
    var uri = Uri.parse('$baseUrl$path');
    if (query != null && query.isNotEmpty) uri = uri.replace(queryParameters: query);
    final req = http.Request(method, uri)
      ..headers['accept'] = 'application/json'
      ..headers.addAll({if (token != null) 'authorization': 'Bearer $token'});
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    try {
      return await http.Response.fromStream(await _http.send(req).timeout(timeout));
    } on TimeoutException {
      throw ApiException.network('timeout');
    } on http.ClientException catch (e) {
      throw ApiException.network(e.message);
    }
  }

  dynamic _decode(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return res.body.isEmpty ? null : jsonDecode(res.body);
    }
    throw _error(res);
  }

  ApiException _error(http.Response res) {
    try {
      final j = jsonDecode(res.body);
      if (j is Map<String, dynamic>) {
        return ApiException(
          status: res.statusCode,
          code: (j['error'] ?? 'error').toString(),
          message: (j['message'] ?? 'Request failed (${res.statusCode})').toString(),
          details: j['details'],
        );
      }
    } catch (_) {}
    return ApiException(status: res.statusCode, code: 'http_${res.statusCode}', message: 'Request failed (${res.statusCode})');
  }
}
