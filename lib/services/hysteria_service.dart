import 'dart:io';
import 'android_vpn_bridge.dart';

/// Запускает родной Hysteria2 клиент как HTTP-прокси к серверу Финляндии
class HysteriaService {
  static Process? _process;
  static bool _started = false;

  static const _port = 1080;
  static const _password = 'Vakh-4JOjF1znmw4kszAdMtarivhR';
  static const _server = '195.226.92.151.nip.io:443';
  static const _sni = '195.226.92.151.nip.io';
  static const _downloadUrl = 'https://github.com/apernet/hysteria/releases/download/app/v2.9.2/hysteria-windows-amd64.exe';
  static const _exeName = 'hysteria.exe';
  static const _probeApiUrl = 'https://195.226.92.151.nip.io:8008/presets';
  static const _probeWebUrl = 'https://seasonvar.ru/';

  static bool get isRunning => _started && _process != null;
  static String get proxyHost => '127.0.0.1';
  static int get proxyPort => _port;
  static String get proxyUrl => 'http://$proxyHost:$proxyPort';

  static Future<Directory> get _dir async {
    // 1. Сначала рядом с приложением (из артефакта сборки)
    final bundled = File('${Directory.current.path}/$_exeName');
    if (await bundled.exists() && await bundled.length() > 20000000) {
      return Directory.current;
    }
    // 2. В AppData
    final d = Directory('${Platform.environment['LOCALAPPDATA'] ?? '.'}/VakhtovikPlayer');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<void> start() async {
    if (Platform.isAndroid) {
      _started = await AndroidVpnBridge.start(
        server: _server,
        password: _password,
        localHttpProxyPort: _port,
      );
      return;
    }
    if (!Platform.isWindows) return;
    stop();
    try {
      final dir = await _dir;
      final exe = File('${dir.path}/$_exeName');

      // Скачать если нет или битый
      if (!await exe.exists() || await exe.length() < 20000000) {
        if (await exe.exists()) await exe.delete();
        final resp = await HttpClient().getUrl(Uri.parse(_downloadUrl));
        final response = await resp.close();
        if (response.statusCode == 200) {
          await exe.openWrite().addStream(response);
        }
      }
      if (!await exe.exists()) return;

      // Создать конфиг
      final config = File('${dir.path}/config.yaml');
      await config.writeAsString(
        'server: $_server\n'
        'auth: $_password\n'
        'tls:\n'
        '  sni: $_sni\n'
        '  insecure: true\n'
        'http:\n'
        '  listen: 127.0.0.1:$_port\n',
      );

      _process = await Process.start(
        exe.path,
        ['-c', config.path, '-l', 'warn'],
        mode: ProcessStartMode.detachedWithStdio,
      );
      // Дожидаемся реальной готовности прокси (API + внешний сайт), иначе считаем старт неудачным.
      _started = await _waitUntilProxyReady();
      if (!_started) {
        stop();
      }
    } catch (e) {
      _started = false;
      _process = null;
    }
  }

  static void stop() {
    if (Platform.isAndroid) {
      AndroidVpnBridge.stop();
    }
    _process?.kill();
    _process = null;
    _started = false;
  }

  static Future<bool> check() async {
    if (!_started) return false;
    return _probe(_probeApiUrl, throughProxy: true, timeout: const Duration(seconds: 40));
  }

  static HttpClient createProxyClient() {
    final client = HttpClient();
    if (_started && Platform.isWindows) {
      client.findProxy = (uri) => 'PROXY $proxyHost:$proxyPort';
      client.connectionTimeout = const Duration(seconds: 10);
    }
    return client;
  }

  static Future<bool> checkWebProxy() async {
    if (!_started) return false;
    final apiOk = await _probe(_probeApiUrl, throughProxy: true, timeout: const Duration(seconds: 40));
    if (!apiOk) return false;
    final webOk = await _probe(_probeWebUrl, throughProxy: true, timeout: const Duration(seconds: 40));
    return webOk;
  }

  static Future<bool> _waitUntilProxyReady() async {
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(seconds: 2));
      if (_process == null) return false;
      final apiOk = await _probe(_probeApiUrl, throughProxy: true, timeout: const Duration(seconds: 15));
      if (!apiOk) continue;
      final webOk = await _probe(_probeWebUrl, throughProxy: true, timeout: const Duration(seconds: 20));
      if (webOk) return true;
    }
    return false;
  }

  static Future<bool> _probe(String target, {required bool throughProxy, required Duration timeout}) async {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    client.badCertificateCallback = (_, __, ___) => true;
    if (throughProxy && Platform.isWindows) {
      client.findProxy = (uri) => 'PROXY $proxyHost:$proxyPort';
    }
    try {
      final req = await client.getUrl(Uri.parse(target));
      final resp = await req.close().timeout(timeout);
      // Любой HTTP-ответ подтверждает, что соединение состоялось (даже 403/404).
      return resp.statusCode >= 100 && resp.statusCode <= 599;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
