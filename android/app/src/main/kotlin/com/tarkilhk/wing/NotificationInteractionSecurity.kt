package com.tarkilhk.wing

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Strict decoding at native intent/storage boundaries; malformed data is discarded. */
internal object NotificationInteractionSchema {
    fun contentTap(data: Map<*, *>): JSONObject {
        val payload = data["payload"] as String
        val group = payload.isNotEmpty() && JSONObject(payload).has("room")
        return action(data, "", !group)
    }

    fun opensMain(value: JSONObject, hasLiveEngine: Boolean): Boolean =
        value.getString("choice").isEmpty() || value.getBoolean("review") || !hasLiveEngine

    fun action(data: Map<*, *>, choice: String, review: Boolean): JSONObject =
        JSONObject().put("payload", data["payload"]).put("choice", choice).put("review", review)
            .put("command", (data["expanded"] as String).take(800))
            .put("chat", data["chat"]).put("revision", data["revision"]).put("notification_id", data["id"])

    fun approvalPreview(command: String, largeText: Boolean): String {
        val preview = command.lineSequence().first().take(if (largeText) 60 else 120)
        return if (preview.length < command.length) "$preview…" else preview
    }

    fun visibleActions(data: Map<*, *>, largeText: Boolean): List<String> {
        val choices = data["choices"] as? List<*> ?: emptyList<String>()
        if (data["kind"] != "approval" || data["preview"] != true || choices.isEmpty()) {
            return if ((data["pending"] as? String).orEmpty().isNotEmpty()) listOf("review") else emptyList()
        }
        if (data["submitting"] == true) return emptyList()
        val command = data["expanded"] as String
        val needsReview = command.length > 40 || command.contains('\n') ||
            command.isBlank() || command.endsWith("…") || largeText
        return buildList {
            if (!needsReview && choices.contains("once")) add("once")
            if (needsReview || choices.any { it == "session" || it == "always" }) add("review")
            if (choices.contains("deny")) add("deny")
        }
    }

    const val maxChars = 64 * 1024
    private val choices = setOf("", "once", "session", "always", "deny")

    fun parse(raw: String?): JSONObject? = try {
        if (raw == null || raw.length > maxChars) null else {
            val value = JSONObject(raw)
            if (valid(value)) value else null
        }
    } catch (_: Exception) { null }

    private fun string(value: JSONObject, key: String, limit: Int, nonempty: Boolean = false): Boolean {
        val item = value.opt(key)
        return item is String && item.length <= limit && (!nonempty || item.isNotEmpty())
    }

    private fun valid(value: JSONObject): Boolean {
        if (value.opt("dismiss") == true) {
            return value.keys().asSequence().all { it in setOf("dismiss", "chat", "revision", "interaction_id") } &&
                string(value, "chat", 16 * 1024, true) && string(value, "revision", 2048, true) &&
                (!value.has("interaction_id") || string(value, "interaction_id", 36, true))
        }
        if (!value.keys().asSequence().all { it in setOf("payload", "choice", "review", "command", "chat", "revision", "notification_id") } ||
            !string(value, "payload", 32 * 1024) || value.opt("choice") !in choices ||
            value.opt("review") !is Boolean) return false
        if (!string(value, "command", 800)) return false
        if (value.has("notification_id") && value.opt("notification_id") !is Int) return false
        for (key in listOf("chat", "revision")) {
            if (value.has(key) && !value.isNull(key) && !string(value, key, if (key == "chat") 16 * 1024 else 2048)) return false
        }
        val payload = value.getString("payload")
        if (payload.isEmpty()) return value.getString("choice").isEmpty()
        val target = JSONObject(payload)
        if (!listOf("connection", "connection_identity").all { string(target, it, 4096, true) }) return false
        if (target.has("room")) {
            if (!string(target, "room", 4096, true) || target.has("session") || target.has("profile") ||
                value.getString("choice") !in setOf("", "once", "deny")) return false
        } else if (!listOf("profile", "session").all { string(target, it, 4096, true) }) return false
        val focus = target.optJSONObject("focus")
        if (focus != null) {
            if (target.has("room")) {
                when (focus.opt("kind")) {
                    "answer" -> if (value.getString("choice").isNotEmpty() || value.getBoolean("review")) return false
                    "approval" -> {
                        val identity = try { JSONArray(focus.optString("id")) } catch (_: Exception) { return false }
                        if (identity.length() != 4 || !(0..2).all { identity.opt(it) is String && identity.getString(it).isNotEmpty() } ||
                            identity.opt(3) !is Int || identity.getInt(3) < 1) return false
                    }
                    else -> return false
                }
            }
            if (focus.opt("kind") !in setOf("answer", "side", "background", "approval", "question", "secure", "status") ||
                !string(focus, "id", 4096, true)) return false
            if (focus.has("message_id") && focus.opt("message_id") !is Int && focus.opt("message_id") !is Long) return false
        } else if (target.has("focus") || (target.has("room") &&
            (value.getString("choice").isNotEmpty() || value.getBoolean("review")))) return false
        return value.getString("choice").isEmpty() || focus?.opt("kind") == "approval"
    }
}

/** Opaque interaction authorizations and bounded conversation shortcut identities.
 * Decisions and activity handoffs are single-use. Shortcut tokens only navigate;
 * the Dart router revalidates their captured connection before opening a chat.
 */
