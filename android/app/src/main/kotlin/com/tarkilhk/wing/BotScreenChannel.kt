package com.tarkilhk.wing

import android.app.Activity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Window presentation only; never changes the desktop or its control lease. */
class BotScreenChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.tarkilhk.wing/bot_screen")
    private var immersive = false
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "setImmersive") result.notImplemented()
            else if (call.arguments !is Boolean) result.error("argument", "Expected a fullscreen state", null)
            else {
                immersive = call.arguments as Boolean
                apply()
                result.success(null)
            }
        }
    }
    fun apply() {
        val controller = WindowCompat.getInsetsController(activity.window, activity.window.decorView)
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (immersive) controller.hide(WindowInsetsCompat.Type.systemBars())
        else controller.show(WindowInsetsCompat.Type.systemBars())
    }
    fun close() { immersive = false; apply(); channel.setMethodCallHandler(null) }
}
