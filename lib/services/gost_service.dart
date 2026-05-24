import 'dart:io';
import 'package:http/http.dart' as http;

/// Запускает GOST HTTP-прокси для тоннеля к серверу Финляндии через Hysteria2
class GostService {
  static Process? _process;
  static bool _started = false;

  static const _port = 1080;
  static const _password = 'Vakh-4JOjF1znmw4kszAdMtarivhR';
  static const _server = '195.226.92.151.nip.io';
  static const _serverPort = 443;
  static const _gostUrl = 'https://github.com/go-gost/gost/releases/download/v3.2.6/gost_3.2.6_windows_amd64.zip';

  static bool get isRunning => _started && _process != null;
  static String get proxyHost => '127.0.0.1';
  static int get proxyPort => _port;
  static String get proxyUrl => 'http://$proxyHost:$proxyPort';

  static Future<File> _findOrDownload() async {
    // 1. Рядом с .exe (из артефакта сборки)
    final bundled = File('${Directory.current.path}/gost.exe');
    if (await bundled.exists()) return bundled;

    // 2. В AppData (уже скачан ранее)
    final dir = Directory('${Platform.environment['LOCALAPPDATA'] ?? '.'}/VakhtovikPlayer');
    final exe = File('${dir.path}/gost.exe');
    if (await exe.exists()) return exe;

    // 3. Скачать с GitHub (запасной вариант)
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      final resp = await http.get(Uri.parse(_gostUrl));
      if (resp.statusCode != 200) throw Exception('download failed');
      final tmp = File('${dir.path}/gost.zip');
      await tmp.writeAsBytes(resp.bodyBytes);
      await Process.run('powershell', [
        '-c', 'Expand-Archive -Force -Path "${tmp.path}" -DestinationPath "${dir.path}"'
      ]);
      await tmp.delete();
      if (await exe.exists()) return exe;
    } catch (_) {}
    throw Exception('gost.exe not found');
  }

  static Future<void> start() async {
    if (!Platform.isWindows) return;
    stop();
    try {
      final exe = await _findOrDownload();
      _process = await Process.start(
        exe.path,
        [
          '-L', 'http://127.0.0.1:$_port',
          '-F', 'hysteria2://$_password@$_server:$_serverPort?sni=$_server&insecure=1',
        ],
        mode: ProcessStartMode.detachedWithStdio,
      );
      // Ждём и проверяем что прокси отвечает
      await Future.delayed(const Duration(seconds: 5));
      if (_process != null) {
        _started = true;
      }
    } catch (e) {
      _started = false;
      _process = null;
    }
  }

  static void stop() {
    _process?.kill();
    _process = null;
    _started = false;
  }

  /// Проверяет жив ли прокси (стучится в сам прокси)
  static Future<bool> check() async {
    if (!_started || _process == null) return false;
    try {
      final client = HttpClient();
      client.findProxy = (uri) => 'PROXY $proxyHost:$proxyPort';
      client.connectionTimeout = const Duration(seconds: 4);
      final req = await client.getUrl(Uri.parse('http://195.226.92.151.nip.io:8008/presets'));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      _started = false;
      return false;
    }
  }

  /// HttpClient через локальный HTTP-прокси (если GOST запущен), иначе напрямую
  static HttpClient createProxyClient() {
    final client = HttpClient();
    if (_started && _process != null) {
      client.findProxy = (uri) => 'PROXY $proxyHost:$proxyPort';
      // Таймаут чтобы не висло при мёртвом прокси
      client.connectionTimeout = const Duration(seconds: 8);
    }
    return client;
  }
}
