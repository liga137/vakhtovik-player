import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

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

    // Validate
    try { json.decode(configJson); }
    catch (e) { _lastError = 'Invalid JSON: $e'; _setState(VpnState.error); return; }

    // Save config
    await saveConfig(configJson);

    // Kill old process
    await disconnect();

    // Find sing-box.exe
    final exeDir = Directory(Platform.resolvedExecutable).parent.path;
    final exePath = '$exeDir\\sing-box.exe';
    if (!File(exePath).existsSync()) {
      _lastError = 'sing-box.exe не найден в $exeDir';
      _setState(VpnState.error);
      return;
    }

    // Start process
    try {
      _process = await Process.start(
        exePath,
        ['run', '-c', configPath],
        workingDirectory: exeDir,
        mode: ProcessStartMode.normal,
      );

      // Check if it dies immediately
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
          // Still running — OK
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
        {'tag': 'remote-dns', 'address': '8.8.8.8', 'detour': 'proxy'},
        {'tag': 'local-dns', 'address': 'local', 'detour': 'direct'},
      ],
      'independent_cache': true,
    },
    'inbounds': [{
      'type': 'tun',
      'tag': 'tun-in',
      'interface_name': 'BeaverVPN',
      'inet4_address': '172.19.0.1/30',
      'auto_route': true,
      'strict_route': true,
      'stack': 'system',
      'mtu': 1360,
      'sniff': true,
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
      {'type': 'block', 'tag': 'block'},
      {'type': 'dns', 'tag': 'dns-out'},
    ],
    'route': {
      'rules': [
        {'protocol': 'dns', 'outbound': 'dns-out'},
        {'ip_is_private': true, 'outbound': 'direct'},
      ],
      'auto_detect_interface': true,
    },
  });

  void dispose() => _stateController.close();
}
