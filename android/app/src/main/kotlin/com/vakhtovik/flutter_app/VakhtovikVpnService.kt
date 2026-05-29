package com.vakhtovik.flutter_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat

/**
 * Android VPN-сервис поверх sing-box.
 *
 * Принимает JSON-конфиг через Intent extra "config",
 * создаёт TUN-интерфейс и передаёт его в libbox.
 *
 * Требует libbox.aar в android/app/libs/ (собирается через gomobile).
 */
class VakhtovikVpnService : VpnService() {

    companion object {
        const val ACTION_CONNECT = "com.vakhtovik.flutter_app.VPN_CONNECT"
        const val ACTION_DISCONNECT = "com.vakhtovik.flutter_app.VPN_DISCONNECT"
        const val EXTRA_CONFIG = "config"
        const val NOTIFICATION_ID = 4242
        const val CHANNEL_ID = "vakhtovik_vpn"
    }

    // libbox native interface (доступен после добавления libbox.aar)
    // import libbox.BoxService
    // import libbox.Instance
    // private var instance: libbox.Instance? = null
    private var tunFd: ParcelFileDescriptor? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CONNECT -> {
                val configJson = intent.getStringExtra(EXTRA_CONFIG) ?: ""
                startVpn(configJson)
            }
            ACTION_DISCONNECT -> {
                stopVpn()
                stopSelf()
            }
        }
        return START_STICKY
    }

    private fun startVpn(configJson: String) {
        if (configJson.isEmpty()) return

        // 1. Создаём TUN через VpnService.Builder
        val builder = Builder()
            .setSession("Vakhtovik VPN")
            .setMtu(1500)
            .addAddress("172.19.0.1", 30)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("1.1.1.1")
            .addDnsServer("8.8.8.8")
            .setBlocking(true)

        // Исключаем сам VPN-сервер из туннеля (чтобы не было петли)
        // extractServerIp(configJson)?.let { builder.addDisallowedApplication(packageName) }

        tunFd = builder.establish()
        if (tunFd == null) {
            sendStatus("Error: TUN creation failed")
            return
        }

        // 2. Запускаем sing-box через libbox
        try {
            // После добавления libbox.aar:
            // val workingDir = filesDir.absolutePath
            // instance = BoxService.newInstance(configJson, tunFd!!.fd, workingDir)
            // instance?.start()

            // Заглушка: библиотека не подключена
            sendStatus("Error: libbox not available (build libbox.aar first)")
            tunFd?.close()
            tunFd = null
            return
        } catch (e: Exception) {
            sendStatus("Error: ${e.message}")
            tunFd?.close()
            tunFd = null
            return
        }

        // 3. Foreground-сервис с уведомлением
        // startForeground(NOTIFICATION_ID, buildNotification("Connected"))
        // sendStatus("Connected")
    }

    private fun stopVpn() {
        try {
            // instance?.close()
            // instance = null
        } catch (_: Exception) {}
        try {
            tunFd?.close()
            tunFd = null
        } catch (_: Exception) {}
        stopForeground(STOP_FOREGROUND_REMOVE)
        sendStatus("Disconnected")
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Vakhtovik VPN",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Статус VPN-подключения"
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(status: String): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Vakhtovik VPN")
            .setContentText(status)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun sendStatus(status: String) {
        // TODO: отправить статус в Dart через Broadcast или callback
    }
}
