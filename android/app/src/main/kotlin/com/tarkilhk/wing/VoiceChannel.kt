package com.tarkilhk.wing

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import com.tarkilhk.wing.voiceoffline.VoiceOfflineHandler
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class VoiceChannel(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        const val PERMISSION_REQUEST = 7314
        // Android returns only a request code even after Activity recreation.
        // A retired channel cannot free the process slot before that callback.
        private val permissions = VoicePermissionRequests<Permission>()
    }
    private val channel = MethodChannel(messenger, "com.tarkilhk.wing/voice")
    private val capture = VoiceCapture(activity, ::emit)
    private val playback = VoicePlayback(activity, ::emit, keepsVoice = { offline.keepsVoice() })
    private val offline = VoiceOfflineHandler(activity, messenger, ::emit)
    private var closed = false
    private val replies = mutableSetOf<Reply>()
    private class Permission(val owner: VoiceChannel, val call: MethodCall, val reply: Reply)
    private inner class Reply(private val delegate: MethodChannel.Result) : MethodChannel.Result {
        private val once = VoiceReply<() -> Unit> { action, _ -> replies.remove(this); action?.invoke() }
        private fun finish(action: () -> Unit) { once.settle(action) }
        override fun success(result: Any?) = finish { delegate.success(result) }
        override fun error(code: String, message: String?, details: Any?) = finish { delegate.error(code, message, details) }
        override fun notImplemented() = finish { delegate.notImplemented() }
    }
    init {
        // Preparation and process-death file cleanup run once on the same owned
        // transfer thread, before current-process files can be created.
        VoiceFileWork.process.prepare(voicePath(activity))
        channel.setMethodCallHandler(::handle)
    }
    private fun emit(event: Map<String, Any>) { if (!closed) channel.invokeMethod("event", event) }
    private fun handle(call: MethodCall, rawResult: MethodChannel.Result) {
        val result = Reply(rawResult)
        replies.add(result)
        if (closed) { result.error("cancelled", "Voice channel closed.", null); return }
        try {
            if (LiveVoiceRuntime.audioOwned && call.method in listOf("start", "startVad", "openMicLink", "speak", "play")) {
                result.error("voice_busy", "End the voice conversation before using other audio.", null)
                return
            }
            val id = call.argument<String>("id").orEmpty()
            when (call.method) {
                "requestLivePermissions" -> {
                    val audio = activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
                    val bluetooth = android.os.Build.VERSION.SDK_INT < 31 ||
                        activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
                    if (audio && bluetooth) result.success(true) else requestPermission(call, result)
                }
                "requestPermission" -> {
                    if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) result.success(true)
                    else requestPermission(call, result)
                }
                "capabilities" -> capture.languages { languages -> playback.withTts { ready ->
                    result.success(mapOf("recognitionAvailable" to capture.available(), "languages" to languages,
                        "voices" to if (ready) playback.voiceChoices() else emptyList<Map<String, String>>()))
                } }
                "start", "startVad" -> {
                    check(id.isNotEmpty()) { "Missing capture ID." }
                    if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) requestPermission(call, result)
                    else start(call, result)
                }
                "stop" -> capture.stop(id, call.argument<Number>("timeoutMs")?.toLong() ?: 5000L) { bytes, error ->
                    if (error == null) result.success(bytes)
                    else result.error("voice_unavailable", error.message ?: "Could not finish recording.", null)
                }
                "cancel" -> {
                    permissions.current?.takeIf { it.value?.owner === this && it.value?.call?.argument<String>("id") == id }?.let {
                        val pending = it.value
                        it.cancel()
                        pending?.reply?.error("cancelled", "Recording cancelled.", null)
                        // Keep the Android request-code slot until its actual
                        // callback; a cancelled request cannot rebound to a new ID.
                    }
                    offline.cancel(id); capture.cancel(id); result.success(null)
                }
                "speak" -> playback.speak(id, call.argument<String>("text").orEmpty(),
                    call.argument<String>("voice").orEmpty(), call.argument<Number>("rate")?.toFloat() ?: 1f,
                    call.argument<List<Map<String, String>>>("segments"), result)
                "play" -> playback.play(id, call.argument<ByteArray>("bytes") ?: error("Missing audio."), result)
                "stopPlayback" -> { playback.stop(id); result.success(null) }
                else -> if (!offline.handle(call, result)) result.notImplemented()
            }
        } catch (error: Exception) { result.error("voice_unavailable", error.message ?: "Voice is unavailable.", null) }
    }
    private fun requestPermission(call: MethodCall, result: Reply) {
        permissions.begin(Permission(this, call, result))
        val requested = if (call.method == "requestLivePermissions" && android.os.Build.VERSION.SDK_INT >= 31)
            arrayOf(Manifest.permission.RECORD_AUDIO, Manifest.permission.BLUETOOTH_CONNECT)
            else arrayOf(Manifest.permission.RECORD_AUDIO)
        try { activity.requestPermissions(requested, PERMISSION_REQUEST) }
        catch (error: Exception) { permissions.finish(); throw error }
    }
    private fun start(call: MethodCall, result: MethodChannel.Result) {
        if (closed) { result.error("cancelled", "Voice channel closed.", null); return }
        // Barge-in listen rounds record while Wing reads aloud.
        if (call.argument<Boolean>("keepPlayback") != true) playback.stop(force = true)
        val id = call.argument<String>("id")!!
        if (call.method == "startVad") { capture.cancel(id); offline.startVad(id, call, result); return }
        offline.cancel(id)
        capture.start(id, call.argument<Boolean>("local") == true,
            call.argument<String>("language").orEmpty()) { error ->
            if (error == null) result.success(null)
            else result.error("voice_unavailable", error.message ?: "Could not start recording.", null)
        }
    }
    fun permissionResult(requestCode: Int, grants: IntArray): Boolean {
        if (offline.permissionResult(requestCode, grants)) return true
        if (requestCode != PERMISSION_REQUEST) return false
        // A stale callback on a retired channel cannot consume another live
        // channel's newly admitted request. A cancelled payload is already
        // cleared and may be consumed by the recreated Activity's OS callback.
        if (permissions.current?.value?.owner?.let { it !== this } == true) return true
        val permission = permissions.finish()
        if (permission == null || permission.cancelled || closed) return true
        val request = permission.value ?: return true
        if (request.call.method in listOf("requestPermission", "requestLivePermissions")) {
            request.reply.success(grants.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        } else if (grants.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            try { start(request.call, request.reply) }
            catch (error: Exception) { request.reply.error("voice_unavailable", error.message, null) }
        } else request.reply.error("permission_denied", "Allow microphone access in Android app permissions to record your voice.", null)
        return true
    }
    fun pause() {
        if (closed) return
        // Android's permission dialog pauses the Activity while it remains visible.
        capture.pause(); playback.stop()
    }
    /** Fork (Wing Voice): VAD/media-key pause, separate from the guarded pause(). */
    fun pauseOffline() {
        if (closed) return
        if (!offline.keepsVoice()) offline.pauseVad()
        offline.pauseMediaKeys()
    }
    fun resume() {
        if (!closed) offline.resume()
    }
    fun leaveForeground() {
        if (closed) return
        permissions.current?.takeIf { it.value?.owner === this }?.let {
            val pending = it.value
            it.cancel()
            pending?.reply?.error("cancelled", "Voice request left the foreground.", null)
        }
        // A grant can arrive after onPause but before the Activity becomes hidden.
        pause()
    }
    fun close() {
        if (closed) return
        closed = true
        offline.closeRoutes()
        replies.toList().forEach { it.error("cancelled", "Voice channel closed.", null) }
        permissions.current?.takeIf { it.value?.owner === this }?.cancel()
        offline.closeKeys()
        capture.close(); playback.close(); offline.close(); channel.setMethodCallHandler(null)
    }
}
