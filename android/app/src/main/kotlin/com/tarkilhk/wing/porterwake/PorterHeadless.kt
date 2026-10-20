package com.tarkilhk.wing.porterwake

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * A short-lived engine that runs porterWakeBackgroundMain while Wing is not
 * running. Main thread only. Events that arrive before Dart called `initialize`
 * are queued and handed over there; later ones are invoked directly on the
 * channel. The engine is destroyed only after Dart reported `finished` and every
 * directly invoked event has been answered (or the 30 s safety timeout hit).
 */
class PorterHeadless(
    context: Context,
    channelFactory: (FlutterEngine, PorterHeadless) -> MethodChannel,
) {
    private val engine = FlutterEngine(context)
    private var channel: MethodChannel? = null
    private val queue = mutableListOf<Map<String, Any?>>()
    private val finished = mutableListOf<() -> Unit>()
    private var initialized = false
    private var finishRequested = false
    private var pending = 0
    private var destroyed = false
    private val timeout = Runnable { PorterWakeNative.finishHeadless(this) }
    private val handler = Handler(Looper.getMainLooper())
    private val wake = context.getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "wing:porter_wake")
        .apply { setReferenceCounted(false); acquire(30_000) }

    init {
        try {
            channel = channelFactory(engine, this)
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
        } catch (error: Throwable) {
            // The caller clears its reference and fails the pending taps.
            if (wake.isHeld) wake.release()
            channel?.setMethodCallHandler(null)
            engine.destroy()
            throw error
        }
    }

    /** Queue the event until Dart initialized, otherwise invoke it directly. */
    fun deliver(event: Map<String, Any?>, completed: (() -> Unit)?) {
        val done = completed?.let(::once)
        if (done != null) finished.add(done)
        if (!initialized) { queue.add(event); return }
        extend()
        pending++
        val answered = once {
            pending--
            done?.invoke()
            finishIfIdle()
        }
        channel?.invokeMethod("event", event, object : MethodChannel.Result {
            override fun success(result: Any?) = answered()
            override fun error(code: String, message: String?, details: Any?) = answered()
            override fun notImplemented() = answered()
        })
    }

    /** Dart's `initialize`: hand over what was queued, later events go direct. */
    fun initialize(): List<Map<String, Any?>> {
        initialized = true
        return queue.toList().also { queue.clear() }
    }

    /** Dart's `finished`: tear down once no direct event is still in flight. */
    fun requestFinish() {
        finishRequested = true
        if (!initialized) {
            // Dart gave up before `initialize`: nothing will consume the queue,
            // so drop it (destroy completes the waiting callbacks) and tear down.
            queue.clear()
            PorterWakeNative.finishHeadless(this)
            return
        }
        finishIfIdle()
    }

    private fun finishIfIdle() {
        if (finishRequested && pending == 0 && queue.isEmpty()) PorterWakeNative.finishHeadless(this)
    }

    private fun extend() {
        handler.removeCallbacks(timeout)
        handler.postDelayed(timeout, 30_000)
        wake.acquire(30_000)
    }

    private fun once(block: () -> Unit): () -> Unit {
        var done = false
        return { if (!done) { done = true; block() } }
    }

    fun destroy() {
        if (destroyed) return
        destroyed = true
        handler.removeCallbacks(timeout)
        channel?.setMethodCallHandler(null)
        engine.destroy()
        if (wake.isHeld) wake.release()
        finished.toList().also { finished.clear() }.forEach { it() }
    }
}
