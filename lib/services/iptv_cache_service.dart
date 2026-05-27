import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'log_service.dart';

/// Кэш IPTV плейлистов: сначала встроенный ассет, потом сеть.
/// Без внешних зависимостей — только dart:io + flutter/services.
class IptvCacheService {
  static const _assets = <String, String>{
    'belarus': 'assets/iptv/belarus.m3u',
  };

  static String _cacheDir() {
    if (Platform.isWindows) {
      final base = Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'] ??
          '.';
      return '$base\\VakhtovikPlayer\\iptv_cache';
    }
    return '${Directory.systemTemp.path}/vakhtovik_player/iptv_cache';
  }

  /// Загружает плейлист: сначала из кэша, если нет — из ассета.
  static Future<String> loadPlaylist(String country,
      {required String networkUrl}) async {
    // 1. Пробуем сохранённый кэш (из предыдущих обновлений сети)
    final cachePath = '$_cacheDir()${Platform.pathSeparator}${country}_cached.m3u';
    try {
      final file = File(cachePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty && content.contains('#EXTM3U')) return content;
      }
    } catch (_) {}

    // 2. Встроенный ассет (первый запуск)
    final assetPath = _assets[country];
    if (assetPath != null) {
      try {
        final content = await rootBundle.loadString(assetPath);
        if (content.isNotEmpty) return content;
      } catch (_) {}
    }

    return '';
  }

  /// Фоновое обновление из сети с ETag-поддержкой.
  static Future<void> updateInBackground(String networkUrl) async {
    try {
      final body = await _downloadWithETag(networkUrl);
      if (body != null) {
        final country = networkUrl.contains('by_') ? 'belarus' : 'russia';
        await _saveToCache(country, body);
        LogService.info(LogService.iptv, 'IPTV: плейлист обновлён из сети');
      }
    } catch (e) {
      LogService.warn(LogService.iptv, 'IPTV: не удалось обновить из сети', e);
    }
  }

  /// Принудительное обновление (по кнопке «Обновить»).
  static Future<String?> forceUpdate(String networkUrl) async {
    try {
      final body = await _downloadWithETag(networkUrl, force: true);
      if (body != null) {
        final country = networkUrl.contains('by_') ? 'belarus' : 'russia';
        await _saveToCache(country, body);
        return body;
      }
    } catch (e) {
      LogService.error(LogService.iptv, 'IPTV: ошибка обновления', e);
    }
    return null;
  }

  static Future<String?> _downloadWithETag(String url, {bool force = false}) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 25);
    client.badCertificateCallback = (_, __, ___) => true;
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'VakhtovikPlayer/0.2 IPTV');
      // ETag: если файл не менялся, получим 304 и не будем качать
      if (!force) {
        req.headers.set(HttpHeaders.cacheControlHeader, 'max-age=86400');
      }
      final resp = await req.close().timeout(const Duration(seconds: 35));
      if (resp.statusCode == 304) return null; // не изменился
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      return utf8.decoder.bind(resp).join();
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _saveToCache(String country, String content) async {
    try {
      final dir = Directory(_cacheDir());
      if (!await dir.exists()) await dir.create(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}${country}_cached.m3u');
      await file.writeAsString(content);
    } catch (_) {}
  }

  static Future<void> clearCache() async {
    try {
      final dir = Directory(_cacheDir());
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}
