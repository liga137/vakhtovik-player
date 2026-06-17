import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HandshakeException, HttpException, Platform, SocketException;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Модель эпизода для сериала
class SeriesEpisode {
  final String title;
  final String? season;
  final String? episode;
  final String? translation;
  final String? quality;
  final String link;

  SeriesEpisode({
    required this.title,
    this.season,
    this.episode,
    this.translation,
    this.quality,
    required this.link,
  });

  factory SeriesEpisode.fromJson(Map<String, dynamic> json) {
    return SeriesEpisode(
      title: json['title']?.toString() ?? '',
      season: json['season']?.toString(),
      episode: json['episode']?.toString(),
      translation: json['translation']?.toString(),
      quality: json['quality']?.toString(),
      link: json['link']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'season': season,
        'episode': episode,
        'translation': translation,
        'quality': quality,
        'link': link,
      };

  /// Человекочитаемый номер: «Сезон 1, Серия 5»
  String get displayNumber {
    final parts = <String>[];
    if (season != null && season!.isNotEmpty) parts.add('S$season');
    if (episode != null && episode!.isNotEmpty) parts.add('E$episode');
    return parts.isEmpty ? title : parts.join(' ');
  }
}

/// Результат парсинга сериала
class SeriesParseResult {
  final String? title;
  final String? originalTitle;
  final List<SeriesEpisode> episodes;
  final List<String> qualities;

  SeriesParseResult({
    this.title,
    this.originalTitle,
    required this.episodes,
    this.qualities = const [],
  });

  factory SeriesParseResult.fromFilmixJson(Map<String, dynamic> json) {
    final eps = (json['episodes'] as List<dynamic>? ?? [])
        .map((e) => SeriesEpisode.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final qs = (json['qualities'] as List<dynamic>? ?? [])
        .map((q) => q.toString())
        .toList();
    return SeriesParseResult(
      title: json['title']?.toString(),
      originalTitle: json['original_title']?.toString(),
      episodes: eps,
      qualities: qs,
    );
  }

  factory SeriesParseResult.fromSeasonvarJson(Map<String, dynamic> json) {
    final eps = (json['episodes'] as List<dynamic>? ?? [])
        .map((e) => SeriesEpisode.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return SeriesParseResult(
      title: json['source']?.toString(),
      episodes: eps,
    );
  }
}

/// Клиент для вызова парсеров сериалов на сервере.
class SeriesParserService {
  static const String _baseUrl = 'https://195.226.92.151.nip.io:8008';
  static const int _maxRetries = 2;
  static const Duration _retryDelay = Duration(seconds: 3);

  static http.Client get _client => IOClient(_httpClient());

  static HttpClient _httpClient() {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    client.idleTimeout = const Duration(seconds: 60);
    client.badCertificateCallback = (cert, host, port) => true;
    if (Platform.isWindows || Platform.isAndroid) {
      client.findProxy = (uri) => 'PROXY 127.0.0.1:1080; DIRECT';
    }
    return client;
  }

  static Future<http.Response> _get(String path, Map<String, String> params,
      {int retries = 0}) async {
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: params);
    try {
      return await _client.get(uri).timeout(const Duration(seconds: 20));
    } on SocketException catch (_) {
      if (retries < _maxRetries) {
        await Future.delayed(_retryDelay);
        return _get(path, params, retries: retries + 1);
      }
      rethrow;
    } on HandshakeException catch (_) {
      if (retries < _maxRetries) {
        await Future.delayed(_retryDelay);
        return _get(path, params, retries: retries + 1);
      }
      rethrow;
    } on HttpException catch (_) {
      if (retries < _maxRetries) {
        await Future.delayed(_retryDelay);
        return _get(path, params, retries: retries + 1);
      }
      rethrow;
    }
  }

  /// Парсит сериал Filmix по ID или URL.
  static Future<SeriesParseResult?> parseFilmix(String idOrUrl,
      {String quality = '720'}) async {
    try {
      final resp = await _get('/parse/filmix', {
        'id': idOrUrl,
        'quality': quality,
      });

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return SeriesParseResult.fromFilmixJson(data);
      } else {
        print('[SeriesParser] Filmix error: ${resp.statusCode} ${resp.body}');
        return null;
      }
    } catch (e) {
      print('[SeriesParser] Filmix exception: $e');
      return null;
    }
  }

  /// Парсит страницу Seasonvar по URL.
  static Future<SeriesParseResult?> parseSeasonvar(String url) async {
    try {
      final resp = await _get('/parse/seasonvar', {'url': url});

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return SeriesParseResult.fromSeasonvarJson(data);
      } else {
        print('[SeriesParser] Seasonvar error: ${resp.statusCode}');
        return null;
      }
    } catch (e) {
      print('[SeriesParser] Seasonvar exception: $e');
      return null;
    }
  }

  /// Определяет, Filmix это или Seasonvar, и вызывает нужный парсер.
  static Future<SeriesParseResult?> parse(String url,
      {String quality = '720'}) async {
    final low = url.toLowerCase();
    if (low.contains('filmix')) {
      return parseFilmix(url, quality: quality);
    } else if (low.contains('seasonvar')) {
      return parseSeasonvar(url);
    }
    return null;
  }
}
