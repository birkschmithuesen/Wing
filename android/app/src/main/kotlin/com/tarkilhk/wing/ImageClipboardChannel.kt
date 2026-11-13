package com.tarkilhk.wing

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CancellationException

/** Reads clipboard content only after an explicit Paste action. */
class ImageClipboardChannel(messenger: BinaryMessenger, activity: Activity) {
    private val channel = MethodChannel(messenger, "com.tarkilhk.wing/image_clipboard")
    private val clipboard = activity.applicationContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private val resolver = activity.applicationContext.contentResolver
    private val reader = ImageClipboardReader({ action -> Handler(Looper.getMainLooper()).post(action) })

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasImage" -> {
                    // Description access does not read the clipboard payload.
                    val hasImage = try {
                        clipboard.primaryClipDescription?.hasMimeType("image/*") == true
                    } catch (_: Exception) {
                        false
                    }
                    result.success(hasImage)
                }
                "readImage" -> {
                    try {
                        val clip = clipboard.primaryClip
                        val uri = (0 until (clip?.itemCount ?: 0))
                            .mapNotNull { clip?.getItemAt(it)?.uri }
                            .firstOrNull { it.scheme == "content" }
                        if (uri == null) {
                            result.error("image_unavailable", "The clipboard image is no longer available. Copy it again.", null)
                        } else {
                            readImage(uri, result)
                        }
                    } catch (_: Exception) {
                        result.error("image_unavailable", "Unable to read the clipboard image. Copy it again.", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun readImage(uri: Uri, result: MethodChannel.Result) {
        val capturedResolver = resolver
        val admitted = reader.read({ capturedResolver.openInputStream(uri) }) { bytes, error ->
            if (error == null) {
                result.success(bytes)
            } else {
                val message = when {
                    error is SecurityException ->
                        "This clipboard image is no longer accessible. Copy it again, or insert it from your keyboard."
                    error is CancellationException ->
                        "Clipboard reading was cancelled or took too long. Copy the image again."
                    error.message == "too_large" ->
                        "The clipboard image exceeds the 64 MiB image input limit."
                    else ->
                        "Unable to read the clipboard image. Copy a JPEG, PNG, or WebP image again."
                }
                result.error("image_unavailable", message, null)
            }
        }
        if (!admitted) result.error("image_unavailable", "Clipboard reading is busy. Try again shortly.", null)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        reader.dispose()
    }
}
