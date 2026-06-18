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
}

/// Локальный парсер сериалов
class SeriesParserService {
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

  // ================= FILMIX PARSER =================

  static String? _extractFilmixId(String url) {
    final patterns = [
      RegExp(r'/(?:seria|film)/[^/]+/(\d+)-'),
      RegExp(r'/(\d+)-[^/]+\.html$'),
      RegExp(r'/(\d+)(?=-|\.html|$)'),
    ];
    for (var p in patterns) {
      final m = p.firstMatch(url);
      if (m != null) return m.group(1);
    }
    return null;
  }

  static Future<SeriesParseResult?> parseFilmix(String idOrUrl, {String quality = '720'}) async {
    final id = int.tryParse(idOrUrl) != null ? idOrUrl : _extractFilmixId(idOrUrl);
    if (id == null) return null;

    try {
      final uri = Uri.parse("http://filmixapp.cyou/api/v2/post/$id").replace(queryParameters: {
        "app_lang": "ru_RU",
        "user_dev_apk": "2.2.13",
        "user_dev_id": "cd88df2bd8dd6cf0",
        "user_dev_name": "Xiaomi 2510EPC8BG",
        "user_dev_os": "16",
        "user_dev_token": "7c92a8c95fa1b1d6b6ed35095ad95744",
        "user_dev_vendor": "Xiaomi",
      });

      final resp = await _client.get(uri, headers: {
        "User-Agent": "okhttp/3.10.0",
      }).timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;

      final playlistRaw = data['player_links']?['playlist'];
      if (playlistRaw == null || playlistRaw is! Map) return null;

      final playlist = playlistRaw as Map<String, dynamic>;
      final episodes = <SeriesEpisode>[];

      for (var season in playlist.keys) {
        final translations = playlist[season];
        if (translations is! Map) continue;

        for (var tname in translations.keys) {
          final eps = translations[tname];
          if (eps is! Map) continue;

          for (var ep in eps.keys) {
            final epData = eps[ep];
            if (epData is! Map) continue;

            final linkTpl = epData['link']?.toString();
            if (linkTpl == null) continue;

            final quals = (epData['qualities'] as List<dynamic>? ?? []).map((q) => q.toString()).toList();
            
            String finalLink = linkTpl;
            String finalQuality = quality;

            if (quals.contains(quality)) {
              finalLink = linkTpl.replaceAll('%s', quality);
            } else if (quals.isNotEmpty) {
              finalQuality = quals.last;
              finalLink = linkTpl.replaceAll('%s', finalQuality);
            }

            episodes.add(SeriesEpisode(
              title: data['title']?.toString() ?? '',
              season: season,
              episode: ep,
              translation: tname,
              quality: finalQuality,
              link: finalLink,
            ));
          }
        }
      }

      episodes.sort((a, b) {
        final sA = int.tryParse(a.season ?? '') ?? 0;
        final sB = int.tryParse(b.season ?? '') ?? 0;
        if (sA != sB) return sA.compareTo(sB);
        final eA = int.tryParse(a.episode ?? '') ?? 0;
        final eB = int.tryParse(b.episode ?? '') ?? 0;
        return eA.compareTo(eB);
      });

      return SeriesParseResult(
        title: data['title']?.toString(),
        originalTitle: data['original_title']?.toString(),
        episodes: episodes,
      );

    } catch (e) {
      print('[SeriesParser] Filmix error: $e');
      return null;
    }
  }

  // ================= SEASONVAR PARSER =================

  static String? _decodeSeasonvarPlayerjs(String? encoded) {
    if (encoded == null || !encoded.startsWith('#2')) return encoded;
    
    var clean = encoded.substring(2).replaceAll('//b2xvbG8=', '');
    final pad = clean.length % 4;
    if (pad > 0) clean += '=' * (4 - pad);
    
    try {
      final decoded = utf8.decode(base64.decode(clean));
      return decoded.replaceAll('\\/', '/');
    } catch (_) {
      return null;
    }
  }

  static Future<SeriesParseResult?> parseSeasonvar(String url) async {
    try {
      final headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'ru-RU',
      };

      var resp = await _client.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;

      final match = RegExp(r'(/[^"\x27\s>]+(?:list\.xml|plist\.txt)[^"\x27\s>]*)').firstMatch(resp.body);
      if (match == null) return null;

      var plistPath = match.group(1)!;
      if (plistPath.startsWith('http')) {
        plistPath = plistPath.replaceFirst('http://', 'https://');
      } else {
        plistPath = 'https://seasonvar.ru$plistPath';
      }

      headers['X-Requested-With'] = 'XMLHttpRequest';
      headers['Referer'] = url;

      resp = await _client.get(Uri.parse(plistPath), headers: headers).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;

      final data = jsonDecode(resp.body);
      return parseSeasonvarJson(data, url);

    } catch (e) {
      print('[SeriesParser] Seasonvar error: $e');
      return null;
    }
  }

  static SeriesParseResult? parseSeasonvarJson(dynamic data, String url) {
    try {
      final episodes = <SeriesEpisode>[];

      void walk(dynamic node) {
        if (node is List) {
          for (var item in node) walk(item);
        } else if (node is Map) {
          if (node['file'] is String && (node['file'] as String).startsWith('#2')) {
            var title = node['title']?.toString() ?? 'Неизвестная серия';
            title = title.replaceAll(RegExp(r'<[^>]+>'), ' - ');
            
            var link = _decodeSeasonvarPlayerjs(node['file']);
            if (link != null) {
              if (link.startsWith('//')) link = 'https:$link';
              
              // Пытаемся вытащить сезон и серию из текста
              final sMatch = RegExp(r'(?:season|сезон)\s*(\d{1,2})', caseSensitive: false).firstMatch(title);
              final eMatch = RegExp(r'(?:episode|серия|ep)\s*(\d{1,3})', caseSensitive: false).firstMatch(title);
              
              episodes.add(SeriesEpisode(
                title: title,
                season: node['season']?.toString() ?? sMatch?.group(1),
                episode: node['episode']?.toString() ?? eMatch?.group(1),
                link: link,
              ));
            }
          }
          if (node['folder'] != null) walk(node['folder']);
        }
      }

      walk(data);

      if (episodes.isEmpty) return null;

      return SeriesParseResult(
        title: url,
        episodes: episodes,
      );
    } catch (e) {
      print('[SeriesParser] parseSeasonvarJson error: $e');
      return null;
    }
  }

  /// Определяет, Filmix это или Seasonvar, и вызывает нужный парсер.
  static Future<SeriesParseResult?> parse(String url, {String quality = '720'}) async {
    final low = url.toLowerCase();
    if (low.contains('filmix')) {
      return parseFilmix(url, quality: quality);
    }
    return null;
  }
}
