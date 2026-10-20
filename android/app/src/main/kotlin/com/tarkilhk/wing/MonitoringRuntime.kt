package com.tarkilhk.wing

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** One engine owns both the visible app and background event subscriptions. */
object MonitoringRuntime {
    var engine: FlutterEngine? = null
        private set
    var activityVisible = false
    private var activityAttached = false
    var summary = mapOf("title" to "Watching chats", "text" to "Connecting to Hermes")
    var running = false
    private var channel: MethodChannel? = null
    private val starting = mutableListOf<MethodChannel.Result>()
    private val stopping = mutableListOf<MethodChannel.Result>()

    fun attach(context: Context, flutterEngine: FlutterEngine) {
        activityAttached = true
        if (engine === flutterEngine) return
        engine = flutterEngine
        ChatNotifications.attach(context, flutterEngine)
        val app = context.applicationContext
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.tarkilhk.wing/background_monitoring",
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val values = call.arguments as? Map<*, *>
                        val next = mapOf("title" to (values?.get("title") as? String ?: "Watching chats"),
                            "text" to (values?.get("text") as? String ?: "Connecting to Hermes"))
                        if (next != summary) {
                            summary = next
                            BackgroundMonitoringService.instance?.updateSummary()
                        }
                        if (running || !activityVisible) {
                            result.success(status(app))
                        } else {
                            starting.add(result)
                            try {
                                ContextCompat.startForegroundService(
                                    app, Intent(app, BackgroundMonitoringService::class.java),
                                )
                            } catch (_: Exception) {
                                startFailed()
                            }
                        }
                    }
                    "stop" -> {
                        stopping.add(result)
                        if (!app.stopService(Intent(app, BackgroundMonitoringService::class.java))) {
                            completeStop()
                        }
                    }
                    "openBatterySettings" -> {
                        try {
                            app.startActivity(Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:${app.packageName}"),
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(null)
                        } catch (_: Exception) {
                            result.error("battery_settings_unavailable", "Could not open battery settings", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun started(context: Context) {
        running = true
        val pending = starting.toList()
        starting.clear()
        pending.forEach { it.success(status(context)) }
    }

    fun startFailed() {
        val pending = starting.toList()
        starting.clear()
        pending.forEach { it.error("monitoring_start_failed", "Could not start monitoring", null) }
    }

    private fun completeStop() {
        val pending = stopping.toList()
        stopping.clear()
        pending.forEach { it.success(null) }
    }

    fun serviceDestroyed() {
        running = false
        completeStop()
        startFailed()
        releaseIfUnused()
    }

    fun detach(changingConfigurations: Boolean) {
        activityAttached = false
        activityVisible = false
        if (!changingConfigurations) releaseIfUnused()
    }

    private fun status(context: Context): Map<String, Boolean> = mapOf(
        "running" to running,
        "batteryUnrestricted" to
            context.getSystemService(PowerManager::class.java)
                .isIgnoringBatteryOptimizations(context.packageName),
    )

    private fun releaseIfUnused() {
        // Allow an in-flight method result or replacement activity to complete.
        Handler(Looper.getMainLooper()).post {
            if (!activityAttached && !running && starting.isEmpty()) {
                channel?.setMethodCallHandler(null)
                channel = null
                ChatNotifications.detach()
                com.tarkilhk.wing.porterwake.PorterWakeNative.detach()
                engine?.destroy()
                engine = null
            }
        }
    }
}
