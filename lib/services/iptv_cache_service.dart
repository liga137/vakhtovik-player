import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'log_service.dart';

/// Кэш-сервис IPTV плейлистов: сначала встроенный ассет, потом сеть с ETag.
class IptvCacheService {
  static const _assets = <String, String>{
    'belarus': 'assets/iptv/belarus.m3u',
  };

  static final _cacheManager = CacheManager(Config(
    'iptv_playlists',
    stalePeriod: const Duration(hours: 24),
    maxNrOfCacheObjects: 5,
    repo: JsonCacheInfoRepository(databaseName: 'iptv_cache'),
    fileService: HttpFileService(),
  ));

  /// Загружает плейлист: сначала из кэша, если нет — из ассета.
  /// Возвращает содержимое M3U как строку.
  static Future<String> loadPlaylist(String country,
      {required String networkUrl}) async {
    // 1. Пробуем кэш
    try {
      final cached = await _cacheManager.getFileFromMemory(networkUrl);
      if (cached != null) {
        return String.fromCharCodes(cached.file.readAsBytesSync());
      }
    } catch (_) {}

    // 2. Пробуем файловый кэш
    try {
      final fileInfo = await _cacheManager.getFileFromCache(networkUrl);
      if (fileInfo != null) {
        final content = await fileInfo.file.readAsString();
        if (content.isNotEmpty) return content;
      }
    } catch (_) {}

    // 3. Встроенный ассет (первый запуск)
    final assetPath = _assets[country];
    if (assetPath != null) {
      try {
        final content = await rootBundle.loadString(assetPath);
        if (content.isNotEmpty) {
          // Сохраняем в локальный кэш
          await _saveLocal(assetPath, content);
          return content;
        }
      } catch (_) {}
    }

    // 4. Пробуем локальный файл (из прошлых сохранений)
    try {
      final local = await _readLocal(assetPath ?? 'iptv_$country.m3u');
      if (local != null && local.isNotEmpty) return local;
    } catch (_) {}

    return '';
  }

  /// Фоновое обновление из сети (stale-while-revalidate).
  static Future<void> updateInBackground(String networkUrl) async {
    try {
      final file = await _cacheManager.getSingleFile(
        networkUrl,
        headers: {'User-Agent': 'VakhtovikPlayer/0.2 IPTV'},
      );
      if (await file.exists()) {
        LogService.info(LogService.iptv, 'IPTV: плейлист обновлён из сети');
      }
    } catch (e) {
      LogService.warn(LogService.iptv, 'IPTV: не удалось обновить из сети', e);
    }
  }

  /// Принудительное обновление (по кнопке «Обновить»).
  static Future<String?> forceUpdate(String networkUrl) async {
    try {
      await _cacheManager.emptyCache();
      final file = await _cacheManager.getSingleFile(
        networkUrl,
        headers: {'User-Agent': 'VakhtovikPlayer/0.2 IPTV'},
      );
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e) {
      LogService.error(LogService.iptv, 'IPTV: ошибка принудительного обновления', e);
    }
    return null;
  }

  static Future<void> _saveLocal(String key, String content) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/iptv_cache/${key.replaceAll('/', '_')}');
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    } catch (_) {}
  }

  static Future<String?> _readLocal(String key) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/iptv_cache/${key.replaceAll('/', '_')}');
      if (await file.exists()) return await file.readAsString();
    } catch (_) {}
    return null;
  }

  /// Очистить весь кэш.
  static Future<void> clearCache() async {
    await _cacheManager.emptyCache();
  }
}
