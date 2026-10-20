package com.tarkilhk.wing.porterwake

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** A short-lived engine that runs porterWakeBackgroundMain while Wing is not running. */
class PorterHeadless(context: Context, channelFactory: (FlutterEngine) -> MethodChannel) {
    private val engine = FlutterEngine(context)
    private val channel: MethodChannel
    private val finished = mutableListOf<() -> Unit>()
    private val timeout = Runnable { PorterWakeNative.headlessTimedOut() }
    private val handler = Handler(Looper.getMainLooper())
    private val wake = context.getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "wing:porter_wake")
        .apply { setReferenceCounted(false); acquire(30_000) }

    init {
        channel = channelFactory(engine)
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context)
        loader.ensureInitializationComplete(context, null)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "package:wing/porter_wake/porter_wake_background.dart",
                "porterWakeBackgroundMain",
            ),
        )
        handler.postDelayed(timeout, 30_000)
    }

    fun onFinished(callback: () -> Unit) { finished.add(callback) }

    fun destroy() {
        handler.removeCallbacks(timeout)
        channel.setMethodCallHandler(null)
        engine.destroy()
        if (wake.isHeld) wake.release()
        finished.toList().also { finished.clear() }.forEach { it() }
    }
}
