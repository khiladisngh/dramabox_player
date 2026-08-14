import 'package:dio/dio.dart';
import 'package:dramabox_free/core/network/network_client.dart';
import 'package:dramabox_free/core/utils/isolate_parser.dart';
import 'package:dramabox_free/data/models/drama_model.dart';
import 'package:dramabox_free/data/models/episode_model.dart';

abstract class DramaRemoteDataSource {
  Future<List<DramaModel>> getTrendingDramas();
  Future<List<DramaModel>> getLatestDramas();
  Future<List<DramaModel>> getForYouDramas({int page = 1});
  Future<List<DramaModel>> getVipDramas();
  Future<List<DramaModel>> searchDramas(String query);
  Future<List<EpisodeModel>> getDramaEpisodes(String bookId);
  Future<String> decryptVideoUrl(String url);
}

class DramaRemoteDataSourceImpl implements DramaRemoteDataSource {
  final NetworkClient client;
  final Map<String, String> _decryptedCache = {};

  DramaRemoteDataSourceImpl({required this.client});

  @override
  Future<List<DramaModel>> getTrendingDramas() async {
    final response = await client.dio.get('/dramabox/trending');
    final data = response.data;
    if (data is List) {
      return data.map((e) => DramaModel.fromJson(e)).toList();
    }
    return [];
  }

  @override
  Future<List<DramaModel>> getForYouDramas({int page = 1}) async {
    final response = await client.dio.get(
      '/dramabox/foryou',
      queryParameters: {'page': page},
    );
    final data = response.data;
    if (data is List) {
      return data.map((e) => DramaModel.fromJson(e)).toList();
    }
    return [];
  }

  @override
  Future<List<DramaModel>> getLatestDramas() async {
    final response = await client.dio.get('/dramabox/latest');
    final data = response.data;
    if (data is List) {
      return data.map((e) => DramaModel.fromJson(e)).toList();
    }
    return [];
  }

  @override
  Future<List<DramaModel>> getVipDramas() async {
    final response = await client.dio.get('/dramabox/vip');
    final data = response.data;
    final List<DramaModel> allDramas = [];

    if (data is Map && data['columnVoList'] is List) {
      final columns = data['columnVoList'] as List;
      for (var column in columns) {
        if (column is Map && column['bookList'] is List) {
          final books = column['bookList'] as List;
          allDramas.addAll(books.map((e) => DramaModel.fromJson(e)).toList());
        }
      }
    } else if (data is List) {
      allDramas.addAll(data.map((e) => DramaModel.fromJson(e)).toList());
    }
    return allDramas;
  }

  @override
  Future<List<DramaModel>> searchDramas(String query) async {
    final response = await client.dio.get(
      '/dramabox/search',
      queryParameters: {'query': query},
    );
    final data = response.data;
    if (data is List) {
      return data.map((e) => DramaModel.fromJson(e)).toList();
    }
    return [];
  }

  @override
  Future<List<EpisodeModel>> getDramaEpisodes(String bookId) async {
    final Response<String> rawResponse = await client.dio.get<String>(
      '/dramabox/allepisode',
      queryParameters: {'bookId': bookId},
      options: Options(responseType: ResponseType.plain),
    );

    final dynamic decoded = await IsolateParser.parseJson(
      rawResponse.data ?? '',
    );
    if (decoded is List) {
      return decoded.map((e) => EpisodeModel.fromJson(e)).toList();
    }
    return [];
  }

  @override
  Future<String> decryptVideoUrl(String url) async {
    // If it's already a decrypted stream URL, no need to decrypt again
    if (url.contains('api.sansekai.my.id/api/dramabox/decrypt-stream')) {
      return url;
    }

    if (_decryptedCache.containsKey(url)) {
      return _decryptedCache[url]!;
    }

    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await client.dio.get(
          '/dramabox/decrypt',
          queryParameters: {'url': url},
        );
        final data = response.data;
        if (data is Map && data['success'] == true) {
          final streamUrl = data['streamUrl'] as String;
          _decryptedCache[url] = streamUrl;
          return streamUrl;
        }

        // If direct string is returned and it's a valid URL, use it
        if (data is String && data.startsWith('http')) {
          _decryptedCache[url] = data;
          return data;
        }

        return '';
      } catch (e) {
        if (attempt < 2) {
          await Future.delayed(Duration(milliseconds: 1000 * (attempt + 1)));
          continue;
        }
        rethrow;
      }
    }
    return '';
  }
}
