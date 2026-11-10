package com.tarkilhk.wing

import android.content.Context
import android.view.accessibility.AccessibilityManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Uses the user's Android time-to-take-action preference for transient text. */
class AccessibilityTimeoutChannel(context: Context, messenger: BinaryMessenger) {
    private val accessibility = context.getSystemService(AccessibilityManager::class.java)
    private val channel = MethodChannel(messenger, "com.tarkilhk.wing/accessibility")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "recommendedTextTimeout") {
                result.notImplemented()
            } else {
                val base = call.arguments as? Int
                if (base == null || base <= 0) {
                    result.error("invalid_timeout", "A positive timeout is required.", null)
                } else {
                    result.success(accessibility.getRecommendedTimeoutMillis(
                        base,
                        AccessibilityManager.FLAG_CONTENT_TEXT or AccessibilityManager.FLAG_CONTENT_ICONS,
                    ))
                }
            }
        }
    }

    fun close() = channel.setMethodCallHandler(null)
}
