package com.tarkilhk.wing

import android.app.*
import android.content.*
import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.lang.ref.WeakReference

/** Render and deliver interactions on the retained app engine, including cold starts. */
object ChatNotifications {
    const val handleExtra = "wing_notification_handle"
    private const val navigationExtra = "wing_conversation_navigation"
    private const val publicRawExtra = "wing_notification_interaction"
    private const val channelName = "com.tarkilhk.wing/chat_notifications"
    private const val turnChannel = "wing_turn_notifications"
    private const val attentionChannel = "wing_attention_notifications"
    private var channel: MethodChannel? = null
    private var ready = false
    private val pendingActions = mutableListOf<JSONObject>()
    private val displayed = mutableMapOf<Int, Map<*, *>>()
    private var observesConfiguration = false
    private var handleStore: NotificationHandleStore? = null
    private var directActionHost: Pair<Int, WeakReference<Activity>>? = null
    private fun handles(context: Context): NotificationHandleStore = handleStore ?: run {
        val prefs = preferences(context.applicationContext)
        NotificationHandleStore(
            read = { prefs.getString("handles", null) },
            write = { prefs.edit().putString("handles", it).commit() },
        ).also { handleStore = it }
    }
    fun consumeAction(context: Context, intent: Intent): JSONObject? =
        consumeIntent(context, intent, NotificationHandleStore.actionPurpose)
    private fun consumeIntent(context: Context, intent: Intent?, purpose: String): JSONObject? = try {
        val token = intent?.getStringExtra(handleExtra)
        intent?.removeExtra(handleExtra)
        handles(context).consume(token, purpose)
    } catch (_: Exception) { null }
    fun mainHandoff(context: Context, value: JSONObject): String? =
        handles(context).issue(value.getInt("notification_id"), NotificationHandleStore.mainPurpose,
            JSONObject(value.toString()))
    private fun pendingDismissals(context: Context): JSONArray {
        return try {
            val raw = preferences(context).getString("pending", "[]") ?: "[]"
            if (raw.length > NotificationInteractionSchema.maxChars * 512) return JSONArray()
            val source = JSONArray(raw)
            val valid = JSONArray()
            for (index in 0 until minOf(source.length(), 512)) {
                val value = NotificationInteractionSchema.parse(source.optJSONObject(index)?.toString())
                if (value?.opt("dismiss") == true) valid.put(value)
            }
            valid
        } catch (_: Exception) { JSONArray() }
    }
    private fun preferences(context: Context) = context.getSharedPreferences("notification_interactions", Context.MODE_PRIVATE)

