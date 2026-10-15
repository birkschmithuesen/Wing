package com.tarkilhk.wing.voicebackground

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import com.tarkilhk.wing.MonitoringRuntime
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Dart control of [BackgroundVoiceService]; a hold starts only while Wing is visible. */
class BackgroundVoiceChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.tarkilhk.wing/background_voice")
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(::handle)
        BackgroundVoiceService.onStopped = { reason -> channel.invokeMethod("stopped", mapOf("reason" to reason)) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "listening") {
            BackgroundVoiceService.listening(call.argument<Boolean>("on") == true)
            return result.success(null)
        }
        if (call.method != "hold") return result.notImplemented()
        if (call.argument<Boolean>("on") != true) {
            release()
            return result.success(mapOf("held" to false))
        }
        if (BackgroundVoiceService.running) return result.success(mapOf("held" to true))
        val refused = refusal()
        if (refused != null) {
            Log.i(BackgroundVoiceService.TAG, "hold refused reason=$refused")
            return result.success(mapOf("held" to false, "reason" to refused))
        }
        val reply: (Boolean) -> Unit = { held -> result.success(mapOf("held" to held)) }
        BackgroundVoiceService.pendingStart = reply
        try {
            ContextCompat.startForegroundService(activity, Intent(activity, BackgroundVoiceService::class.java))
        } catch (_: Exception) {
            BackgroundVoiceService.pendingStart = null
            Log.i(BackgroundVoiceService.TAG, "hold refused reason=startFailed")
            return result.success(mapOf("held" to false, "reason" to "startFailed"))
        }
        main.postDelayed({
            if (BackgroundVoiceService.pendingStart === reply) {
                BackgroundVoiceService.pendingStart = null
                Log.i(BackgroundVoiceService.TAG, "hold refused reason=startTimeout")
                reply(false)
            }
        }, START_TIMEOUT_MS)
    }

    private fun refusal(): String? = when {
        !MonitoringRuntime.activityVisible -> "notVisible"
        activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED -> "permission"
        !BackgroundVoiceService.notificationsAllowed(activity) -> "notifications"
        else -> null
    }

    private fun release() {
        if (BackgroundVoiceService.running) activity.stopService(Intent(activity, BackgroundVoiceService::class.java))
    }

    fun close() {
        if (BackgroundVoiceService.running) {
            Log.i(BackgroundVoiceService.TAG, "stop reason=activityClosed")
            BackgroundVoiceService.onStopped?.invoke("activityClosed")
            release()
        }
        BackgroundVoiceService.onStopped = null
        channel.setMethodCallHandler(null)
    }

    private companion object { const val START_TIMEOUT_MS = 5_000L }
}
