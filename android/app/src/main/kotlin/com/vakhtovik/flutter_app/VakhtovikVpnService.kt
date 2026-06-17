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
import io.nekohasekai.libbox.BoxService

/**
 * Android VPN-сервис поверх sing-box (libbox.so).
 */
class VakhtovikVpnService : VpnService() {

    companion object {
        const val ACTION_CONNECT = "com.vakhtovik.flutter_app.VPN_CONNECT"
        const val ACTION_DISCONNECT = "com.vakhtovik.flutter_app.VPN_DISCONNECT"
        const val EXTRA_CONFIG = "config"
        const val NOTIFICATION_ID = 4242
        const val CHANNEL_ID = "vakhtovik_vpn"
    }

    private var running = false
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
        if (configJson.isEmpty() || running) return

        val builder = Builder()
            .setSession("Vakhtovik VPN")
            .setMtu(1500)
            .addAddress("172.19.0.1", 30)
            .addDnsServer("1.1.1.1")
            .addDnsServer("8.8.8.8")
            .setBlocking(true)

        // Маршрутизируем весь трафик (0.0.0.0/0) КРОМЕ IP сервера Hysteria2 (195.226.92.151),
        // чтобы не было routing loop, так как мы не можем сделать protect() для сокетов libbox.
        addBypassRoute(builder, "195.226.92.151")

        tunFd = builder.establish()
        if (tunFd == null) {
            sendStatus("Error: TUN creation failed")
            return
        }

        try {
            val error = BoxService.start(configJson, tunFd!!.fd, filesDir.absolutePath)
            if (error != null) {
                sendStatus("Error: $error")
                tunFd?.close()
                tunFd = null
                return
            }
        } catch (e: UnsatisfiedLinkError) {
            sendStatus("Error: libbox.so not found")
            tunFd?.close()
            tunFd = null
            return
        } catch (e: Exception) {
            sendStatus("Error: ${e.message}")
            tunFd?.close()
            tunFd = null
            return
        }

        running = true
        startForeground(NOTIFICATION_ID, buildNotification("Connected"))
        sendStatus("Connected")
    }

    private fun addBypassRoute(builder: Builder, bypassIp: String) {
        val parts = bypassIp.split(".").map { it.toLong() }
        val ip = (parts[0] shl 24) or (parts[1] shl 16) or (parts[2] shl 8) or parts[3]
        
        var currentIp = 0L
        for (i in 31 downTo 0) {
            val bit = (ip ushr i) and 1L
            val oppositeBit = bit xor 1L
            val routeIp = currentIp or (oppositeBit shl i)
            
            val ipString = "${(routeIp ushr 24) and 0xFF}.${(routeIp ushr 16) and 0xFF}.${(routeIp ushr 8) and 0xFF}.${routeIp and 0xFF}"
            try {
                builder.addRoute(ipString, 32 - i)
            } catch (e: Exception) {}
            
            currentIp = currentIp or (bit shl i)
        }
    }

    private fun stopVpn() {
        if (!running) return
        try { BoxService.stop() } catch (_: Exception) {}
        try { tunFd?.close(); tunFd = null } catch (_: Exception) {}
        running = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        sendStatus("Disconnected")
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL_ID, "Vakhtovik VPN", NotificationManager.IMPORTANCE_LOW)
            ch.description = "Статус VPN-подключения"
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
    }

    private fun buildNotification(status: String): Notification {
        val intent = Intent(this, MainActivity::class.java).apply { flags = Intent.FLAG_ACTIVITY_SINGLE_TOP }
        val pi = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Vakhtovik VPN")
            .setContentText(status)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    private fun sendStatus(status: String) {
        try {
            java.io.File(filesDir, "vpn_status.txt").writeText(status)
        } catch (e: Exception) {}
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            android.widget.Toast.makeText(this, status, android.widget.Toast.LENGTH_LONG).show()
        }
    }
}
