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
      // Ждём и проверяем что процесс жив
      await Future.delayed(const Duration(seconds: 5));
      _started = true;
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
    try {
      final client = HttpClient();
      if (_started && Platform.isWindows) {
        client.findProxy = (uri) => 'PROXY $proxyHost:$proxyPort';
      }
      client.connectionTimeout = const Duration(seconds: 30);
      final req = await client.getUrl(Uri.parse('https://195.226.92.151.nip.io:8008/presets'));
      final resp = await req.close().timeout(const Duration(seconds: 40));
      final ok = resp.statusCode == 200;
      return ok;
    } catch (_) {
      return false;
    }
  }

  static HttpClient createProxyClient() {
    final client = HttpClient();
    if (_started && Platform.isWindows) {
      client.findProxy = (uri) => 'PROXY $proxyHost:$proxyPort';
      client.connectionTimeout = const Duration(seconds: 10);
    }
    return client;
  }
}
