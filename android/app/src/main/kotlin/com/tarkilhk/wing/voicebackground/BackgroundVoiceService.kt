package com.tarkilhk.wing.voicebackground

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.tarkilhk.wing.MainActivity
import com.tarkilhk.wing.R

/**
 * Microphone foreground service for a conversation that continues with the
 * screen off (spec 2026-10-14 background). It never records: it keeps the
 * process, CPU and while-in-use microphone access for the vad rounds Dart starts.
 */
class BackgroundVoiceService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var modeListener: Any? = null
    private val stopReason = StopReason()
    private var heldAt = 0L
    private val idleHandler = Handler(Looper.getMainLooper())
    private val idleTimer = HoldIdleTimer(IDLE_TIMEOUT_MS)
    private val idleCheck: Runnable = Runnable { checkIdle() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            finish(intent.getStringExtra(EXTRA_REASON) ?: "notification")
            return START_NOT_STICKY
        }
        if (running) return START_NOT_STICKY
        val reply = pendingStart
        pendingStart = null
        try {
            val notification = notification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            if (reply == null) {
                // The caller gave up waiting: never hold a microphone nobody owns.
                stopReason.resolve("released")
                stopSelf()
                return START_NOT_STICKY
            }
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:voice-conversation")
                .apply { setReferenceCounted(false); acquire() }
            watchCalls()
            running = true
            instance = this
            heldAt = SystemClock.elapsedRealtime()
            startIdleTimeout()
            Log.i(TAG, "hold on")
            reply(true)
        } catch (_: Exception) {
            Log.i(TAG, "hold refused reason=startFailed")
            reply?.invoke(false)
            stopReason.resolve("startFailed")
            stopSelf()
        }
        // Reopening Wing starts a new conversation; never resurrect a microphone.
        return START_NOT_STICKY
    }

    private fun finish(reason: String) {
        val resolved = stopReason.resolve(reason) ?: return
        Log.i(TAG, "stop reason=$resolved")
        onStopped?.invoke(resolved)
        stopSelf()
    }

    private fun startIdleTimeout() {
        idleTimer.start(SystemClock.elapsedRealtime())
        idleHandler.postDelayed(idleCheck, IDLE_CHECK_INTERVAL_MS)
    }

    private fun cancelIdleTimeout() {
        idleTimer.stop()
        idleHandler.removeCallbacks(idleCheck)
    }

    private fun checkIdle() {
        val now = SystemClock.elapsedRealtime()
        if (idleTimer.expired(now)) {
            finish("idleTimeout")
            return
        }
        idleHandler.postDelayed(idleCheck, IDLE_CHECK_INTERVAL_MS)
    }

    /** A barge-in listen round opening or closing counts as a live conversation,
     * pushing the idle-timeout deadline out. */
    private fun touchIdleTimeout() {
        idleTimer.touch(SystemClock.elapsedRealtime())
    }

    private fun watchCalls() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val listener = AudioManager.OnModeChangedListener { mode -> if (mode in callModes) finish("call") }
        getSystemService(AudioManager::class.java).addOnModeChangedListener(mainExecutor, listener)
        modeListener = listener
    }

    private fun notification(listening: Boolean = false): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Voice conversation", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shows while conversation mode can open the microphone"
                    setShowBadge(false)
                },
            )
        }
        val open = PendingIntent.getActivity(
            this, NOTIFICATION_ID,
            Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
                this.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_monitoring)
            .setContentTitle("Conversation mode")
            .setContentText(if (listening) "Microphone is listening." else "Microphone opens after each reply.")
            .setContentIntent(open)
            .setDeleteIntent(stopIntent("dismissed", 1))
            .addAction(0, "Stop", stopIntent("notification", 2))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun stopIntent(reason: String, code: Int): PendingIntent = PendingIntent.getService(
        this, code,
        Intent(this, BackgroundVoiceService::class.java).setAction(ACTION_STOP).putExtra(EXTRA_REASON, reason),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    override fun onDestroy() {
        running = false
        instance = null
        if (stopReason.reason == null) Log.i(TAG, "stop reason=released")
        cancelIdleTimeout()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (modeListener as? AudioManager.OnModeChangedListener)?.let {
                getSystemService(AudioManager::class.java).removeOnModeChangedListener(it)
            }
        }
        modeListener = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        if (heldAt > 0) Log.i(TAG, "wakelock released heldMs=${SystemClock.elapsedRealtime() - heldAt}")
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        const val TAG = "WingBgVoice"
        const val ACTION_STOP = "com.tarkilhk.wing.voicebackground.STOP"
        private const val EXTRA_REASON = "reason"
        private const val CHANNEL_ID = "voice_conversation"
        private const val NOTIFICATION_ID = 214611

        /** Safety backstop (t_8f6a3d26): no `listening()` activity for this long
         * force-stops the hold even if the conversation loop never told it to.
         * A vad round or a single spoken reply normally finishes in seconds;
         * ten minutes gives generous margin above any plausible turn while
         * bounding the worst-case wakelock/foreground-service drain. */
        private const val IDLE_TIMEOUT_MS = 10 * 60 * 1000L
        private const val IDLE_CHECK_INTERVAL_MS = 60 * 1000L
        private val callModes = setOf(
            AudioManager.MODE_RINGTONE, AudioManager.MODE_IN_CALL,
            AudioManager.MODE_IN_COMMUNICATION, AudioManager.MODE_CALL_SCREENING,
        )

        @Volatile var running = false
            private set

        /** Answer for the Dart `hold(true)` that started this service. */
        var pendingStart: ((Boolean) -> Unit)? = null

        /** Forwards a native stop (notification, dismissed, call) to Dart. */
        var onStopped: ((String) -> Unit)? = null

        private var instance: BackgroundVoiceService? = null

        /** Barge-in listen round open or closed: live conversation activity,
         * so it pushes the idle-timeout deadline out, and updates the
         * notification text. */
        fun listening(on: Boolean) {
            val service = instance ?: return
            service.touchIdleTimeout()
            if (!notificationsAllowed(service)) return
            Log.i(TAG, if (on) "listening on" else "listening off")
            service.getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, service.notification(on))
        }

        /** Hook for VoiceChannel.pause(): true keeps the vad round and playback. */
        fun keepsVoice(): Boolean {
            if (running) Log.i(TAG, "pause kept")
            return running
        }

        fun notificationsAllowed(context: Context): Boolean {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
            val channel = context.getSystemService(NotificationManager::class.java).getNotificationChannel(CHANNEL_ID)
            return channel == null || channel.importance != NotificationManager.IMPORTANCE_NONE
        }
    }
}
