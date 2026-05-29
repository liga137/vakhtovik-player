package com.vakhtovik.flutter_app

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.VpnService
import android.os.IBinder
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter-плагин для управления sing-box VPN.
 * Регистрирует MethodChannel "vakhtovik/singbox" и запускает VakhtovikVpnService.
 */
class VpnPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var pendingResult: MethodChannel.Result? = null
    private val VPN_REQUEST_CODE = 2424

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "vakhtovik/singbox")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    // ── ActivityAware ──────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener { requestCode, resultCode, data ->
            if (requestCode == VPN_REQUEST_CODE) {
                val result = pendingResult
                pendingResult = null
                if (resultCode == Activity.RESULT_OK) {
                    result?.success(true)
                } else {
                    result?.error("PERMISSION_DENIED", "VPN permission not granted", null)
                }
                return@addActivityResultListener true
            }
            false
        }
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    // ── MethodCallHandler ──────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(true) // vpn_service.kt always available on Android
            "connect" -> handleConnect(call, result)
            "disconnect" -> handleDisconnect(result)
            else -> result.notImplemented()
        }
    }

    private fun handleConnect(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config") ?: ""
        if (config.isEmpty()) {
            result.error("NO_CONFIG", "Config is empty", null)
            return
        }

        val act = activity ?: run {
            result.error("NO_ACTIVITY", "Activity not attached", null)
            return
        }

        // Запрашиваем разрешение на VPN (обязательно для VpnService.prepare)
        val intent = VpnService.prepare(act)
        if (intent != null) {
            pendingResult = result
            act.startActivityForResult(intent, VPN_REQUEST_CODE)
            return
        }

        // Разрешение уже есть — запускаем сервис
        startVpnService(act, config)
        result.success(true)
    }

    private fun handleDisconnect(result: MethodChannel.Result) {
        val act = activity
        if (act != null) {
            val intent = Intent(act, VakhtovikVpnService::class.java).apply {
                action = VakhtovikVpnService.ACTION_DISCONNECT
            }
            act.startService(intent)
        }
        result.success(true)
    }

    private fun startVpnService(context: Context, config: String) {
        val intent = Intent(context, VakhtovikVpnService::class.java).apply {
            action = VakhtovikVpnService.ACTION_CONNECT
            putExtra(VakhtovikVpnService.EXTRA_CONFIG, config)
        }
        context.startForegroundService(intent)
    }
}
