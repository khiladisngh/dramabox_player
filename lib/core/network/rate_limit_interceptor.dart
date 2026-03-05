import 'package:dio/dio.dart';
import 'package:dramabox_free/core/network/rate_limit_exception.dart';

/// Dio interceptor that catches HTTP 429 and 403 responses and throws an
/// [ApiBlockedException] so the UI can display a user-friendly message.
class RateLimitInterceptor extends Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final statusCode = err.response?.statusCode;

    if (statusCode == 429 || statusCode == 403) {
      handler.reject(
        DioException(
          requestOptions: err.requestOptions,
          response: err.response,
          type: DioExceptionType.badResponse,
          error: ApiBlockedException(
            statusCode: statusCode ?? 0,
            message: statusCode == 429
                ? 'Too many requests. Please try again later.'
                : 'API access is temporarily unavailable due to high server load.',
          ),
        ),
      );
      return;
    }
    handler.next(err);
  }
}
