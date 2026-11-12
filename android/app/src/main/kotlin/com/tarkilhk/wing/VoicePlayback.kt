package com.tarkilhk.wing

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.tarkilhk.wing.voiceoffline.LanguageSpeech
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class VoicePlayback(
    private val activity: Activity,
    private val emit: (Map<String, Any>) -> Unit,
    // Fork (Wing Voice): conversation mode keeps reading aloud while the Activity is paused.
    private val keepsVoice: () -> Boolean = { false },
) {
    private val handler = Handler(Looper.getMainLooper())
    // Retired process-owned leases must not retain the Activity through this dispatcher.
    private val dispatchFile: (() -> Unit) -> Unit = handler.let { main -> { task -> main.post(task) } }
    private val audio = activity.getSystemService(AudioManager::class.java)
    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private var focus: AudioFocusRequest? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var closed = false
    private var initialization = 0
    private var ttsDeadline: Runnable? = null
    private val waiters = mutableListOf<(Boolean) -> Unit>()
    private var player: MediaPlayer? = null
    private var file: VoiceFileWork.Lease? = null
    private val operations = VoiceOperations()
    private var result: MethodChannel.Result? = null
    private var timeout: Runnable? = null
    private var focusListener: AudioManager.OnAudioFocusChangeListener? = null
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) { stop(force = true) }
    }
    init {
        if (Build.VERSION.SDK_INT >= 33) activity.registerReceiver(noisyReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), Context.RECEIVER_NOT_EXPORTED)
        else { @Suppress("DEPRECATION") activity.registerReceiver(noisyReceiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)) }
    }

    fun withTts(callback: (Boolean) -> Unit) {
        if (closed) { callback(false); return }
        if (ttsReady) { callback(true); return }
        if (waiters.size >= 8) { callback(false); return }
        waiters.add(callback)
        if (tts != null) return
        val generation = ++initialization
        fun finish(ok: Boolean) {
            if (generation != initialization || closed) return
            initialization++
            ttsDeadline?.let { handler.removeCallbacks(it) }; ttsDeadline = null
            ttsReady = ok
            if (!ok) { val owned = tts; tts = null; try { owned?.shutdown() } catch (_: Exception) {} }
            val pending = waiters.toList(); waiters.clear()
            pending.forEach { it(ok) }
        }
        ttsDeadline = Runnable { finish(false) }
        handler.postDelayed(ttsDeadline!!, 5000)
        try { tts = TextToSpeech(activity.applicationContext) { status -> handler.post {
            if (generation != initialization || closed) return@post
            if (status != TextToSpeech.SUCCESS) { finish(false); return@post }
            try {
            tts?.setAudioAttributes(attributes)
            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) { handler.post {
                    val attempt = operations.current
                    if (attempt != null && utteranceId?.startsWith("${attempt.generation}:") == true) emit(mapOf("id" to attempt.id, "playing" to true))
                } }
                override fun onDone(utteranceId: String?) { handler.post {
                    val attempt = operations.current
                    if (attempt != null && utteranceId == "${attempt.generation}:last") finishPlayback(attempt)
                } }
                @Deprecated("Required by Android")
                override fun onError(utteranceId: String?) { handler.post {
                    val attempt = operations.current
                    if (attempt != null && utteranceId?.startsWith("${attempt.generation}:") == true) finishPlayback(attempt, "Android could not generate speech with this voice.")
                } }
            })
            finish(true)
            } catch (_: Exception) { finish(false) }
        } } } catch (_: Exception) { finish(false) }
    }
    private fun voices() = tts?.voices.orEmpty().filter {
        !it.isNetworkConnectionRequired && !it.features.orEmpty().contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)
    }.sortedBy { "${it.locale.toLanguageTag()} ${it.name}" }
    fun voiceChoices() = voices().map { mapOf("id" to it.name, "label" to "${it.locale.getDisplayName(Locale.getDefault())} · ${it.name}") }

    private fun claim(owner: String, response: MethodChannel.Result): VoiceOperation {
        check(!closed) { "Voice playback is unavailable." }
        check(owner.isNotEmpty()) { "Missing playback ID." }
        stop(force = true)
        val attempt = operations.begin(owner)
        val listener = AudioManager.OnAudioFocusChangeListener { value -> handler.post {
            if (value < 0 && operations.owns(attempt)) stop(force = true)
        } }
        focusListener = listener
        try {
            @Suppress("DEPRECATION")
            val granted = if (Build.VERSION.SDK_INT >= 26) {
                focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    .setAudioAttributes(attributes).setOnAudioFocusChangeListener(listener, handler).build()
                audio.requestAudioFocus(focus!!)
            } else audio.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            check(granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) { "Audio is in use by another app. Please retry." }
            result = response
            timeout = Runnable { finishPlayback(attempt, "Speech playback timed out.") }
            handler.postDelayed(timeout!!, 600000)
            return attempt
        } catch (error: Exception) { stop(force = true); throw error }
    }
    fun speak(owner: String, text: String, voiceName: String, rate: Float, segments: List<Map<String, String>>?, response: MethodChannel.Result) {
        val attempt = claim(owner, response)
        withTts { ready ->
            if (!operations.owns(attempt) || closed) return@withTts
            try {
                check(ready) { "Android speech synthesis is unavailable. Install an offline voice in Android settings." }
                val installed = voices()
                val voice = if (voiceName.isNotEmpty()) installed.find { it.name == voiceName }
                    else installed.find { it.locale == Locale.getDefault() } ?: installed.find { it.locale.language == Locale.getDefault().language }
                // Engines like SherpaTTS may list no Voice objects; use the engine default then.
                check(voice != null || voiceName.isEmpty()) { "The selected offline voice is unavailable. Choose an installed Android voice in App settings." }
                if (voice != null) check(tts!!.setVoice(voice) == TextToSpeech.SUCCESS) { "Could not select the offline voice." }
                check(tts!!.setSpeechRate(rate.coerceIn(0.5f, 2f)) == TextToSpeech.SUCCESS) { "Could not set speaking speed." }
                check(text.isNotBlank()) { "There is no text to read." }
                LanguageSpeech.enqueue(tts!!, attempt.generation.toString(), text, segments, voice)
            } catch (error: Exception) { finishPlayback(attempt, error.message ?: "Could not generate speech.") }
        }
    }
    fun play(owner: String, bytes: ByteArray, response: MethodChannel.Result) {
        check(bytes.isNotEmpty() && bytes.size <= MAX_VOICE_BYTES) { "Invalid speech audio size." }
        val attempt = claim(owner, response)
        try {
            file = VoiceFileWork.process.create(voicePath(activity), "playback-", bytes,
                dispatch = dispatchFile) { lease, error ->
                if (!operations.owns(attempt) || closed) { lease?.cancel(); return@create }
                try {
                    if (error != null) throw error
                    val prepared = MediaPlayer()
                    player = prepared
                    prepared.setAudioAttributes(attributes)
                    prepared.setDataSource(lease!!.path)
                    prepared.setOnPreparedListener {
                        if (operations.owns(attempt) && !closed && player === it) {
                            try { it.start(); emit(mapOf("id" to owner, "playing" to true)) }
                            catch (_: Exception) { finishPlayback(attempt, "Could not start the Hermes audio.") }
                        }
                    }
                    prepared.setOnCompletionListener { if (player === it) finishPlayback(attempt) }
                    prepared.setOnErrorListener { failed, _, _ ->
                        if (player === failed) finishPlayback(attempt, "Could not play the Hermes audio.")
                        true
                    }
                    prepared.prepareAsync()
                } catch (_: Exception) { finishPlayback(attempt, "Could not play the Hermes audio.") }
            }
        } catch (_: Exception) { finishPlayback(attempt, "Could not prepare the Hermes audio.") }
    }
    private fun finishPlayback(attempt: VoiceOperation, failure: String? = null) {
        if (!operations.owns(attempt)) return
        val response = result; result = null
        stop(force = true)
        if (failure == null) response?.success(null) else response?.error("voice_playback", failure, null)
    }
    fun stop(owner: String? = null, force: Boolean = false) {
        if (owner == null && !force && keepsVoice()) return
        val attempt = operations.current
        if (owner != null && attempt?.id != owner) return
        if (attempt != null) operations.retire(attempt)
        timeout?.let { handler.removeCallbacks(it) }; timeout = null
        try { tts?.stop() } catch (_: Exception) {}
        try { player?.release() } catch (_: Exception) {}
        player = null
        file?.cancel(); file = null
        try {
            if (Build.VERSION.SDK_INT >= 26) focus?.let { audio.abandonAudioFocusRequest(it) }
            else { @Suppress("DEPRECATION") focusListener?.let { audio.abandonAudioFocus(it) } }
        } catch (_: Exception) {}
        focus = null; focusListener = null
        val response = result; result = null
        response?.success(null)
    }
    fun close() {
        if (closed) return
        closed = true; stop(force = true)
        ttsDeadline?.let { handler.removeCallbacks(it) }; ttsDeadline = null
        val pending = waiters.toList(); waiters.clear(); pending.forEach { it(false) }
        val owned = tts; tts = null
        try { owned?.shutdown() } catch (_: Exception) {}
        try { activity.unregisterReceiver(noisyReceiver) } catch (_: IllegalArgumentException) {}
    }
}
