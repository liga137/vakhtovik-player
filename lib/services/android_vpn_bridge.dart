import 'package:flutter/services.dart';

/// Мост к Android VpnService (пока минимальный контракт).
class AndroidVpnBridge {
  static const MethodChannel _channel = MethodChannel('vakhtovik/vpn');

  static Future<bool> isSupported() async {
    try {
      final ok = await _channel.invokeMethod<bool>('isSupported');
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> start({
    required String server,
    required String password,
    required int localHttpProxyPort,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('start', {
        'server': server,
        'password': password,
        'localHttpProxyPort': localHttpProxyPort,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
