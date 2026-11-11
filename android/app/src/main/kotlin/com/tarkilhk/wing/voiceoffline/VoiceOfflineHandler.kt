package com.tarkilhk.wing.voiceoffline

import android.app.Activity
import android.view.WindowManager
import com.tarkilhk.wing.OfflineSpeech
import com.tarkilhk.wing.SpeechModelStore
import com.tarkilhk.wing.VadCapture
import com.tarkilhk.wing.VoiceDebugStore
import com.tarkilhk.wing.VoiceMediaKeys
import com.tarkilhk.wing.voicebackground.BackgroundVoiceChannel
import com.tarkilhk.wing.voicebackground.BackgroundVoiceService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CancellationException

/** Fork-only voice calls (VAD dictation, offline speech models, headset routes, media keys),
 *  kept out of the upstream-owned VoiceChannel. */
class VoiceOfflineHandler(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val emit: (Map<String, Any>) -> Unit,
) {
    private val models = SpeechModelStore(activity, emit)
    private val speech = OfflineSpeech(models)
    private val debugStore = VoiceDebugStore(activity)
    private val micRoute = HeadsetMicRoute(activity)
    private val vad = VadCapture(activity, models, speech, debugStore, micRoute, emit)
    private val mediaKeys = VoiceMediaKeys(activity, emit)
    private val background = BackgroundVoiceChannel(activity, messenger)
    private val route = HeadphoneRouteChannel(activity, messenger)

    /** Handles fork-only voice calls; returns false for calls it does not own.
     *  "startVad" is routed by VoiceChannel itself (it shares the mic-permission request). */
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        val id = call.argument<String>("id").orEmpty()
        when (call.method) {
            "finishVad" -> vad.finish(id, call.argument<Int>("startWindow") ?: 0, call.argument<Int>("endWindow") ?: 0,
                call.argument<Int>("atWindow") ?: 0, call.argument<String>("reason").orEmpty(),
                call.argument<Map<String, Any?>>("config") ?: emptyMap(), call.argument<List<List<Int>>>("chunks"), result)
            "deleteVadDebugRecordings" -> result.success(debugStore.deleteAll())
            "vadModelStatus" -> result.success(models.status())
            "installVadModel" -> { models.install(); result.success(null) }
            "cancelVadModelInstall" -> { models.cancel(); result.success(null) }
            "removeVadModel" -> { speech.release(); models.remove(); result.success(null) }
            "prepareVad" -> { if (models.verifyManifest() == null) speech.prepare(); result.success(null) }
            "releaseVad" -> { speech.release(); result.success(null) }
            "openMicLink" -> micRoute.openLink { ready -> result.success(ready) }
            "closeMicLink" -> { micRoute.closeLink(); result.success(null) }
            "setMediaKeys" -> { mediaKeys.enable(call.argument<Boolean>("on") == true); result.success(null) }
            "keepScreenOn" -> {
                if (call.argument<Boolean>("on") == true) activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                result.success(null)
            }
            else -> return false
        }
        return true
    }

    /** The "startVad" half of VoiceChannel.start (permission already granted). */
    fun startVad(id: String, call: MethodCall, result: MethodChannel.Result) {
        val cues = call.argument<Boolean>("cues") != false
        val options = VadCapture.Options(
            cues = cues,
            debug = call.argument<Boolean>("debug") == true,
            source = call.argument<String>("source") ?: "communication",
            maxMs = call.argument<Int>("maxMs") ?: 600_000,
            startCue = call.argument<Boolean>("startCue") ?: cues,
            mic = call.argument<String>("mic") ?: "auto",
            holdMic = call.argument<Boolean>("holdMic") == true,
        )
        val begin = {
            try {
                vad.start(id, options) { failure, fallback ->
                    when (failure) {
                        null -> result.success(fallback)
                        is CancellationException -> result.error("cancelled", "Recording cancelled.", null)
                        else -> result.error("voice_unavailable", failure.message ?: "Voice is unavailable.", null)
                    }
                }
            } catch (error: Exception) { result.error("voice_unavailable", error.message ?: "Voice is unavailable.", null) }
        }
        // Spec §3 F1: the first explicit recording with Bluetooth audio asks for Nearby devices once.
        // "bluetooth" is a manual preference for that same link, so it asks too; "phone" and "wired" never need it.
        if ((options.mic == "auto" || options.mic == "bluetooth") && micRoute.needsPermission()) micRoute.requestOnce(begin) else begin()
    }

    fun cancel(id: String) { vad.cancel(id) }

    fun permissionResult(requestCode: Int, grants: IntArray): Boolean {
        if (requestCode == HeadsetMicRoute.PERMISSION_REQUEST) { micRoute.permissionResult(grants); route.refresh(); return true }
        if (requestCode == HeadphoneRouteChannel.PERMISSION_REQUEST) { route.permissionResult(grants); return true }
        return false
    }

    /** True when the background voice service keeps the mic (BackgroundVoiceService.keepsVoice()). */
    fun keepsVoice(): Boolean = BackgroundVoiceService.keepsVoice()
    fun pauseVad() { vad.pause() }
    fun pauseMediaKeys() { mediaKeys.pause() }
    fun resume() { mediaKeys.resume() }
    fun closeRoutes() { background.close(); route.close() }
    fun closeKeys() { mediaKeys.close(); activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    fun close() { vad.close(); micRoute.close(); debugStore.close(); speech.close(); models.close() }
}
