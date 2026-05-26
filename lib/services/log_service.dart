import 'dart:io';
import 'package:flutter/foundation.dart';

/// Единый лог ошибок для отладки на слабом интернете.
///
/// Пишет в файл `vakhtovik_error.log` в папке логов приложения.
/// Формат строки:
///   [2026-05-26 14:30:00.123] [ERROR] [BROWSER] Filmix: описание ошибки
///
/// Использование:
///   LogService.error(LogSource.browser, 'Filmix: не найден video url');
///   LogService.warn(LogSource.api, 'transcode: попытка 2/3');
class LogService {
  LogService._();

  // ── Категории источников ──
  static const browser = 'BROWSER';
  static const api = 'API';
  static const player = 'PLAYER';
  static const youtube = 'YOUTUBE';
  static const iptv = 'IPTV';
  static const filmix = 'FILMIX';
  static const seasonvar = 'SEASONVAR';
  static const general = 'GENERAL';

  static IOSink? _sink;

  /// Путь к файлу лога.
  static String get logPath {
    if (Platform.isWindows) {
      final base = Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'] ??
          '.';
      return '$base\\VakhtovikPlayer\\logs\\vakhtovik_error.log';
    }
    // Android / Linux / macOS
    return '${Directory.systemTemp.path}/vakhtovik_player/vakhtovik_error.log';
  }

  static Future<IOSink> _getSink() async {
    if (_sink != null) return _sink!;
    final file = File(logPath);
    final dir = file.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _sink = file.openWrite(mode: FileMode.append);
    return _sink!;
  }

  static Future<void> _write(String level, String source, String message,
      [Object? error, StackTrace? stack]) async {
    final ts = DateTime.now().toIso8601String().replaceFirst('T', ' ').substring(0, 23);
    final sb = StringBuffer();
    sb.write('[$ts] [$level] [$source] $message');
    if (error != null) {
      sb.write(' | $error');
    }
    if (stack != null) {
      sb.write('\n$stack');
    }
    final line = '$sb\n';

    // Всегда пишем в консоль тоже (для flutter run)
    if (level == 'ERROR') {
      debugPrint(line.trimRight());
    }

    try {
      final sink = await _getSink();
      // ignore: avoid_dynamic_calls — безопасно под блокировкой
      sink.write(line);
      await sink.flush();
    } catch (_) {
      // Не можем писать в лог — хотя бы в консоль
      debugPrint('LogService: не удалось записать в файл: $_');
    }
  }

  /// Ошибка — то, что ломает функциональность.
  static Future<void> error(String source, String message,
      [Object? error, StackTrace? stack]) async {
    await _write('ERROR', source, message, error, stack);
  }

  /// Предупреждение — что-то нештатное, но приложение продолжает работу.
  static Future<void> warn(String source, String message,
      [Object? error]) async {
    await _write('WARN', source, message, error);
  }

  /// Информация — штатные события (старт/стоп/переключение).
  static Future<void> info(String source, String message) async {
    await _write('INFO', source, message);
  }

  /// Прочитать весь лог как строку.
  static Future<String> readLog() async {
    try {
      final file = File(logPath);
      if (!await file.exists()) return '(лог пуст)';
      final content = await file.readAsString();
      return content.isEmpty ? '(лог пуст)' : content;
    } catch (e) {
      return 'Ошибка чтения лога: $e';
    }
  }

  /// Очистить лог.
  static Future<void> clearLog() async {
    try {
      await _sink?.close();
      _sink = null;
      final file = File(logPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('LogService: ошибка очистки лога: $e');
    }
  }

  /// Закрыть поток (вызвать при завершении приложения).
  static Future<void> dispose() async {
    await _sink?.close();
    _sink = null;
  }
}
