package com.tarkilhk.wing

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.media.AudioManager
import com.cloudwebrtc.webrtc.audio.AudioSwitchManager
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Audio and notification lifetime follows the call, independently of monitoring. */
object LiveVoiceRuntime {
    private var channel: MethodChannel? = null
    private var pending: MethodChannel.Result? = null
    private val stopping = mutableListOf<MethodChannel.Result>()
    private var preparing = false
    val audioOwned get() = active || preparing
    var active = false
        private set
    var title = "Voice conversation"
        private set
    var payload = ""
        private set
    var muted = false
        private set

    fun attach(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.tarkilhk.wing/live_voice").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepare" -> {
                        if (audioOwned) {
                            result.error("voice_busy", "A voice conversation already owns audio.", null)
                            return@setMethodCallHandler
                        }
                        preparing = true
                        AudioSwitchManager.instance?.audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { focus ->
                            if (active && focus < 0) action("audioInterrupted")
                        }
                        result.success(null)
                    }
                    "start" -> {
                        if (!MonitoringRuntime.activityVisible || active ||
                            ContextCompat.checkSelfPermission(app, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED ||
                            !NotificationManagerCompat.from(app).areNotificationsEnabled()) {
                            result.error("voice_unavailable", "Allow microphone and notifications, then start voice in Wing.", null)
                        } else {
                            title = call.argument<String>("title") ?: "Voice conversation"
                            payload = call.argument<String>("payload").orEmpty()
                            muted = false
                            pending = result
                            active = true
                            try {
                                ContextCompat.startForegroundService(app, Intent(app, LiveVoiceService::class.java))
                            } catch (_: Exception) { failed() }
                        }
                    }
                    "muted" -> {
                        muted = call.arguments == true
                        LiveVoiceService.instance?.updateNotification()
                        result.success(null)
                    }
                    "stop" -> {
                        stopping.add(result)
                        if (!app.stopService(Intent(app, LiveVoiceService::class.java))) {
                            active = false
                            preparing = false
                            completeStop()
                            MonitoringRuntime.releaseIfUnused()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
    private fun completeStop() {
        val pendingStops = stopping.toList()
        stopping.clear()
        pendingStops.forEach { it.success(null) }
    }
    fun started() { pending?.success(null); pending = null }
    fun failed() {
        pending?.error("voice_service_failed", "Could not keep voice active in the background.", null)
        pending = null
        active = false
        preparing = false
        MonitoringRuntime.releaseIfUnused()
    }
    fun action(action: String) { channel?.invokeMethod("action", action) }
    fun destroyed() {
        action("end")
        failed()
        completeStop()
    }
    fun detach() { preparing = false; channel?.setMethodCallHandler(null); channel = null }
}

class LiveVoiceService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    override fun onBind(intent: Intent?): IBinder? = null
    private fun action(name: String): PendingIntent = PendingIntent.getService(
        this, if (name == "end") 1 else 2,
        Intent(this, LiveVoiceService::class.java).setAction(name),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    private fun notification() = NotificationCompat.Builder(this, channelId)
        .setSmallIcon(R.drawable.ic_stat_monitoring)
        .setContentTitle(LiveVoiceRuntime.title)
        .setContentText(if (LiveVoiceRuntime.muted) "Voice · microphone muted" else "Voice · microphone on")
        .setContentIntent(ChatNotifications.monitoringIntent(this, notificationId, LiveVoiceRuntime.payload))
        .setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false)
        .setCategory(NotificationCompat.CATEGORY_CALL)
        .addAction(0, if (LiveVoiceRuntime.muted) "Unmute" else "Mute", action("mute"))
        .addAction(0, "End voice", action("end"))
        .build()

    fun updateNotification() { getSystemService(NotificationManager::class.java).notify(notificationId, notification()) }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!LiveVoiceRuntime.active || MonitoringRuntime.engine == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action in listOf("end", "mute")) {
            LiveVoiceRuntime.action(intent!!.action!!)
            return START_NOT_STICKY
        }
        try {
            val manager = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(NotificationChannel(channelId, "Voice conversations", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
                check(manager.getNotificationChannel(channelId).importance != NotificationManager.IMPORTANCE_NONE)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(notificationId, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else { startForeground(notificationId, notification()) }
            instance = this
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:live-voice")
                .apply { setReferenceCounted(false); acquire() }
            LiveVoiceRuntime.started()
        } catch (_: Exception) { LiveVoiceRuntime.failed(); stopSelf() }
        return START_NOT_STICKY
    }
    override fun onDestroy() {
        instance = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        LiveVoiceRuntime.destroyed()
        super.onDestroy()
    }
    companion object {
        var instance: LiveVoiceService? = null
            private set
        private const val channelId = "wing_live_voice"
        private const val notificationId = 214602
    }
}
