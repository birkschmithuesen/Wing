package com.tarkilhk.wing

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Hands an unchanged mailto URI to the user's chosen email app. */
class EmailComposerChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.tarkilhk.wing/email")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "compose") {
                result.notImplemented()
            } else {
                val uri = (call.arguments as? String)?.let(Uri::parse)?.normalizeScheme()
                if (uri?.scheme != "mailto") {
                    result.success(false)
                } else {
                    val intent = Intent(Intent.ACTION_SENDTO, uri)
                    try {
                        if (intent.resolveActivity(activity.packageManager) == null) {
                            result.success(false)
                        } else {
                            activity.startActivity(Intent.createChooser(intent, "Send email"))
                            result.success(true)
                        }
                    } catch (_: ActivityNotFoundException) {
                        result.success(false)
                    } catch (_: SecurityException) {
                        result.success(false)
                    }
                }
            }
        }
    }

    fun close() = channel.setMethodCallHandler(null)
}
