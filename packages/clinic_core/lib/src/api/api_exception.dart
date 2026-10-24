/// Error returned by the API (`{error, message, details?}`) or a transport failure (status 0).
class ApiException implements Exception {
  ApiException({required this.status, required this.code, required this.message, this.details});

  factory ApiException.network([String? detail]) => ApiException(
        status: 0,
        code: 'network_error',
        message: 'Cannot reach the server. Check your connection and try again.',
        details: detail,
      );

  final int status;
  final String code;
  final String message;
  final Object? details;

  bool get isNetwork => status == 0;
  bool get isUnauthorized => status == 401;

  @override
  String toString() => 'ApiException($status, $code, $message)';
}
