import 'package:dio/dio.dart';
import 'package:dramabox_free/core/network/rate_limit_interceptor.dart';

class NetworkClient {
  final Dio dio;

  NetworkClient()
    : dio = Dio(
        BaseOptions(
          baseUrl: 'https://api.sansekai.my.id/api',
          connectTimeout: const Duration(seconds: 60),
          receiveTimeout: const Duration(seconds: 60),
          headers: {'accept': 'application/json'},
        ),
      ) {
    dio.interceptors.add(RateLimitInterceptor());
  }
}
