import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenPair {
  const TokenPair(this.access, this.refresh);
  final String access;
  final String refresh;
}

/// Persistence for the session tokens. Tests use [MemoryTokenStore].
abstract class TokenStore {
  Future<TokenPair?> read();
  Future<void> write(TokenPair tokens);
  Future<void> clear();
}

class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([this._tokens]);
  TokenPair? _tokens;

  @override
  Future<TokenPair?> read() async => _tokens;
  @override
  Future<void> write(TokenPair tokens) async => _tokens = tokens;
  @override
  Future<void> clear() async => _tokens = null;
}

class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage, this.namespace = 'carelink'})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final String namespace;

  String get _a => '$namespace.access';
  String get _r => '$namespace.refresh';

  @override
  Future<TokenPair?> read() async {
    final a = await _storage.read(key: _a);
    final r = await _storage.read(key: _r);
    return a == null || r == null ? null : TokenPair(a, r);
  }

  @override
  Future<void> write(TokenPair tokens) async {
    await _storage.write(key: _a, value: tokens.access);
    await _storage.write(key: _r, value: tokens.refresh);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _a);
    await _storage.delete(key: _r);
  }
}
