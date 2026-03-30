import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

class VideoProxyService {
  HttpServer? _server;
  int _port = 0;
  final String _localIp = '127.0.0.1';

  final HttpClient _httpClient = HttpClient();

  /// Initializes the proxy server.
  /// Only starts the server on Android.
  Future<void> init() async {
    try {
      // Bind to loopback interface (localhost) on an ephemeral port (0)
      _server = await HttpServer.bind(_localIp, 0);
      _port = _server!.port;
      _httpClient.connectionTimeout = const Duration(seconds: 15);
      debugPrint(
        'VideoProxyService: Server running on http://$_localIp:$_port/',
      );

      _server!.listen(_handleRequest);
    } catch (e) {
      debugPrint('VideoProxyService: Failed to start server: $e');
    }
  }

  /// Returns the proxied URL for Android, or the original URL for other platforms.
  /// Returns the proxied URL if the server is available, otherwise returns the original URL.
  String getProxyUrl(String originalUrl) {
    if (_server == null) {
      return originalUrl;
    }
    // Encode the original URL to safely pass it as a query parameter
    final encodedUrl = Uri.encodeComponent(originalUrl);
    return 'http://$_localIp:$_port/?url=$encodedUrl';
  }

  /// Handles incoming requests from the video player.
  Future<void> _handleRequest(HttpRequest request) async {
    final originalUrl = request.uri.queryParameters['url'];
    if (originalUrl == null) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.close();
      return;
    }

    try {
      final actualUrl = Uri.parse(originalUrl);
      final proxyRequest = await _httpClient.getUrl(actualUrl);

      // Forward headers from the original request
      String? rangeHeaderText;
      request.headers.forEach((name, values) {
        if (name.toLowerCase() == 'range') {
          rangeHeaderText = values.first;
        }
        if (name.toLowerCase() != 'host' &&
            name.toLowerCase() != 'connection') {
          for (var value in values) {
            proxyRequest.headers.add(name, value);
          }
        }
      });

      final proxyResponse = await proxyRequest.close();
      final response = request.response;

      // Extract requested range
      int start = 0;
      int? end;
      bool isRangeRequest = rangeHeaderText != null;

      if (isRangeRequest) {
        final parts = rangeHeaderText!.split('=');
        if (parts.length == 2 && parts[0] == 'bytes') {
          final rangeParts = parts[1].split('-');
          start = int.tryParse(rangeParts[0]) ?? 0;
          if (rangeParts.length > 1 && rangeParts[1].isNotEmpty) {
            end = int.tryParse(rangeParts[1]);
          }
        }
      }

      final totalLength = proxyResponse.contentLength; // -1 if unknown

      // OPTIMIZATION: Fast path if no range is needed, or if server already handled it,
      // or if the player asks for a range starting at 0 and server gave the full file.
      if (proxyResponse.statusCode == HttpStatus.partialContent ||
          !isRangeRequest ||
          (proxyResponse.statusCode == HttpStatus.ok &&
              start == 0 &&
              end == null)) {
        response.statusCode = proxyResponse.statusCode;
        proxyResponse.headers.forEach((name, values) {
          for (var value in values) {
            response.headers.add(name, value);
          }
        });

        response.headers.contentType ??= ContentType.parse("video/mp4");

        if (!isRangeRequest && proxyResponse.statusCode == HttpStatus.ok) {
          response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        }

        await proxyResponse.pipe(response);
        return;
      }

      // Case: Manual Slicing (Server returned 200 OK but a range (>0 or chunked) was requested)
      if (proxyResponse.statusCode == HttpStatus.ok) {
        int actualEnd = end ?? (totalLength != -1 ? totalLength - 1 : -1);

        response.statusCode = HttpStatus.partialContent;

        // Forward headers except content-length (calculated manually)
        proxyResponse.headers.forEach((name, values) {
          if (name.toLowerCase() != 'content-length' &&
              name.toLowerCase() != 'content-range') {
            for (var value in values) {
              response.headers.add(name, value);
            }
          }
        });

        // Set mandatory range headers
        if (totalLength != -1) {
          int headerEnd = (actualEnd == -1) ? totalLength - 1 : actualEnd;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$headerEnd/$totalLength',
          );
          response.headers.contentLength = headerEnd - start + 1;
        } else if (actualEnd != -1) {
          // We have an end but not total length
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$actualEnd/*',
          );
          response.headers.contentLength = actualEnd - start + 1;
        }

        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        response.headers.contentType ??= ContentType.parse("video/mp4");

        debugPrint(
          "Proxy: Manual Range slice for $originalUrl ($start-${actualEnd == -1 ? '' : actualEnd}/${totalLength == -1 ? '*' : totalLength})",
        );

        int bytesServed = 0;
        await for (final chunk in proxyResponse) {
          // Entire chunk is before the start point
          if (bytesServed + chunk.length <= start) {
            bytesServed += chunk.length;
            continue;
          }

          // Calculate what part of this chunk we need
          int chunkStart = (start > bytesServed) ? (start - bytesServed) : 0;
          int chunkEnd = chunk.length - 1;

          if (actualEnd != -1 && bytesServed + chunk.length - 1 > actualEnd) {
            chunkEnd = actualEnd - bytesServed;
          }

          if (chunkStart <= chunkEnd) {
            // Avoid sublist if the whole chunk is used
            if (chunkStart == 0 && chunkEnd == chunk.length - 1) {
              response.add(chunk);
            } else {
              response.add(chunk.sublist(chunkStart, chunkEnd + 1));
            }
          }

          bytesServed += chunk.length;
          if (actualEnd != -1 && bytesServed > actualEnd) break;
        }
        await response.close();
      } else {
        // Handle error status from upstream (404, 403, etc.)
        response.statusCode = proxyResponse.statusCode;
        await proxyResponse.pipe(response);
      }
    } catch (e) {
      debugPrint('VideoProxyService: Error handling request: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.close();
      } catch (_) {}
    }
  }

  void dispose() {
    _server?.close();
  }
}
