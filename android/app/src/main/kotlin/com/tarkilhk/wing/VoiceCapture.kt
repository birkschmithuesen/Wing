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
import com.tarkilhk.wing.voiceoffline.cleanTranscript
import com.tarkilhk.wing.voiceoffline.createRecognizer
import com.tarkilhk.wing.voiceoffline.onDeviceRecognition
import com.tarkilhk.wing.voiceoffline.recognitionAvailable
import java.util.Locale

/** Hard ceiling on a single hermes recording, in milliseconds. Spec/brainstorming
 *  sessions run 3-6 minutes; 600s leaves headroom above that. */
private const val MAX_RECORDING_MS = 600_000
private const val RECORDING_DEADLINE_BUFFER_MS = 5_000

/** One capture at a time. Local prefers Android's on-device recognizer and falls back to the
 *  default RecognitionService (e.g. an offline third-party recognizer set as system voice input). */
class VoiceCapture(private val activity: Activity, private val emit: (Map<String, Any>) -> Unit) {
    private val handler = Handler(Looper.getMainLooper())
    // Retired process-owned leases must not retain the Activity through this dispatcher.
    private val dispatchFile: (() -> Unit) -> Unit = handler.let { main -> { task -> main.post(task) } }
    private val operations = VoiceOperations()
    private var closed = false
    private var starting: VoiceReply<Unit>? = null
    private var stopping: VoiceReply<ByteArray>? = null
    private var recognizer: SpeechRecognizer? = null
    private var recorder: MediaRecorder? = null
    private var file: VoiceFileWork.Lease? = null
    private var deadline: Runnable? = null
    private var probe: SpeechRecognizer? = null
    private var finishProbe: (() -> Unit)? = null

    fun available() = !closed && recognitionAvailable(activity)

