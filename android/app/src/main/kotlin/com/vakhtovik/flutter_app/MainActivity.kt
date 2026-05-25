package com.vakhtovik.flutter_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val vpnChannel = "vakhtovik/vpn"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, vpnChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(true)
                    "start" -> {
                        // TODO: здесь подключается Android VpnService + ARM hysteria binary.
                        // Сейчас оставляем безопасный stub, чтобы клиент не падал.
                        result.success(false)
                    }
                    "stop" -> result.success(true)
                    else -> result.notImplemented()
                }
            }
    }
}
