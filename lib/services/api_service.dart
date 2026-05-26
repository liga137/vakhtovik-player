import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/preset.dart';
import '../models/transcode_result.dart';
import '../models/youtube_video.dart';

/// Сервис для работы с API «Плеер Вахтовика»
class ApiService {
  static const String _baseUrlHttps = 'https://195.226.92.151.nip.io:8008';
  static const String _ytTokenKey = 'yt_token';
  static const String _ytUsernameKey = 'yt_username';
  static const String _ytWatchedChannelsKey = 'yt_watched_channels';
  static String? _ytToken;
  static String? _ytUsername;
  static bool _ytStateLoaded = false;

  static http.Client get _client => IOClient(_directHttpClient());

  static HttpClient _directHttpClient() {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 45);
    client.badCertificateCallback = (cert, host, port) => true;
    client.findProxy = (uri) => 'PROXY 127.0.0.1:1080; DIRECT';
    return client;
  }

  /// Пробует HTTPS; при HandshakeException/TLS-ошибке возвращает HTTPS-URL по IP.
  static Future<String> _resolveBaseUrl() async {
    try {
      final req = await _client
          .get(Uri.parse('$_baseUrlHttps/presets'))
          .timeout(const Duration(seconds: 15));
      if (req.statusCode == 200) return _baseUrlHttps;
    } catch (_) {}
    return 'https://195.226.92.151:8008';
  }

  static bool get isYouTubeLoggedIn => _ytToken != null;
  static String? get youtubeUsername => _ytUsername;
  static String? get youtubeToken => _ytToken;

  static String? _resolvedBaseUrl;
  static String get baseUrl => _resolvedBaseUrl ?? 'https://195.226.92.151:8008';

  static Future<void> _ensureBaseUrlResolved() async {
    if (_resolvedBaseUrl != null) return;
    _resolvedBaseUrl = await _resolveBaseUrl();
  }

  static Map<String, String> get _ytHeaders => {
        'Content-Type': 'application/json',
        if (_ytToken != null) 'Authorization': 'Bearer $_ytToken',
      };

  static Future<void> initLocalState() async {
    if (_ytStateLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    _ytToken = prefs.getString(_ytTokenKey);
    _ytUsername = prefs.getString(_ytUsernameKey);
    _ytStateLoaded = true;
    await _ensureBaseUrlResolved();
  }

  static Future<void> _saveAuthState() async {
    final prefs = await SharedPreferences.getInstance();
    if (_ytToken == null || _ytToken!.isEmpty) {
      await prefs.remove(_ytTokenKey);
      await prefs.remove(_ytUsernameKey);
      return;
    }
    await prefs.setString(_ytTokenKey, _ytToken!);
    if (_ytUsername != null && _ytUsername!.isNotEmpty) {
      await prefs.setString(_ytUsernameKey, _ytUsername!);
    }
  }

  /// Получить список пресетов качества
  static Future<List<Preset>> getPresets() async {
    final response = await _client.get(Uri.parse('$baseUrl/presets'));
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
    final uri = Uri.parse('$baseUrl/transcode').replace(
      queryParameters: {'url': url, 'quality': quality, 'referer': referer},
    );
    final response = await _client.post(uri);
    if (response.statusCode == 200) {
      return TranscodeResult.fromJson(json.decode(response.body));
    }
    final body = json.decode(response.body);
    throw Exception(
        body['detail'] ?? 'Ошибка транскодирования: ${response.statusCode}');
  }

  /// Получить статус сессии
  static Future<Map<String, dynamic>> getStatus(String sessionId) async {
    final response = await _client.get(Uri.parse('$baseUrl/status/$sessionId'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Ошибка статуса: ${response.statusCode}');
  }

  /// Остановить и очистить сессию
  static Future<void> stopSession(String sessionId) async {
    await _client.post(Uri.parse('$baseUrl/stop/$sessionId'));
  }

  /// Скачать транскодированный mp4 на диск
  static Future<void> downloadSessionMp4({
    required String sessionId,
    required String outputPath,
  }) async {
    final request =
        http.Request('GET', Uri.parse('$baseUrl/download/$sessionId'));
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw Exception('Ошибка скачивания: ${response.statusCode} $body');
    }

    final outFile = File(outputPath);
    await outFile.parent.create(recursive: true);
    final sink = outFile.openWrite();
    await response.stream.pipe(sink);
    await sink.close();
  }

  /// Полный URL для HLS плейлиста
  static String hlsUrl(String playlistPath) {
    return '$baseUrl$playlistPath';
  }

  /// URL для экономного прокси-режима страниц
  static String liteUrl(String targetUrl) {
    return Uri.parse('$baseUrl/lite')
        .replace(queryParameters: {'url': targetUrl}).toString();
  }

  /// Нативный поиск YouTube через серверный yt-dlp
  static Future<List<YouTubeVideo>> searchYouTube(String query,
      {int limit = 12}) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final uri = Uri.parse('$baseUrl/yt/search').replace(
      queryParameters: {'q': q, 'limit': limit.toString()},
    );
    final response =
        await _client.get(uri).timeout(const Duration(seconds: 30));
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
    await initLocalState();
    await _youtubeAuth('/yt/auth/register', username, password);
  }

  static Future<void> youtubeLogin(String username, String password) async {
    await initLocalState();
    await _youtubeAuth('/yt/auth/login', username, password);
  }

  static Future<void> _youtubeAuth(
      String path, String username, String password) async {
    final response = await _client.post(
      Uri.parse('$baseUrl$path'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'username': username, 'password': password}),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      _ytToken = data['token'] as String?;
      _ytUsername = data['username'] as String? ?? username;
      await _saveAuthState();
      return;
    }
    throw Exception(
        'Ошибка авторизации: ${response.statusCode} ${response.body}');
  }

  static void youtubeLogout() {
    _ytToken = null;
    _ytUsername = null;
    unawaited(_saveAuthState());
  }

  static Future<List<Map<String, dynamic>>> youtubeSubscriptions() async {
    await initLocalState();
    final response = await _client.get(
      Uri.parse('$baseUrl/yt/subscriptions'),
      headers: _ytHeaders,
    );
    if (response.statusCode == 200) {
      return List<Map<String, dynamic>>.from(json.decode(response.body));
    }
    throw Exception('Ошибка подписок: ${response.statusCode}');
  }

  static Future<void> youtubeAddSubscription(String input,
      {String channelName = ''}) async {
    await initLocalState();
    final response = await _client.post(
      Uri.parse('$baseUrl/yt/subscriptions/add'),
      headers: _ytHeaders,
      body: json.encode({'text': input, 'channel_name': channelName}),
    );
    if (response.statusCode == 200) return;
    throw Exception(
        'Ошибка добавления: ${response.statusCode} ${response.body}');
  }

  static Future<List<YouTubeVideo>> youtubeFeed({int limit = 30}) async {
    await initLocalState();
    final uri = Uri.parse('$baseUrl/yt/feed')
        .replace(queryParameters: {'limit': limit.toString()});
    final response = await _client.get(uri, headers: _ytHeaders);
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as List<dynamic>;
      return data
          .whereType<Map<String, dynamic>>()
          .map(YouTubeVideo.fromJson)
          .toList();
    }
    throw Exception('Ошибка ленты: ${response.statusCode}');
  }

  static Future<List<YouTubeVideo>> youtubePopular({int limit = 24}) async {
    await initLocalState();
    final uri = Uri.parse('$baseUrl/yt/popular')
        .replace(queryParameters: {'limit': limit.toString()});
    final response =
        await _client.get(uri).timeout(const Duration(seconds: 30));
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as List<dynamic>;
      return data
          .whereType<Map<String, dynamic>>()
          .map(YouTubeVideo.fromJson)
          .toList();
    }
    throw Exception('Ошибка популярного: ${response.statusCode}');
  }

  static String youtubeGoogleStartUrl(String state) {
    final token = _ytToken;
    if (token == null) throw Exception('Сначала войдите во внутренний аккаунт');
    return Uri.parse('$baseUrl/yt/google/start').replace(
      queryParameters: {'token': token, 'state': state},
    ).toString();
  }

  static Future<Map<String, dynamic>> youtubeGoogleStatus(String state) async {
    await initLocalState();
    final uri = Uri.parse('$baseUrl/yt/google/status').replace(
      queryParameters: {'state': state},
    );
    final response = await _client.get(uri);
    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw Exception('Ошибка статуса Google: ${response.statusCode}');
  }

  static String _normalizeChannelName(String value) {
    final t = value.trim().toLowerCase();
    if (t.isEmpty) return '';
    final noAt = t.startsWith('@') ? t.substring(1) : t;
    return noAt.replaceAll(RegExp(r'\s+'), ' ');
  }

  static Future<List<String>> youtubeWatchedChannels() async {
    await initLocalState();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_ytWatchedChannelsKey) ?? const [];
    final out = <String>[];
    final seen = <String>{};
    for (final item in raw) {
      final t = item.trim();
      final key = _normalizeChannelName(t);
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      out.add(t);
    }
    return out;
  }

  static Future<void> youtubeRememberWatchedChannel(String channel) async {
    final ch = channel.trim();
    if (ch.isEmpty) return;
    final existing = await youtubeWatchedChannels();
    final key = _normalizeChannelName(ch);
    final rebuilt = <String>[ch];
    for (final it in existing) {
      if (_normalizeChannelName(it) == key) continue;
      rebuilt.add(it);
      if (rebuilt.length >= 40) break;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_ytWatchedChannelsKey, rebuilt);
  }

  static bool _isSimilarChannel(String a, String b) {
    final na = _normalizeChannelName(a);
    final nb = _normalizeChannelName(b);
    if (na.isEmpty || nb.isEmpty) return false;
    if (na == nb) return true;
    return na.contains(nb) || nb.contains(na);
  }

  static String _videoKey(YouTubeVideo video) {
    if (video.id.isNotEmpty) return 'id:${video.id}';
    if (video.url.isNotEmpty) return 'url:${video.url}';
    return 'ttl:${video.title.toLowerCase()}|ch:${video.channel.toLowerCase()}';
  }

  static Future<List<YouTubeVideo>> youtubeFresh({int limit = 40}) async {
    await initLocalState();
    final channels = await youtubeWatchedChannels();
    if (channels.isEmpty) {
      if (isYouTubeLoggedIn) {
        try {
          return await youtubeFeed(limit: limit);
        } catch (_) {}
      }
      return youtubePopular(limit: limit);
    }

    final channelBatches = <String, List<YouTubeVideo>>{};
    for (final channel in channels.take(8)) {
      try {
        final items = await searchYouTube(channel, limit: 8);
        var filtered = items
            .where((v) =>
                v.channel.isEmpty || _isSimilarChannel(v.channel, channel))
            .toList();
        if (filtered.isEmpty) filtered = items;
        if (filtered.isNotEmpty) {
          channelBatches[channel] = filtered;
        }
      } catch (_) {}
    }

    if (channelBatches.isEmpty) {
      if (isYouTubeLoggedIn) {
        try {
          return await youtubeFeed(limit: limit);
        } catch (_) {}
      }
      return youtubePopular(limit: limit);
    }

    final output = <YouTubeVideo>[];
    final seen = <String>{};
    final keys = channelBatches.keys.toList();
    var progress = true;
    while (output.length < limit && progress) {
      progress = false;
      for (final key in keys) {
        final list = channelBatches[key]!;
        if (list.isEmpty) continue;
        final item = list.removeAt(0);
        final itemKey = _videoKey(item);
        if (seen.add(itemKey)) {
          output.add(item);
        }
        progress = true;
        if (output.length >= limit) break;
      }
    }
    return output;
  }
}
