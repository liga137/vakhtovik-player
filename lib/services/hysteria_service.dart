import 'dart:io';

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

  static Future<File> _findOrDownload() async {
    final dir = Directory('${Platform.environment['LOCALAPPDATA'] ?? '.'}/VakhtovikPlayer');
    if (!await dir.exists()) await dir.create(recursive: true);
    final exe = File('${dir.path}/$_exeName');
    if (await exe.exists()) return exe;

    // Скачать
    final resp = await HttpClient().getUrl(Uri.parse(_downloadUrl));
    final response = await resp.close();
    if (response.statusCode != 200) throw Exception('download failed');
    await exe.openWrite().addStream(response);
    return exe;
  }

  static Future<void> start() async {
    if (!Platform.isWindows) return;
    stop();
    try {
      final exe = await _findOrDownload();
      _process = await Process.start(exe.path, [
        'client',
        '--server', _server,
        '--auth', _password,
        '--tls-sni', _sni,
        '--tls-insecure',
        '--http-listen', '127.0.0.1:$_port',
        '--socks5-listen', '127.0.0.1:${_port + 1}',
        '--log-level', 'warn',
      ], mode: ProcessStartMode.detachedWithStdio);
      await Future.delayed(const Duration(seconds: 5));
      if (_process != null) _started = true;
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

  static Future<bool> check() async {
    if (!_started || _process == null) return false;
    try {
      final client = HttpClient();
      client.findProxy = (uri) => 'PROXY $proxyHost:$proxyPort';
      client.connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(Uri.parse('http://195.226.92.151.nip.io:8008/presets'));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static HttpClient createProxyClient() {
    final client = HttpClient();
    if (_started && _process != null) {
      client.findProxy = (uri) => 'PROXY $proxyHost:$proxyPort';
      client.connectionTimeout = const Duration(seconds: 8);
    }
    return client;
  }
}