    fun attach(source: Context, engine: FlutterEngine) {
        // The retained engine outlives activities and their configuration.
        val context = source.applicationContext
        if (!observesConfiguration) {
            observesConfiguration = true
            context.registerComponentCallbacks(object : ComponentCallbacks {
                override fun onLowMemory() {}
                override fun onConfigurationChanged(configuration: Configuration) {
                    Handler(Looper.getMainLooper()).post {
                        val manager = context.getSystemService(NotificationManager::class.java)
                        val active = manager.activeNotifications.map { it.id }.toSet()
                        for ((id, data) in displayed.toMap()) {
                            if (id !in active) { displayed.remove(id); continue }
                            try { show(context, data + mapOf("alert" to false)) }
                            catch (_: Exception) { /* A settings change can revoke posting. */ }
                        }
                    }
                }
            })
        }
        if (channel != null) return
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, channelName).apply {
            setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "initialize" -> {
                            createChannels(context)
                            ready = true
                            val queue = pendingDismissals(context)
                            val deliveries = (0 until queue.length()).map { asMap(queue.getJSONObject(it)) } + pendingActions.map { asMap(it) }
                            pendingActions.clear()
                            result.success(deliveries)
                        }
                        "acknowledge" -> {
                            val prefs = preferences(context)
                            val queue = pendingDismissals(context)
                            val remaining = JSONArray()
                            for (index in 0 until queue.length()) {
                                val entry = queue.getJSONObject(index)
                                if (entry.optString("interaction_id") != call.arguments) remaining.put(entry)
                            }
                            prefs.edit().putString("pending", remaining.toString()).commit()
                            result.success(null)
                        }
                        "finishDirectAction" -> {
                            val host = directActionHost
                            if (host != null && host.first == call.arguments) {
                                directActionHost = null
                                result.success(null)
                                host.second.get()?.finish()
                            } else result.success(null)
                        }
                        "actionStatus" -> {
                            Toast.makeText(context, call.arguments as String, Toast.LENGTH_LONG).show()
                            result.success(null)
                        }
                        "show" -> { show(context, call.arguments as Map<*, *>); result.success(null) }
                        "cancel" -> {
                            val id = (call.arguments as Number).toInt()
                            check(handles(context).invalidate(id))
                            displayed.remove(id)
                            ShortcutManagerCompat.removeLongLivedShortcuts(context, listOf("wing-chat-$id"))
                            context.getSystemService(NotificationManager::class.java).cancel(id)
                            result.success(null)
                        }
                        "channels" -> result.success(channelStates(context))
                        "openChannelSettings" -> {
                            val intent = if (Build.VERSION.SDK_INT >= 26) Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                                .putExtra(Settings.EXTRA_CHANNEL_ID, call.arguments as String)
                            else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
                            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) { result.error("notification_failed", "Notification operation failed", null) }
            }
        }
    }
    fun detach() { channel?.setMethodCallHandler(null); channel = null; ready = false; pendingActions.clear(); directActionHost = null }

    fun interact(context: Context, value: JSONObject, completed: (() -> Unit)? = null) {
        if (NotificationInteractionSchema.parse(value.toString()) == null) {
            completed?.invoke()
            return
        }
        // Only dismissals survive process death. A permission choice must never
        // become a deferred grant replayed on some later launch.
        if (value.optBoolean("dismiss")) {
            value.put("interaction_id", java.util.UUID.randomUUID().toString())
            val prefs = preferences(context)
            val queue = pendingDismissals(context)
            if (queue.length() < 512) queue.put(value)
            prefs.edit().putString("pending", queue.toString()).commit()
        }
        if (ready && channel != null) {
            channel!!.invokeMethod("interaction", asMap(value), object : MethodChannel.Result {
                override fun success(result: Any?) { completed?.invoke() }
                override fun error(code: String, message: String?, details: Any?) { completed?.invoke() }
                override fun notImplemented() { completed?.invoke() }
            })
        } else {
            if (!value.optBoolean("dismiss") && pendingActions.size < 512) pendingActions.add(value)
            completed?.invoke()
        }
    }
    private fun asMap(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith {
        val item = value.get(it)
        if (item == JSONObject.NULL) null else item
    }
    fun handleMainIntent(context: Context, intent: Intent?) {
        // MainActivity is exported. Raw JSON can never authorize an interaction.
        try { intent?.removeExtra(publicRawExtra) } catch (_: Exception) { return }
        val navigation = try { intent?.getStringExtra(navigationExtra) } catch (_: Exception) { null }
        try { intent?.removeExtra(navigationExtra) } catch (_: Exception) { return }
        val value = if (navigation != null) handles(context).readNavigation(navigation)
            else consumeIntent(context, intent, NotificationHandleStore.mainPurpose)
        value ?: return
        if (context is Activity && value.optString("choice").isNotEmpty() && !value.optBoolean("review")) {
            directActionHost = value.getInt("notification_id") to WeakReference(context)
        }
        interact(context, value)
    }
    fun dismiss(context: Context, intent: Intent) {
        val value = consumeIntent(context, intent, NotificationHandleStore.dismissPurpose) ?: return
        interact(context, value)
    }
    fun hasLiveEngine() = ready && channel != null && MonitoringRuntime.engine != null

    private fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(turnChannel, "Replies and updates", NotificationManager.IMPORTANCE_DEFAULT))
        manager.createNotificationChannel(NotificationChannel(attentionChannel, "Input needed and failures", NotificationManager.IMPORTANCE_HIGH))
    }
    private fun channelStates(context: Context): List<Map<String, Any>> {
        createChannels(context)
        val manager = context.getSystemService(NotificationManager::class.java)
        return listOf(turnChannel, attentionChannel, "hermes_monitoring").map { id ->
            val blocked = Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(id)?.importance == NotificationManager.IMPORTANCE_NONE
            mapOf("id" to id, "blocked" to blocked, "name" to when(id) {
                turnChannel -> "Replies and updates"; attentionChannel -> "Input needed and failures"; else -> "Background monitoring"
            })
        }
    }
    private fun intent(context: Context, data: Map<*, *>, choice: String, review: Boolean): PendingIntent {
        return intent(context, data, NotificationInteractionSchema.action(data, choice, review))
    }
    private fun intent(context: Context, data: Map<*, *>, value: JSONObject): PendingIntent {
        // Immutable PendingIntent identity contains only an opaque token; trusted storage binds its target and choice.
        val token = handles(context).issue((data["id"] as Number).toInt(), NotificationHandleStore.actionPurpose, value)
            ?: throw IllegalStateException("Notification handoff could not be stored")
        val identity = Uri.Builder().scheme("wing-notification").authority("action").appendPath(token).build()
        val intent = Intent(context, NotificationActionActivity::class.java).setData(identity).putExtra(handleExtra, token)
        return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    fun monitoringIntent(context: Context, id: Int, payload: String): PendingIntent {
        if (payload.isEmpty()) {
            return PendingIntent.getActivity(context, id,
                Intent(context, MainActivity::class.java)
                    .setAction("com.tarkilhk.wing.action.ACTIVITY")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        val data = mapOf("id" to id, "payload" to payload, "chat" to payload,
            "revision" to "monitoring", "expanded" to "")
        check(handles(context).replace(id, payload, "monitoring"))
        return intent(context, data, NotificationInteractionSchema.contentTap(data))
    }

    private fun deleteIntent(context: Context, data: Map<*, *>): PendingIntent {
        val value = JSONObject().put("dismiss", true).put("chat", data["chat"]).put("revision", data["revision"])
        // Local test alerts do not own a chat dismissal.
        val token = handles(context).issue((data["id"] as Number).toInt(), NotificationHandleStore.dismissPurpose, value)
        val target = Intent(context, NotificationDismissReceiver::class.java)
            .setData(Uri.Builder().scheme("wing-notification").authority("dismiss").appendPath(token ?: java.util.UUID.randomUUID().toString()).build())
            .putExtra(handleExtra, token)
        return PendingIntent.getBroadcast(context, 0, target, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    private fun show(context: Context, data: Map<*, *>) {
        createChannels(context)
        val id = (data["id"] as Number).toInt()
        check(handles(context).replace(id, data["payload"] as? String, data["revision"] as? String))
        val pending = data["pending"] as? String ?: ""
        val error = data["error"] as? String
        val busy = data["submitting"] == true
        val body = listOf(pending, data["body"] as String).filter { it.isNotEmpty() }.joinToString(" · ")
        val icon = when(data["icon"]) {
            "ic_stat_wing_input" -> R.drawable.ic_stat_wing_input
            "ic_stat_wing_stopped" -> R.drawable.ic_stat_wing_stopped
            else -> R.drawable.ic_stat_wing
        }
        val builder = NotificationCompat.Builder(context, data["channel"] as String)
            .setSmallIcon(icon).setContentTitle(data["title"] as String)
            .setContentText(body).setSubText(data["scope"] as? String)
            .setAutoCancel(true).setOnlyAlertOnce(data["alert"] != true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(NotificationCompat.Builder(context, data["channel"] as String)
                .setSmallIcon(icon).setContentTitle("Wing").setContentText("Open Wing to review this chat").build())
            .setCategory(if (pending.isNotEmpty()) NotificationCompat.CATEGORY_REMINDER else NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(if (data["channel"] == attentionChannel) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(intent(context, data, NotificationInteractionSchema.contentTap(data))).setDeleteIntent(deleteIntent(context, data))
        if (data["alert"] == true) builder.setDefaults(NotificationCompat.DEFAULT_ALL)
        else builder.setSilent(true)
        val largeText = context.resources.configuration.fontScale > 1.3f
        val command = data["expanded"] as String
        val preview = if (data["kind"] == "approval")
            NotificationInteractionSchema.approvalPreview(command, largeText) else command
        val expanded = listOf(
            when { busy -> "Sending decision…"; !error.isNullOrEmpty() -> error; else -> pending },
            preview,
        ).filter { it.isNotEmpty() }.joinToString("\n")
        if ((data["payload"] as String).isNotEmpty()) {
            val user = Person.Builder().setName("You").setKey("wing-user").build()
            val sender = Person.Builder().setName(data["title"] as String).setBot(true).build()
            val shortcut = "wing-chat-$id"
            val navigation = handles(context).issue(id, NotificationHandleStore.navigationPurpose,
                NotificationInteractionSchema.contentTap(data))
                ?: throw IllegalStateException("Conversation navigation could not be stored")
            val shortcutIntent = Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .setData(Uri.parse("wing-conversation://chat/$id"))
                .putExtra(navigationExtra, navigation)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            check(ShortcutManagerCompat.pushDynamicShortcut(context,
                ShortcutInfoCompat.Builder(context, shortcut)
                    .setShortLabel(data["title"] as String)
                    .setLongLived(true)
                    .setPersons(arrayOf(user, sender))
                    .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
                    .setIntent(shortcutIntent)
                    .build()))
            builder.setShortcutId(shortcut)
                .setStyle(NotificationCompat.MessagingStyle(user)
                    .setConversationTitle(data["title"] as String)
                    .setGroupConversation(JSONObject(data["payload"] as String).has("room"))
                    .addMessage(expanded, System.currentTimeMillis(), sender))
        } else {
            builder.setStyle(NotificationCompat.BigTextStyle().bigText(expanded))
        }
        for (action in NotificationInteractionSchema.visibleActions(
            data, largeText)) {
            val review = action == "review"
            val label = when (action) { "once" -> "Once"; "deny" -> "Deny"; else -> "Review" }
            builder.addAction(0, label, intent(context, data, if (review) "" else action, review))
        }
        NotificationManagerCompat.from(context).notify(id, builder.build())
        displayed[id] = data
    }
}

class NotificationDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        ChatNotifications.dismiss(context, intent)
    }
}

/** An activity PendingIntent permits unlock and cold-start UI without a trampoline. */
class NotificationActionActivity : Activity() {
    private var sent = false
    private var resumed = false
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        if (Build.VERSION.SDK_INT >= 27) setShowWhenLocked(true)
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (keyguard.isKeyguardLocked && Build.VERSION.SDK_INT >= 26) {
            keyguard.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() { deliver() }
                override fun onDismissCancelled() { finish() }
                override fun onDismissError() { finish() }
            })
        } else if (keyguard.isKeyguardLocked) {
            // On API 24/25 let the normal app activity wait behind the lock screen.
            val value = ChatNotifications.consumeAction(this, intent)
            if (value == null) finish() else openMain(value)
        }
    }
    override fun onResume() {
        super.onResume()
        resumed = true
        deliver()
    }
    override fun onPause() {
        resumed = false
        super.onPause()
    }
    private fun deliver() {
        if (!resumed || sent || getSystemService(KeyguardManager::class.java).isKeyguardLocked) return
        sent = true
        val value = ChatNotifications.consumeAction(this, intent) ?: return finish()
        if (NotificationInteractionSchema.opensMain(value, ChatNotifications.hasLiveEngine())) openMain(value)
        else {
            // A retained engine does not give a background UID network access.
            // Keep this user-started activity resumed through recovery and the
            // decision acknowledgement, rather than finishing at dispatch.
            ChatNotifications.interact(this, value) { finish() }
        }
    }
    private fun openMain(value: JSONObject) {
        val token = ChatNotifications.mainHandoff(this, value) ?: return finish()
        startActivity(Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(ChatNotifications.handleExtra, token))
        finish()
    }
}
