import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

/// Состояния VPN-подключения
enum VpnState { disconnected, connecting, connected, disconnecting, error }

/// Сервис управления sing-box VPN через MethodChannel.
///
/// [Android] — MyVpnService.kt (Kotlin + libbox.aar)
/// [Windows] — vpn_plugin.cpp (Wintun + libbox.dll)
class VpnService {
  static const _channel = MethodChannel('vakhtovik/singbox');

  static final VpnService instance = VpnService._();
  factory VpnService() => instance;
  VpnService._() {
    _channel.setMethodCallHandler(_handleMethod);
  }

  final _stateController = StreamController<VpnState>.broadcast();
  Stream<VpnState> get stateStream => _stateController.stream;

  VpnState _state = VpnState.disconnected;
  VpnState get state => _state;

  String _lastError = '';
  String get lastError => _lastError;

  // ── Управление конфигом ────────────────────────────────────

  static String get configPath {
    if (Platform.isWindows) {
      final appData = Platform.environment['LOCALAPPDATA'] ?? '.';
      return '$appData\\VakhtovikPlayer\\singbox_config.json';
    }
    return '/data/data/com.example.vakhtovik_player/files/singbox_config.json';
  }

  static Future<String> loadConfig() async {
    try {
      final f = File(configPath);
      if (await f.exists()) return await f.readAsString();
    } catch (_) {}
    return _defaultConfig();
  }

  static Future<void> saveConfig(String jsonText) async {
    final f = File(configPath);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonText);
  }

  // ── Подключение/отключение ─────────────────────────────────

  Future<void> connect(String configJson) async {
    if (_state == VpnState.connecting || _state == VpnState.connected) return;

    _setState(VpnState.connecting);
    _lastError = '';

    // Валидация JSON
    try { json.decode(configJson); }
    catch (e) {
      _lastError = 'Некорректный JSON: $e';
      _setState(VpnState.error);
      return;
    }

    try {
      await _channel.invokeMethod('connect', {'config': configJson});
    } on MissingPluginException {
      _lastError = 'VPN-плагин не собран для ${Platform.operatingSystem}';
      _setState(VpnState.error);
    } catch (e) {
      _lastError = 'Ошибка VPN: $e';
      _setState(VpnState.error);
    }
  }

  Future<void> disconnect() async {
    if (_state != VpnState.connected && _state != VpnState.error) return;
    _setState(VpnState.disconnecting);
    try {
      await _channel.invokeMethod('disconnect');
    } on MissingPluginException {
      // плагина нет — считаем отключённым
    } catch (e) {
      _lastError = 'Ошибка отключения: $e';
    }
    _setState(VpnState.disconnected);
  }

  /// Есть ли нативный плагин на этой платформе.
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  // ── Внутреннее ────────────────────────────────────────────

  void _setState(VpnState s) {
    _state = s;
    _stateController.add(s);
  }

  Future<void> _handleMethod(MethodCall call) async {
    switch (call.method) {
      case 'onStatusChanged':
        final s = call.arguments?.toString() ?? '';
        if (s == 'Connected') _setState(VpnState.connected);
        else if (s == 'Disconnected') _setState(VpnState.disconnected);
        else if (s == 'Error') {
          _lastError = 'Ошибка VPN-сервиса';
          _setState(VpnState.error);
        }
    }
  }

  static String _defaultConfig() => json.encode({
    'log': {'level': 'info'},
    'inbounds': [{
      'type': 'tun',
      'interface_name': 'sing-box',
      'inet4_address': '172.19.0.1/30',
      'mtu': 1500,
      'auto_route': true,
      'strict_route': true,
      'stack': 'system',
    }],
    'outbounds': [{
      'type': 'hysteria2',
      'server': '195.226.92.151',
      'server_port': 443,
      'password': 'Vakh-37PWkJ6RcQfC95Rsnw8jzpP0',
      'tls': {
        'enabled': true,
        'server_name': '195.226.92.151.nip.io',
        'insecure': false,
      },
      'congestion_control': 'brutal',
      'up_mbps': 30,
      'down_mbps': 100,
    }],
  });

  void dispose() => _stateController.close();
}
