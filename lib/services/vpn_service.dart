import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

enum VpnState { disconnected, connecting, connected, disconnecting, error }

class VpnService {
  static const _channel = MethodChannel('vakhtovik/singbox');
  static final VpnService instance = VpnService._();
  factory VpnService() => instance;

  Process? _process;
  final _stateController = StreamController<VpnState>.broadcast();
  Stream<VpnState> get stateStream => _stateController.stream;

  VpnState _state = VpnState.disconnected;
  VpnState get state => _state;
  String _lastError = '';
  String get lastError => _lastError;

  VpnService._() {
    _channel.setMethodCallHandler(_handleMethod);
  }

  /// Извлечь sing-box из assets на Android (вызвать при старте приложения)
  static Future<void> bootstrapAndroid() async {
    if (!Platform.isAndroid) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final exe = File('${dir.path}/sing-box');
      if (await exe.exists()) return; // уже извлечён
      final data = await rootBundle.load('assets/sing-box');
      await exe.writeAsBytes(data.buffer.asUint8List());
      await Process.run('chmod', ['+x', exe.path]);
      print('[VPN] sing-box extracted to ${exe.path}');
    } catch (e) {
      print('[VPN] bootstrap failed: $e');
    }
  }

  // ── Config ───────────────────────────────────────────────

  static String get configDir {
    if (Platform.isWindows) {
      return '${Platform.environment['LOCALAPPDATA']}\\VakhtovikPlayer';
    }
    return '${Platform.environment['HOME'] ?? '/tmp'}/.vakhtovik';
  }

  static String get configPath => '$configDir\\vpn_config.json';

  static Future<String> loadConfig() async {
    try {
      final f = File(configPath);
      if (await f.exists()) return await f.readAsString();
    } catch (_) {}
    return _defaultConfig();
  }

  static Future<void> saveConfig(String json) async {
    final f = File(configPath);
    await f.parent.create(recursive: true);
    await f.writeAsString(json);
  }

  // ── Connect / Disconnect ─────────────────────────────────

  Future<void> connect(String configJson) async {
    if (_state == VpnState.connecting || _state == VpnState.connected) return;
    _setState(VpnState.connecting);
    _lastError = '';

    try { json.decode(configJson); }
    catch (e) { _lastError = 'Invalid JSON: $e'; _setState(VpnState.error); return; }

    // На Android заменяем TUN на SOCKS5
    if (Platform.isAndroid) {
      final cfg = json.decode(configJson) as Map<String, dynamic>;
      cfg['inbounds'] = [
        {
          'type': 'mixed',
          'tag': 'mixed-in',
          'listen': '127.0.0.1',
          'listen_port': 1080,
        }
      ];
      configJson = json.encode(cfg);
    }

    await saveConfig(configJson);
    await disconnect();

    // Найти/извлечь sing-box
    String exePath;
    if (Platform.isAndroid) {
      await bootstrapAndroid();
      final dir = await getApplicationDocumentsDirectory();
      exePath = '${dir.path}/sing-box';
    } else {
      final exeDir = Directory(Platform.resolvedExecutable).parent.path;
      exePath = '$exeDir\\sing-box.exe';
    }

    if (!File(exePath).existsSync()) {
      _lastError = 'sing-box не найден: $exePath';
      _setState(VpnState.error);
      return;
    }

    try {
      // Android: SOCKS5-only режим (без TUN)
      final args = Platform.isAndroid
          ? ['run', '-c', configPath, '--disable-color']
          : ['run', '-c', configPath];
      _process = await Process.start(
        exePath, args,
        workingDirectory: Directory(exePath).parent.path,
        mode: ProcessStartMode.normal,
      );

      _process!.stdout.transform(utf8.decoder).listen((data) {
        print('[sing-box] $data');
      });
      _process!.stderr.transform(utf8.decoder).listen((data) {
        print('[sing-box ERR] $data');
      });

      Future.delayed(const Duration(seconds: 3), () async {
        if (_process == null) return;
        try {
          if (await _process!.exitCode.timeout(const Duration(milliseconds: 100)) != null) {
            _lastError = 'sing-box упал при запуске';
            _setState(VpnState.error);
            _process = null;
          } else {
            _setState(VpnState.connected);
          }
        } catch (_) {
          _setState(VpnState.connected);
        }
      });
    } catch (e) {
      _lastError = 'Ошибка запуска: $e';
      _setState(VpnState.error);
    }
  }

  Future<void> disconnect() async {
    _setState(VpnState.disconnecting);
    try {
      _process?.kill(ProcessSignal.sigterm);
      await _process?.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      _process?.kill(ProcessSignal.sigkill);
    }
    _process = null;
    _setState(VpnState.disconnected);
  }

  Future<bool> isAvailable() async {
    if (Platform.isAndroid) return true; // sing-box bundled in assets
    final exeDir = Directory(Platform.resolvedExecutable).parent.path;
    return File('$exeDir\\sing-box.exe').existsSync();
  }

  // ── Internal ─────────────────────────────────────────────

  void _setState(VpnState s) {
    _state = s;
    _stateController.add(s);
  }

  Future<void> _handleMethod(MethodCall call) async {}

  static String _defaultConfig() => json.encode({
    'log': {'level': 'info', 'timestamp': true},
    'dns': {
      'servers': [
        {'tag': 'dns-remote', 'address': 'tls://1.1.1.1', 'detour': 'proxy'},
      ],
      'final': 'dns-remote',
    },
    'inbounds': [{
      'type': 'tun',
      'tag': 'tun-in',
      'interface_name': 'BeaverVPN',
      'address': ['172.19.0.1/30'],
      'auto_route': true,
      'strict_route': true,
      'stack': 'system',
      'mtu': 1360,
    }],
    'outbounds': [
      {
        'type': 'hysteria2',
        'tag': 'proxy',
        'server': '195.226.92.151',
        'server_port': 443,
        'password': 'Vakh-37PWkJ6RvQfC95Rsnw8jzpP0',
        'tls': {
          'enabled': true,
          'server_name': '195.226.92.151.nip.io',
          'insecure': false,
        },
      },
      {'type': 'direct', 'tag': 'direct'},
    ],
    'route': {
      'rules': [
        {'port': 53, 'action': 'hijack-dns'},
        {'protocol': 'dns', 'action': 'hijack-dns'},
        {'ip_is_private': true, 'outbound': 'direct'},
        {'ip_cidr': ['195.226.92.151/32'], 'outbound': 'direct'},
      ],
      'final': 'proxy',
      'auto_detect_interface': true,
    },
  });

  void dispose() => _stateController.close();
}
