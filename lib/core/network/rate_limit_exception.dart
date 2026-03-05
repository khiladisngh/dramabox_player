/// Exception thrown when the API returns a 429 (Too Many Requests) or
/// 403 (Forbidden) response indicating the server is blocking access.
class ApiBlockedException implements Exception {
  final String message;
  final int statusCode;

  const ApiBlockedException({
    this.message = 'API access is temporarily unavailable.',
    this.statusCode = 0,
  });

  bool get isRateLimited => statusCode == 429;
  bool get isForbidden => statusCode == 403;

  @override
  String toString() => message;
}