    private fun intent(language: String) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, language.ifBlank { Locale.getDefault().toLanguageTag() })
    }

    fun languages(callback: (List<String>?) -> Unit) {
        if (closed || Build.VERSION.SDK_INT < 33 || !onDeviceRecognition(activity)) { callback(null); return }
        finishProbe?.invoke()
        var complete = false
        var timeout: Runnable? = null
        fun finish(languages: List<String>?) {
            if (complete) return
            complete = true
            timeout?.let { handler.removeCallbacks(it) }
            val owned = probe; probe = null; finishProbe = null
            try { owned?.destroy() } catch (_: Exception) {}
            callback(languages)
        }
        finishProbe = { finish(null) }
        timeout = Runnable { finish(null) }
        handler.postDelayed(timeout, 3000)
        try {
            probe = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity).also {
                it.checkRecognitionSupport(intent(""), activity.mainExecutor, object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) = finish(support.installedOnDeviceLanguages.sorted())
                    override fun onError(error: Int) = finish(null)
                })
            }
        } catch (_: Exception) { finish(null) }
    }

    fun start(owner: String, local: Boolean, language: String, completed: (Exception?) -> Unit) {
        check(!closed) { "Voice capture is unavailable." }
        clear()
        val attempt = operations.begin(owner)
        val reply = VoiceReply<Unit> { _, error -> completed(error) }
        starting = reply
        fun started() {
            if (!operations.owns(attempt)) return
            starting = null
            arm(attempt, (MAX_RECORDING_MS + RECORDING_DEADLINE_BUFFER_MS).toLong(), "Recording reached its time limit. Please try a shorter recording.")
            reply.settle(Unit)
        }
        try {
            if (local) {
                check(available()) { "On-device recognition is unavailable. Android 12 or later and a supported speech service are required. Choose Hermes in App settings or install a local recognition service." }
                val speech = createRecognizer(activity)
                recognizer = speech
                speech.setRecognitionListener(object : RecognitionListener {
                    override fun onReadyForSpeech(params: Bundle?) {}
                    override fun onBeginningOfSpeech() {}
                    override fun onRmsChanged(rmsdB: Float) {}
                    override fun onBufferReceived(buffer: ByteArray?) {}
                    override fun onEndOfSpeech() {}
                    override fun onEvent(eventType: Int, params: Bundle?) {}
                    override fun onError(error: Int) {
                        if (!operations.owns(attempt)) return
                        if (error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) {
                            fail(attempt, "No speech detected", "no_speech")
                            return
                        }
                        fail(attempt, when (error) {
                            SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "This recognition language is not installed or supported on this phone. Install its offline language data in Android settings or select another language."
                            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone access was denied. Allow it in Android app permissions."
                            else -> "On-device recognition failed ($error). Please retry."
                        })
                    }
                    override fun onResults(results: Bundle?) = transcript(attempt, results, true)
                    override fun onPartialResults(results: Bundle?) = transcript(attempt, results, false)
                })
                speech.startListening(intent(language))
                started()
            } else {
                arm(attempt, 15000, "Recording preparation timed out. Please retry.")
                file = VoiceFileWork.process.create(voicePath(activity), "capture-", dispatch = dispatchFile) { lease, error ->
                    if (!operations.owns(attempt) || closed) { lease?.cancel(); return@create }
                    try {
                        if (error != null) throw error
                        @Suppress("DEPRECATION")
                        val capture = MediaRecorder()
                        recorder = capture
                        capture.setAudioSource(MediaRecorder.AudioSource.MIC)
                        capture.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                        capture.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                        capture.setAudioSamplingRate(44100)
                        capture.setAudioEncodingBitRate(96000)
                        capture.setMaxDuration(MAX_RECORDING_MS)
                        capture.setMaxFileSize(MAX_VOICE_BYTES.toLong())
                        capture.setOnInfoListener { recording, what, _ ->
                            if (operations.owns(attempt) && recorder === recording &&
                                (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED || what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED)) {
                                emit(mapOf("id" to owner, "limit" to true))
                            }
                        }
                        capture.setOnErrorListener { recording, _, _ ->
                            if (operations.owns(attempt) && recorder === recording) fail(attempt, "Microphone recording failed. Please retry.")
                        }
                        capture.setOutputFile(lease!!.path)
                        capture.prepare(); capture.start()
                        started()
                    } catch (failure: Exception) { fail(attempt, failure.message ?: "Could not start recording.") }
                }
            }
        } catch (error: Exception) { clear(error); reply.settle(error = error) }
    }

    fun stop(owner: String, timeoutMs: Long = 5000L, completed: (ByteArray?, Exception?) -> Unit) {
        val attempt = operations.current
        if (attempt == null || attempt.id != owner) { completed(null, null); return }
        val reply = VoiceReply<ByteArray>(completed)
        check(stopping == null) { "Recording transfer is already running." }
        if (recognizer != null) {
            try {
                recognizer?.stopListening()
                if (operations.owns(attempt)) arm(attempt, timeoutMs, "Recognition did not finish. Please retry.")
                stopping = null
                reply.settle()
            } catch (error: Exception) { clear(error); reply.settle(error = error) }
            return
        }
        stopping = reply
        try {
            check(starting == null && recorder != null) { "Recording has not started." }
            recorder!!.stop(); recorder!!.release(); recorder = null
            arm(attempt, 15000, "Recording transfer timed out. Please retry.")
            val recording = file ?: error("No recording is available.")
            recording.read { bytes, error ->
                if (!operations.owns(attempt) || closed) return@read
                stopping = null
                clear()
                reply.settle(bytes, error)
            }
        } catch (error: Exception) {
            stopping = null
            clear()
            reply.settle(error = error)
        }
    }

    private fun arm(attempt: VoiceOperation, millis: Long, message: String) {
        deadline?.let { handler.removeCallbacks(it) }
        deadline = Runnable { if (operations.owns(attempt)) fail(attempt, message) }
        handler.postDelayed(deadline!!, millis)
    }
    private fun transcript(attempt: VoiceOperation, result: Bundle?, final: Boolean) {
        if (!operations.owns(attempt)) return
        val text = cleanTranscript(result?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty())
        // Offline recognizers may send placeholder partials ("…") only to signal ongoing capture.
        if (!final && text.isEmpty()) return
        if (final) clear()
        emit(mapOf("id" to attempt.id, "text" to text, "final" to final))
    }
    private fun fail(attempt: VoiceOperation, message: String, code: String = "capture_failed") {
        if (!operations.owns(attempt)) return
        clear(IllegalStateException(message))
        emit(mapOf("id" to attempt.id, "error" to message, "code" to code))
    }
    fun cancel(owner: String) { if (operations.current?.id == owner) clear() }
    fun pause() { operations.current?.let { fail(it, "Recording stopped because Wing left the foreground.") } }
    private fun clear(error: Exception = java.util.concurrent.CancellationException("Recording cancelled.")) {
        operations.current?.let { operations.retire(it) }
        deadline?.let { handler.removeCallbacks(it) }; deadline = null
        val start = starting; starting = null
        val stop = stopping; stopping = null
        try { recognizer?.cancel() } catch (_: Exception) {}
        try { recognizer?.destroy() } catch (_: Exception) {}
        recognizer = null
        try { recorder?.stop() } catch (_: Exception) {}
        try { recorder?.release() } catch (_: Exception) {}
        recorder = null
        file?.cancel(); file = null
        start?.settle(error = error); stop?.settle(error = error)
    }
    fun close() { closed = true; clear(); finishProbe?.invoke() }
}

internal fun voicePath(activity: Activity) = activity.cacheDir.absolutePath + "/voice"
