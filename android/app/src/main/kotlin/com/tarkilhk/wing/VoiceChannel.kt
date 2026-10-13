package com.tarkilhk.wing

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class VoiceChannel(private val activity: Activity, messenger: BinaryMessenger) {
    companion object { const val PERMISSION_REQUEST = 7314 }
    private val channel = MethodChannel(messenger, "com.tarkilhk.wing/voice")
    private val capture = VoiceCapture(activity, ::emit)
    private val playback = VoicePlayback(activity, ::emit)
    private val models = SpeechModelStore(activity, ::emit)
    private val speech = OfflineSpeech(models)
    private val debugStore = VoiceDebugStore(activity)
    private val vad = VadCapture(activity, models, speech, debugStore, ::emit)
    private var pending: Pair<MethodCall, MethodChannel.Result>? = null
    init {
        // A previous process may have died before its normal cleanup.
        voiceDirectory(activity).listFiles()?.forEach { it.delete() }
        channel.setMethodCallHandler(::handle)
    }
    private fun emit(event: Map<String, Any>) { channel.invokeMethod("event", event) }
    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            val id = call.argument<String>("id").orEmpty()
            when (call.method) {
                "requestPermission" -> {
                    if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) result.success(true)
                    else {
                        check(pending == null) { "Wait for microphone permission." }
                        pending = call to result
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
                    }
                }
                "capabilities" -> capture.languages { languages -> playback.withTts { ready ->
                    result.success(mapOf("recognitionAvailable" to capture.available(), "languages" to languages,
                        "voices" to if (ready) playback.voiceChoices() else emptyList<Map<String, String>>()))
                } }
                "start" -> {
                    check(id.isNotEmpty()) { "Missing capture ID." }
                    if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        check(pending == null) { "Wait for microphone permission." }
                        pending = call to result
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
                    } else start(call, result)
                }
                "startVad" -> {
                    check(id.isNotEmpty()) { "Missing capture ID." }
                    if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        check(pending == null) { "Wait for microphone permission." }
                        pending = call to result
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
                    } else start(call, result)
                }
                "finishVad" -> vad.finish(id, call.argument<Int>("startWindow") ?: 0, call.argument<Int>("endWindow") ?: 0,
                    call.argument<Int>("atWindow") ?: 0, call.argument<String>("reason").orEmpty(),
                    call.argument<Map<String, Any?>>("config") ?: emptyMap(), result)
                "deleteVadDebugRecordings" -> result.success(debugStore.deleteAll())
                "stop" -> result.success(capture.stop(id))
                "cancel" -> {
                    if (pending?.first?.argument<String>("id") == id) {
                        pending?.second?.error("cancelled", "Recording cancelled.", null); pending = null
                    }
                    vad.cancel(id); capture.cancel(id); result.success(null)
                }
                "speak" -> playback.speak(id, call.argument<String>("text").orEmpty(),
                    call.argument<String>("voice").orEmpty(), call.argument<Number>("rate")?.toFloat() ?: 1f, result)
                "play" -> playback.play(id, call.argument<ByteArray>("bytes") ?: error("Missing audio."), result)
                "stopPlayback" -> { playback.stop(id); result.success(null) }
                "vadModelStatus" -> result.success(models.status())
                "installVadModel" -> { models.install(); result.success(null) }
                "cancelVadModelInstall" -> { models.cancel(); result.success(null) }
                "removeVadModel" -> { speech.release(); models.remove(); result.success(null) }
                "prepareVad" -> { if (models.verifyManifest() == null) speech.prepare(); result.success(null) }
                "releaseVad" -> { speech.release(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { result.error("voice_unavailable", error.message ?: "Voice is unavailable.", null) }
    }
    private fun start(call: MethodCall, result: MethodChannel.Result) {
        playback.stop()
        val id = call.argument<String>("id")!!
        if (call.method == "startVad") {
            capture.cancel(id)
            vad.start(id, VadCapture.Options(
                cues = call.argument<Boolean>("cues") != false,
                debug = call.argument<Boolean>("debug") == true,
                source = call.argument<String>("source") ?: "communication",
                maxMs = call.argument<Int>("maxMs") ?: 120_000,
            ))
        } else {
            vad.cancel(id)
            capture.start(id, call.argument<Boolean>("local") == true, call.argument<String>("language").orEmpty())
        }
        result.success(null)
    }
    fun permissionResult(requestCode: Int, grants: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val request = pending; pending = null
        if (request != null) {
            if (request.first.method == "requestPermission") {
                request.second.success(grants.firstOrNull() == PackageManager.PERMISSION_GRANTED)
                return true
            }
            if (grants.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
                try { start(request.first, request.second) }
                catch (error: Exception) { request.second.error("voice_unavailable", error.message, null) }
            } else request.second.error("permission_denied", "Allow microphone access in Android app permissions to record your voice.", null)
        }
        return true
    }
    fun pause() { capture.pause(); vad.pause(); playback.stop() }
    fun close() {
        pending?.second?.error("cancelled", "Recording cancelled.", null); pending = null
        capture.close(); playback.close(); vad.close(); debugStore.close(); speech.close(); models.close(); channel.setMethodCallHandler(null)
    }
}
