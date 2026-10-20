package com.tarkilhk.wing.porterwake

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import org.unifiedpush.android.connector.UnifiedPush
import java.lang.ref.WeakReference

/** Native side of com.tarkilhk.wing/porter_wake for the app engine and the headless engine. */
object PorterWakeNative {
    const val channelName = "com.tarkilhk.wing/porter_wake"
    const val extra = "porter_wake_interaction"
    private val main = Handler(Looper.getMainLooper())
    private var mainEngine: FlutterEngine? = null
    private var mainChannel: MethodChannel? = null
    private var mainReady = false
    private var activity = WeakReference<Activity>(null)
    private var headless: PorterHeadless? = null
    private val headlessQueue = mutableListOf<Map<String, Any?>>()
    private val pendingInteractions = mutableListOf<Map<String, Any?>>()
    private fun prefs(context: Context) =
        context.getSharedPreferences("porter_wake_native", Context.MODE_PRIVATE)

    fun attach(source: Activity, engine: FlutterEngine) {
        activity = WeakReference(source)
        if (mainEngine === engine) return
        mainEngine = engine
        mainReady = false
        mainChannel = channel(source.applicationContext, engine, background = false)
    }

    fun detach() {
        mainChannel?.setMethodCallHandler(null)
        mainChannel = null
        mainEngine = null
        mainReady = false
    }

    internal fun channel(context: Context, engine: FlutterEngine, background: Boolean): MethodChannel =
        MethodChannel(engine.dartExecutor.binaryMessenger, channelName).apply {
            setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "initialize" -> {
                            if (background) {
                                result.success(headlessQueue.toList().also { headlessQueue.clear() })
                            } else {
                                mainReady = true
                                result.success(drainMain(context) + pendingInteractions.toList().also { pendingInteractions.clear() })
                            }
                        }
                        "register" -> register(context, call.arguments as String) { result.success(it) }
                        "unregister" -> { UnifiedPush.unregister(context, call.arguments as String); result.success(null) }
                        "show" -> { PorterNotifications.show(context, call.arguments as Map<*, *>); result.success(null) }
                        "cancel" -> { PorterNotifications.cancel(context); result.success(null) }
                        "deviceLabel" -> result.success(Build.MODEL.take(40))
                        "finished" -> { result.success(null); if (background) main.post { finishHeadless() } }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    result.error("porter_wake_failed", "Porter wake operation failed", null)
                }
            }
        }

    private fun register(context: Context, instance: String, done: (Boolean) -> Unit) {
        // ANNAHME C1: may require an Activity context to show the distributor chooser.
        val owner = activity.get() ?: context
        UnifiedPush.tryUseCurrentOrDefaultDistributor(owner) { success ->
            if (success) UnifiedPush.register(context, instance)
            main.post { done(success) }
        }
    }

    /** Registration events belong to the app engine; persist them across process death. */
    fun queueForMain(context: Context, event: Map<String, Any?>) = main.post {
        val channel = mainChannel
        if (mainReady && channel != null) { channel.invokeMethod("event", event); return@post }
        val queue = JSONArray(prefs(context).getString("pending", "[]"))
        queue.put(JSONObject(event))
        prefs(context).edit().putString("pending", queue.toString()).commit()
    }

    private fun drainMain(context: Context): List<Map<String, Any?>> {
        val queue = JSONArray(prefs(context).getString("pending", "[]"))
        prefs(context).edit().remove("pending").commit()
        return (0 until queue.length()).map { asMap(queue.getJSONObject(it)) }
    }

    /** JSONObject.NULL is not encodable by the method codec. */
    internal fun asMap(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith {
        val item = value.get(it)
        if (item == JSONObject.NULL) null else item
    }

    fun deliverPush(context: Context, instance: String, bytes: ByteArray) = main.post {
        val event = mapOf("type" to "push", "connection" to instance, "bytes" to bytes)
        val channel = mainChannel
        if (mainReady && channel != null) channel.invokeMethod("event", event)
        else runHeadless(context, event, null)
    }

    /** From PorterActionActivity: rate/snooze stay in the background; open goes to the app. */
    fun interact(context: Context, event: Map<String, Any?>, completed: () -> Unit) {
        val channel = mainChannel
        if (mainReady && channel != null) {
            channel.invokeMethod("event", event, object : MethodChannel.Result {
                override fun success(result: Any?) = completed()
                override fun error(code: String, message: String?, details: Any?) = completed()
                override fun notImplemented() = completed()
            })
        } else runHeadless(context, event, completed)
    }

    fun handleMainIntent(context: Context, intent: Intent?) {
        val raw = intent?.getStringExtra(extra) ?: return
        intent.removeExtra(extra)
        val event = asMap(JSONObject(raw))
        val channel = mainChannel
        if (mainReady && channel != null) channel.invokeMethod("event", event)
        else pendingInteractions.add(event)
    }

    private fun runHeadless(context: Context, event: Map<String, Any?>, completed: (() -> Unit)?) {
        headlessQueue.add(event)
        val current = headless
        if (current != null) { completed?.let(current::onFinished); return }
        headless = PorterHeadless(context.applicationContext, channelFactory = { engine ->
            channel(context.applicationContext, engine, background = true)
        }).also { started -> completed?.let(started::onFinished) }
    }

    private fun finishHeadless() {
        headless?.destroy()
        headless = null
    }

    internal fun headlessTimedOut() = finishHeadless()
}
