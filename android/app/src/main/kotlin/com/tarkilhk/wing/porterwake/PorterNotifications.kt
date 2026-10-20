package com.tarkilhk.wing.porterwake

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.tarkilhk.wing.ChatNotifications
import com.tarkilhk.wing.R
import org.json.JSONObject

object PorterNotifications {
    private const val id = 214700
    private val buttonIds by lazy { listOf(R.id.porter_b0, R.id.porter_b1, R.id.porter_b2, R.id.porter_b3) }

    fun cancel(context: Context) = context.getSystemService(NotificationManager::class.java).cancel(id)

    private fun intent(context: Context, data: Map<*, *>, action: String, value: String?): PendingIntent {
        val event = JSONObject()
            .put("type", "interaction").put("connection", data["connection"]).put("notice_id", data["notice_id"])
            .put("action", action).put("value", value).put("open_profile", data["open_profile"])
            .put("neutral", data["neutral"] == true)
        val identity = Uri.Builder().scheme("wing-porter").authority("action")
            .appendPath(data["notice_id"].toString()).appendPath(action).appendPath(value ?: "").build()
        val target = Intent(context, PorterActionActivity::class.java).setData(identity)
            .putExtra(PorterWakeNative.extra, event.toString())
        return PendingIntent.getActivity(context, 0, target, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun show(context: Context, data: Map<*, *>) {
        ChatNotifications.createChannels(context)
        val title = data["title"] as String
        val body = data["body"] as String
        val expanded = data["expanded"] as String
        val buttons = (data["buttons"] as List<*>).map { it as Map<*, *> }
        val builder = NotificationCompat.Builder(context, data["channel"] as String)
            .setSmallIcon(R.drawable.ic_stat_wing_input).setContentTitle(title)
            .setContentText(body).setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(NotificationCompat.Builder(context, data["channel"] as String)
                .setSmallIcon(R.drawable.ic_stat_wing_input).setContentTitle("Wing").build())
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setContentIntent(intent(context, data, "open", null))
        if (buttons.size > 3) {
            val large = context.resources.configuration.fontScale > 1.3f
            val views = RemoteViews(context.packageName,
                if (large) R.layout.notification_porter_grid else R.layout.notification_porter_row)
            views.setTextViewText(R.id.porter_title, title)
            views.setTextViewText(R.id.porter_text, expanded)
            buttonIds.forEachIndexed { index, viewId ->
                val button = buttons.getOrNull(index)
                views.setViewVisibility(viewId, if (button == null) View.GONE else View.VISIBLE)
                if (button != null) {
                    views.setTextViewText(viewId, button["label"] as String)
                    views.setOnClickPendingIntent(viewId,
                        intent(context, data, button["action"] as String, button["value"] as String))
                }
            }
            builder.setStyle(NotificationCompat.DecoratedCustomViewStyle()).setCustomBigContentView(views)
        } else {
            if (expanded.isNotEmpty()) builder.setStyle(NotificationCompat.BigTextStyle().bigText(expanded))
            for (button in buttons) {
                builder.addAction(0, button["label"] as String,
                    intent(context, data, button["action"] as String, button["value"] as String))
            }
        }
        NotificationManagerCompat.from(context).notify(id, builder.build())
    }
}
