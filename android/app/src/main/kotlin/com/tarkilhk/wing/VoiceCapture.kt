package com.tarkilhk.wing

import android.app.Activity
import android.content.Intent
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import java.io.File
import java.util.Locale

/** One capture at a time. Local prefers Android's on-device recognizer and falls back to the
 *  default RecognitionService (e.g. an offline third-party recognizer set as system voice input). */
class VoiceCapture(private val activity: Activity, private val emit: (Map<String, Any>) -> Unit) {
    private val handler = Handler(Looper.getMainLooper())
    private var id: String? = null
    private var recognizer: SpeechRecognizer? = null
    private var recorder: MediaRecorder? = null
    private var file: File? = null
    private var deadline: Runnable? = null
    private var probe: SpeechRecognizer? = null
    private var finishProbe: (() -> Unit)? = null

    private fun onDevice() = Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)
    fun available() = onDevice() || SpeechRecognizer.isRecognitionAvailable(activity)
    private fun recognizer() = if (onDevice()) SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
        else SpeechRecognizer.createSpeechRecognizer(activity)

    private fun intent(language: String) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, language.ifBlank { Locale.getDefault().toLanguageTag() })
    }

    fun languages(callback: (List<String>?) -> Unit) {
        if (Build.VERSION.SDK_INT < 33 || !onDevice()) { callback(null); return }
        finishProbe?.invoke()
        var complete = false
        var timeout: Runnable? = null
        fun finish(languages: List<String>?) {
            if (complete) return
            complete = true
            timeout?.let { handler.removeCallbacks(it) }
            probe?.destroy(); probe = null; finishProbe = null
            callback(languages)
        }
        finishProbe = { finish(null) }
        timeout = Runnable { finish(null) }
        handler.postDelayed(timeout!!, 3000)
        try {
            probe = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity).also {
                it.checkRecognitionSupport(intent(""), activity.mainExecutor, object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) = finish(support.installedOnDeviceLanguages.sorted())
                    override fun onError(error: Int) = finish(null)
                })
            }
        } catch (_: Exception) { finish(null) }
    }

    fun start(owner: String, local: Boolean, language: String) {
        clear()
        id = owner
        try {
            if (local) {
                check(available()) { "On-device recognition is unavailable. Android 12 or later and a supported speech service are required. Choose Hermes in App settings or install a local recognition service." }
                recognizer = recognizer().also { speech ->
                    speech.setRecognitionListener(object : RecognitionListener {
                        override fun onReadyForSpeech(params: Bundle?) {}
                        override fun onBeginningOfSpeech() {}
                        override fun onRmsChanged(rmsdB: Float) {}
                        override fun onBufferReceived(buffer: ByteArray?) {}
                        override fun onEndOfSpeech() {}
                        override fun onEvent(eventType: Int, params: Bundle?) {}
                        override fun onError(error: Int) {
                            if (id != owner) return
                            fail(when (error) {
                                SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech detected. Try again."
                                SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "This recognition language is not installed or supported on this phone. Install its offline language data in Android settings or select another language."
                                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone access was denied. Allow it in Android app permissions."
                                else -> "On-device recognition failed ($error). Please retry."
                            })
                        }
                        override fun onResults(results: Bundle?) = transcript(owner, results, true)
                        override fun onPartialResults(results: Bundle?) = transcript(owner, results, false)
                    })
                    speech.startListening(intent(language))
                }
            } else {
                file = File.createTempFile("capture-", ".m4a", voiceDirectory(activity))
                @Suppress("DEPRECATION")
                val capture = MediaRecorder()
                recorder = capture
                capture.setAudioSource(MediaRecorder.AudioSource.MIC)
                capture.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                capture.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                capture.setAudioSamplingRate(44100)
                capture.setAudioEncodingBitRate(96000)
                capture.setMaxDuration(120000)
                capture.setMaxFileSize(25L * 1024 * 1024)
                capture.setOnInfoListener { _, what, _ ->
                    if (id == owner && (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED || what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED)) {
                        emit(mapOf("id" to owner, "limit" to true))
                    }
                }
                capture.setOnErrorListener { _, _, _ -> if (id == owner) fail("Microphone recording failed. Please retry.") }
                capture.setOutputFile(file!!.absolutePath)
                capture.prepare(); capture.start()
            }
            deadline = Runnable { if (id == owner) fail("Recording reached its time limit. Please try a shorter recording.") }
            handler.postDelayed(deadline!!, 125000)
        } catch (error: Exception) { clear(); throw error }
    }

    fun stop(owner: String, timeoutMs: Long = 5000L): ByteArray? {
        if (id != owner) return null
        if (recognizer != null) {
            recognizer?.stopListening()
            deadline?.let { handler.removeCallbacks(it) }
            deadline = Runnable { if (id == owner) fail("Recognition did not finish. Please retry.") }
            handler.postDelayed(deadline!!, timeoutMs)
            return null
        }
        try {
            recorder?.stop(); recorder?.release(); recorder = null
            val recording = file ?: error("No recording is available.")
            check(recording.length() in 1..(25L * 1024 * 1024)) { "Recording is empty or too large." }
            return recording.readBytes()
        } catch (_: Exception) {
            error("Could not finish recording. Try speaking for longer.")
        } finally { clear() }
    }

    private fun transcript(owner: String, result: Bundle?, final: Boolean) {
        if (id != owner) return
        val text = cleanTranscript(result?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty())
        // Offline recognizers may send placeholder partials ("…") only to signal ongoing capture.
        if (!final && text.isEmpty()) return
        emit(mapOf("id" to owner, "text" to text, "final" to final))
        if (final) clear()
    }
    private fun fail(message: String) {
        id?.let { emit(mapOf("id" to it, "error" to message)) }
        clear()
    }
    fun cancel(owner: String) { if (id == owner) clear() }
    fun pause() { if (id != null) fail("Recording stopped because Wing left the foreground.") }
    private fun clear() {
        id = null
        deadline?.let { handler.removeCallbacks(it) }; deadline = null
        recognizer?.cancel(); recognizer?.destroy(); recognizer = null
        try { recorder?.stop() } catch (_: Exception) {}
        recorder?.release(); recorder = null
        file?.delete(); file = null
    }
    fun close() { clear(); finishProbe?.invoke() }
}

/** Drops heartbeat placeholders ("…"/"...") some offline recognizers emit as partial results. */
internal fun cleanTranscript(raw: String): String {
    val trimmed = raw.trim()
    if (trimmed.all { it == '…' || it == '.' || it.isWhitespace() }) return ""
    return trimmed.removePrefix("…").removePrefix("...").trim()
}

internal fun voiceDirectory(activity: Activity) = File(activity.cacheDir, "voice").apply { mkdirs() }
