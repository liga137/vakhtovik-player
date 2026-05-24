import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/preset.dart';
import '../models/transcode_result.dart';
import '../models/youtube_video.dart';

/// Сервис для работы с API «Плеер Вахтовика»
class ApiService {
  // Домен nip.io совпадает с SSL-сертификатом Let's Encrypt (IP напрямую → ошибка mismatch)
  static const String _baseUrl = 'https://195.226.92.151.nip.io:8008';
  static String? _ytToken;
  static String? _ytUsername;

  static bool get isYouTubeLoggedIn => _ytToken != null;
  static String? get youtubeUsername => _ytUsername;
  static String? get youtubeToken => _ytToken;
  static String get baseUrl => _baseUrl;

  static Map<String, String> get _ytHeaders => {
        'Content-Type': 'application/json',
        if (_ytToken != null) 'Authorization': 'Bearer $_ytToken',
      };

  /// Получить список пресетов качества
  static Future<List<Preset>> getPresets() async {
    final response = await http.get(Uri.parse('$_baseUrl/presets'));
    if (response.statusCode == 200) {
      final Map<String, dynamic> data = json.decode(response.body);
      return data.entries
          .map((e) => Preset.fromJson(e.key, e.value as Map<String, dynamic>))
          .toList();
    }
    throw Exception('Ошибка загрузки пресетов: ${response.statusCode}');
  }

  /// Запустить транскодирование
  static Future<TranscodeResult> transcode({
    required String url,
    String quality = '360p',
    String referer = '',
  }) async {
    final uri = Uri.parse('$_baseUrl/transcode').replace(
      queryParameters: {'url': url, 'quality': quality, 'referer': referer},
    );
    final response = await http.post(uri);
    if (response.statusCode == 200) {
      return TranscodeResult.fromJson(json.decode(response.body));
    }
    final body = json.decode(response.body);
    throw Exception(
        body['detail'] ?? 'Ошибка транскодирования: ${response.statusCode}');
  }

  /// Получить статус сессии
  static Future<Map<String, dynamic>> getStatus(String sessionId) async {
    final response = await http.get(Uri.parse('$_baseUrl/status/$sessionId'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Ошибка статуса: ${response.statusCode}');
  }

  /// Остановить и очистить сессию
  static Future<void> stopSession(String sessionId) async {
    await http.post(Uri.parse('$_baseUrl/stop/$sessionId'));
  }

  /// Полный URL для HLS плейлиста
  static String hlsUrl(String playlistPath) {
    return '$_baseUrl$playlistPath';
  }

  /// URL для экономного прокси-режима страниц
  static String liteUrl(String targetUrl) {
    return Uri.parse('$_baseUrl/lite')
        .replace(queryParameters: {'url': targetUrl}).toString();
  }

  /// Нативный поиск YouTube через серверный yt-dlp
  static Future<List<YouTubeVideo>> searchYouTube(String query,
      {int limit = 12}) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final uri = Uri.parse('$_baseUrl/yt/search').replace(
      queryParameters: {'q': q, 'limit': limit.toString()},
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 30));
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as List<dynamic>;
      return data
          .whereType<Map<String, dynamic>>()
          .map(YouTubeVideo.fromJson)
          .where((v) => v.id.isNotEmpty || v.url.isNotEmpty)
          .toList();
    }
    throw Exception('Ошибка поиска YouTube: ${response.statusCode}');
  }

  static Future<void> youtubeRegister(String username, String password) async {
    await _youtubeAuth('/yt/auth/register', username, password);
  }

  static Future<void> youtubeLogin(String username, String password) async {
    await _youtubeAuth('/yt/auth/login', username, password);
  }

  static Future<void> _youtubeAuth(
      String path, String username, String password) async {
    final response = await http.post(
      Uri.parse('$_baseUrl$path'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'username': username, 'password': password}),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      _ytToken = data['token'] as String?;
      _ytUsername = data['username'] as String? ?? username;
      return;
    }
    throw Exception(
        'Ошибка авторизации: ${response.statusCode} ${response.body}');
  }

  static void youtubeLogout() {
    _ytToken = null;
    _ytUsername = null;
  }

  static Future<List<Map<String, dynamic>>> youtubeSubscriptions() async {
    final response = await http.get(
      Uri.parse('$_baseUrl/yt/subscriptions'),
      headers: _ytHeaders,
    );
    if (response.statusCode == 200) {
      return List<Map<String, dynamic>>.from(json.decode(response.body));
    }
    throw Exception('Ошибка подписок: ${response.statusCode}');
  }

  static Future<void> youtubeAddSubscription(String input,
      {String channelName = ''}) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/yt/subscriptions/add'),
      headers: _ytHeaders,
      body: json.encode({'text': input, 'channel_name': channelName}),
    );
    if (response.statusCode == 200) return;
    throw Exception(
        'Ошибка добавления: ${response.statusCode} ${response.body}');
  }

  static Future<List<YouTubeVideo>> youtubeFeed({int limit = 30}) async {
    final uri = Uri.parse('$_baseUrl/yt/feed')
        .replace(queryParameters: {'limit': limit.toString()});
    final response = await http.get(uri, headers: _ytHeaders);
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as List<dynamic>;
      return data.whereType<Map<String, dynamic>>().map(YouTubeVideo.fromJson).toList();
    }
    throw Exception('Ошибка ленты: ${response.statusCode}');
  }

  static Future<List<YouTubeVideo>> youtubePopular({int limit = 24}) async {
    final uri = Uri.parse('$_baseUrl/yt/popular')
        .replace(queryParameters: {'limit': limit.toString()});
    final response = await http.get(uri).timeout(const Duration(seconds: 30));
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as List<dynamic>;
      return data.whereType<Map<String, dynamic>>().map(YouTubeVideo.fromJson).toList();
    }
    throw Exception('Ошибка популярного: ${response.statusCode}');
  }

  static String youtubeGoogleStartUrl(String state) {
    final token = _ytToken;
    if (token == null) throw Exception('Сначала войдите во внутренний аккаунт');
    return Uri.parse('$_baseUrl/yt/google/start').replace(
      queryParameters: {'token': token, 'state': state},
    ).toString();
  }

  static Future<Map<String, dynamic>> youtubeGoogleStatus(String state) async {
    final uri = Uri.parse('$_baseUrl/yt/google/status').replace(
      queryParameters: {'state': state},
    );
    final response = await http.get(uri);
    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw Exception('Ошибка статуса Google: ${response.statusCode}');
  }
}
