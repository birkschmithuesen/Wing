package com.tarkilhk.wing

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/** Raises the priority of the process that owns the real Dart event clients. */
class BackgroundMonitoringService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var builder: NotificationCompat.Builder? = null
    fun updateSummary() {
        val notification = builder ?: return
        notification.setContentIntent(ChatNotifications.monitoringIntent(
            this, notificationId, MonitoringRuntime.summary["payload"].orEmpty()))
            .setContentTitle(MonitoringRuntime.summary["title"])
            .setContentText(MonitoringRuntime.summary["text"])
            .setStyle(NotificationCompat.BigTextStyle().bigText(MonitoringRuntime.summary["text"]))
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(notificationId, notification.build())
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Never display a monitoring claim after process death without clients.
        if (MonitoringRuntime.engine == null ||
            !NotificationManagerCompat.from(this).areNotificationsEnabled()
        ) {
            MonitoringRuntime.startFailed()
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            val manager = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(NotificationChannel(
                    channelId, "Background monitoring", NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Keeps connected Hermes chats available outside Wing"
                    setShowBadge(false)
                })
                check(manager.getNotificationChannel(channelId).importance != NotificationManager.IMPORTANCE_NONE)
            }
            val builder = NotificationCompat.Builder(this, channelId)
                .setSmallIcon(R.drawable.ic_stat_monitoring)
                .setContentTitle(MonitoringRuntime.summary["title"])
                .setContentText(MonitoringRuntime.summary["text"])
                .setStyle(NotificationCompat.BigTextStyle().bigText(MonitoringRuntime.summary["text"]))
                .setContentIntent(ChatNotifications.monitoringIntent(
                    this, notificationId, MonitoringRuntime.summary["payload"].orEmpty()))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setPriority(NotificationCompat.PRIORITY_LOW)
            this.builder = builder
            instance = this
            val notification = builder.build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(notificationId, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(notificationId, notification)
            }
            if (wakeLock == null) {
                wakeLock = getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:hermes-monitoring")
                    .apply { setReferenceCounted(false); acquire() }
            }
            MonitoringRuntime.started(this)
        } catch (_: Exception) {
            MonitoringRuntime.startFailed()
            stopSelf()
        }
        // Reopening Wing restores connections; don't resurrect an empty engine.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        instance = null
        builder = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        MonitoringRuntime.serviceDestroyed()
        super.onDestroy()
    }

    companion object {
        var instance: BackgroundMonitoringService? = null
            private set
        private const val channelId = "hermes_monitoring"
        private const val notificationId = 214601
    }
}
