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

    // Android: MethodChannel → VpnPlugin.kt → VakhtovikVpnService
    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod('connect', {'config': configJson});
        if (result == true) {
          // Очищаем старый статус
          try {
            final dir = await getApplicationSupportDirectory();
            final file = File('${dir.path}/vpn_status.txt');
            if (await file.exists()) await file.delete();
          } catch (_) {}

          // Ждём пока сервис запишет статус
          for (int i = 0; i < 20; i++) {
            await Future.delayed(const Duration(milliseconds: 500));
            try {
              final dir = await getApplicationSupportDirectory();
              final file = File('${dir.path}/vpn_status.txt');
              if (await file.exists()) {
                final status = await file.readAsString();
                if (status.startsWith('Error:')) {
                  _lastError = status;
                  _setState(VpnState.error);
                  return;
                } else if (status == 'Connected') {
                  _setState(VpnState.connected);
                  return;
                }
              }
            } catch (_) {}
          }
          // Если файл не появился, считаем что подключено (fallback)
          _setState(VpnState.connected);
        } else {
          _lastError = 'VPN permission denied';
          _setState(VpnState.error);
        }
      } catch (e) {
        _lastError = 'Android VPN error: $e';
        _setState(VpnState.error);
      }
      return;
    }

    // Windows: sing-box.exe

    await saveConfig(configJson);
    await disconnect();

    // Найти/извлечь sing-box
    String exePath;
    final exeDir = Directory(Platform.resolvedExecutable).parent.path;
    exePath = '$exeDir\\sing-box.exe';

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
    if (Platform.isAndroid) {
      try { await _channel.invokeMethod('disconnect'); } catch (_) {}
      _setState(VpnState.disconnected);
      return;
    }
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
    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod<bool>('isAvailable');
        return result ?? false;
      } catch (_) {
        return false;
      }
    }
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
        {'tag': 'dns-proxy', 'type': 'tls', 'server': '1.1.1.1', 'detour': 'proxy'},
        {'tag': 'dns-local', 'type': 'local', 'detour': 'direct'},
      ],
    },
    'inbounds': [
      if (Platform.isWindows) {
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': 'BeaverVPN',
        'address': ['172.19.0.1/30'],
        'auto_route': true,
        'strict_route': true,
        'stack': 'system',
        'mtu': 1360,
      } else {
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': 'tun0',
        'address': ['172.19.0.1/30'],
        'auto_route': false,
        'strict_route': false,
        'stack': 'system',
        'mtu': 1500,
      }
    ],
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
        {'type': 'dns', 'tag': 'dns-out'},
      ],
    'route': {
      'default_domain_resolver': 'dns-local',
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
