import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/youtube_video.dart';

/// Piped API — открытый YouTube-фронтенд, не требует ключей.
/// Инстансы: https://github.com/TeamPiped/Piped/wiki/Instances
class PipedService {
  static const _instances = [
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.tokhmi.xyz',
    'https://pipedapi.moomoo.me',
    'https://pipedapi.syncpundit.io',
    'https://piped-api.garudalinux.org',
  ];

  static int _instanceIndex = 0;
  static String get _baseUrl => _instances[_instanceIndex];

  static void _nextInstance() {
    _instanceIndex = (_instanceIndex + 1) % _instances.length;
  }

  /// Популярное / тренды
  static Future<List<YouTubeVideo>> getTrending({String region = 'RU'}) async {
    for (var attempt = 0; attempt < _instances.length; attempt++) {
      try {
        final uri = Uri.parse('$_baseUrl/trending?region=$region');
        final resp = await http.get(uri).timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) {
          final data = json.decode(resp.body) as List<dynamic>;
          return data.map((v) => _fromPiped(v)).toList();
        }
      } catch (_) {}
      _nextInstance();
    }
    return [];
  }

  /// Поиск
  static Future<List<YouTubeVideo>> search(String query, {int limit = 20}) async {
    for (var attempt = 0; attempt < _instances.length; attempt++) {
      try {
        final uri = Uri.parse('$_baseUrl/search?q=${Uri.encodeComponent(query)}&filter=videos');
        final resp = await http.get(uri).timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) {
          final data = json.decode(resp.body) as Map<String, dynamic>;
          final items = (data['items'] as List<dynamic>?)
              ?.take(limit)
              .map((v) => _fromPiped(v))
              .toList() ?? [];
          return items;
        }
      } catch (_) {}
      _nextInstance();
    }
    return [];
  }

  /// Главная (неавторизованная лента)
  static Future<List<YouTubeVideo>> getHome({String region = 'RU'}) async {
    for (var attempt = 0; attempt < _instances.length; attempt++) {
      try {
        final uri = Uri.parse('$_baseUrl/feed/unauthenticated?region=$region');
        final resp = await http.get(uri).timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) {
          final data = json.decode(resp.body) as List<dynamic>;
          return data.map((v) => _fromPiped(v)).toList();
        }
      } catch (_) {}
      _nextInstance();
    }
    return [];
  }

  static YouTubeVideo _fromPiped(dynamic v) {
    final id = (v['url'] ?? '').toString().replaceAll('/watch?v=', '');
    return YouTubeVideo(
      id: id,
      title: (v['title'] ?? '').toString(),
      channel: (v['uploaderName'] ?? v['uploader'] ?? '').toString(),
      thumbnail: (v['thumbnail'] ?? '').toString(),
      duration: v['duration'] is int ? v['duration'] as int : 0,
      viewsText: _fmtViews(v['views']),
      publishedText: (v['uploadedDate'] ?? v['uploaded'] ?? '').toString(),
      url: 'https://www.youtube.com/watch?v=$id',
    );
  }

  static String _fmtViews(dynamic v) {
    if (v == null) return '';
    if (v is int && v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v is int && v >= 1000) return '${(v / 1000).toStringAsFixed(1)}K';
    return v.toString();
  }
}
