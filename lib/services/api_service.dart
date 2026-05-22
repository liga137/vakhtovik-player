import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/preset.dart';
import '../models/transcode_result.dart';

/// Сервис для работы с API «Плеер Вахтовика»
class ApiService {
  // Домен nip.io совпадает с SSL-сертификатом Let's Encrypt (IP напрямую → ошибка mismatch)
  static const String _baseUrl = 'https://195.226.92.151.nip.io:8008';

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
    throw Exception(body['detail'] ?? 'Ошибка транскодирования: ${response.statusCode}');
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
}