internal class NotificationHandleStore(
    private val read: () -> String?,
    private val write: (String) -> Boolean,
    private val now: () -> Long = System::currentTimeMillis,
) {
    companion object {
        const val actionPurpose = "action"
        const val mainPurpose = "main"
        const val navigationPurpose = "navigation"
        const val dismissPurpose = "dismiss"
        private const val maxHandles = 512
        private const val maxStoredChars = 4 * 1024 * 1024
        private val tokenPattern = Regex("[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}")
    }

    private fun entries(): MutableList<JSONObject> = try {
        val raw = read()
        if (raw == null || raw.length > maxStoredChars) mutableListOf() else {
            val array = JSONArray(raw)
            if (array.length() > maxHandles) mutableListOf() else (0 until array.length()).mapNotNull { index ->
                val entry = array.optJSONObject(index) ?: return@mapNotNull null
                val expires = entry.opt("expires")
                if (expires !is Long && expires !is Int) return@mapNotNull null
                val value = entry.optJSONObject("value") ?: return@mapNotNull null
                if (!tokenPattern.matches(entry.optString("token")) ||
                    entry.opt("purpose") !in setOf(actionPurpose, mainPurpose, dismissPurpose, navigationPurpose) ||
                    entry.opt("notification") !is Int || entry.getLong("expires") <= now() ||
                    NotificationInteractionSchema.parse(value.toString()) == null) null else entry
            }.toMutableList()
        }
    } catch (_: Exception) { mutableListOf() }

    @Synchronized fun issue(notification: Int, purpose: String, value: JSONObject): String? {
        if (purpose !in setOf(actionPurpose, mainPurpose, dismissPurpose, navigationPurpose) || NotificationInteractionSchema.parse(value.toString()) == null) return null
        if (purpose == navigationPurpose && value.optString("choice").isNotEmpty()) return null
        val entries = entries()
        if (purpose == navigationPurpose) {
            val existing = entries.firstOrNull {
                it.optString("purpose") == navigationPurpose && it.optInt("notification") == notification &&
                    it.getJSONObject("value").optString("chat") == value.optString("chat")
            }
            if (existing != null) {
                existing.put("value", JSONObject(value.toString()))
                val raw = JSONArray(entries).toString()
                return if (raw.length <= maxStoredChars && write(raw)) existing.getString("token") else null
            }
        }
        while (entries.size >= maxHandles) entries.removeAt(0)
        val token = UUID.randomUUID().toString()
        val ttl = if (purpose == mainPurpose) 5 * 60 * 1000L else 7 * 24 * 60 * 60 * 1000L
        entries.add(JSONObject().put("token", token).put("purpose", purpose).put("notification", notification)
            .put("expires", if (purpose == navigationPurpose) Long.MAX_VALUE else now() + ttl)
            .put("value", JSONObject(value.toString())))
        var raw = JSONArray(entries).toString()
        while (raw.length > maxStoredChars && entries.size > 1) {
            entries.removeAt(0)
            raw = JSONArray(entries).toString()
        }
        return if (raw.length <= maxStoredChars && write(raw)) token else null
    }

    @Synchronized fun consume(token: String?, purpose: String): JSONObject? {
        if (token == null || token.length != 36 || !tokenPattern.matches(token)) return null
        val entries = entries()
        val index = entries.indexOfFirst { it.optString("token") == token && it.optString("purpose") == purpose }
        if (index < 0) return null
        val entry = entries.removeAt(index)
        // Never deliver an action unless its deletion is durably acknowledged.
        return if (write(JSONArray(entries).toString())) entry.getJSONObject("value") else null
    }

    @Synchronized fun readNavigation(token: String?): JSONObject? {
        if (token == null || token.length != 36 || !tokenPattern.matches(token)) return null
        return entries().firstOrNull {
            it.optString("token") == token && it.optString("purpose") == navigationPurpose &&
                it.getJSONObject("value").optString("choice").isEmpty()
        }?.getJSONObject("value")
    }

    // Android can capture a PendingIntent before replacement, then start its
    // activity after replacement. Navigation carries no decision authority and
    // must survive both sides of that handoff. Tokens stay bounded/single-use.
    private fun navigation(entry: JSONObject): Boolean =
        entry.optString("purpose") in setOf(actionPurpose, mainPurpose) &&
            entry.getJSONObject("value").optString("choice").isEmpty()

    private fun retainNavigation(entry: JSONObject): JSONObject {
        if (navigation(entry) && entry.optString("purpose") == actionPurpose) {
            entry.put("expires", minOf(entry.getLong("expires"), now() + 5 * 60 * 1000L))
        }
        return entry
    }

    @Synchronized fun invalidate(notification: Int): Boolean =
        write(JSONArray(entries().mapNotNull { entry ->
            when {
                entry.optInt("notification") != notification || entry.optString("purpose") == navigationPurpose -> entry
                navigation(entry) -> retainNavigation(entry)
                else -> null
            }
        }).toString())

    @Synchronized fun replace(notification: Int, payload: String?, revision: String?): Boolean =
        write(JSONArray(entries().mapNotNull { entry ->
            when {
                entry.optInt("notification") != notification || entry.optString("purpose") == navigationPurpose -> entry
                navigation(entry) -> retainNavigation(entry)
                // Locked approval review still requires the exact revision.
                entry.optString("purpose") == mainPurpose &&
                    entry.getJSONObject("value").optString("payload") == payload &&
                    entry.getJSONObject("value").optString("revision") == revision -> entry
                else -> null
            }
        }).toString())
}

/** External shares must carry a read grant and resolve to a different app's provider. */
internal object ExternalShareUriPolicy {
    fun allows(scheme: String?, authority: String?, providerPackage: String?, ownPackage: String, granted: Boolean): Boolean =
        scheme == "content" && !authority.isNullOrBlank() && !authority.contains('@') &&
            !providerPackage.isNullOrBlank() && providerPackage != ownPackage && granted
}
