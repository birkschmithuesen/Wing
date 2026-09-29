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
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

class VoicePlayback(private val activity: Activity, private val emit: (Map<String, Any>) -> Unit) {
    private val handler = Handler(Looper.getMainLooper())
    private val audio = activity.getSystemService(AudioManager::class.java)
    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private var focus: AudioFocusRequest? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var closed = false
    private var initialization = 0
    private val waiters = mutableListOf<(Boolean) -> Unit>()
    private var player: MediaPlayer? = null
    private var file: File? = null
    private var id: String? = null
    private var result: MethodChannel.Result? = null
    private var timeout: Runnable? = null
    private val focusListener = AudioManager.OnAudioFocusChangeListener { value ->
        if (value < 0) stop()
    }
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) { stop() }
    }
    init {
        if (Build.VERSION.SDK_INT >= 33) activity.registerReceiver(noisyReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), Context.RECEIVER_NOT_EXPORTED)
        else { @Suppress("DEPRECATION") activity.registerReceiver(noisyReceiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)) }
    }

    fun withTts(callback: (Boolean) -> Unit) {
        if (closed) { callback(false); return }
        if (ttsReady) { callback(true); return }
        waiters.add(callback)
        if (tts != null) return
        val generation = ++initialization
        fun finish(ok: Boolean) {
            if (generation != initialization || closed) return
            initialization++
            ttsReady = ok
            if (!ok) { tts?.shutdown(); tts = null }
            val pending = waiters.toList(); waiters.clear()
            pending.forEach { it(ok) }
        }
        handler.postDelayed({ finish(false) }, 5000)
        tts = TextToSpeech(activity.applicationContext) { status -> handler.post {
            if (generation != initialization || closed) return@post
            if (status != TextToSpeech.SUCCESS) { finish(false); return@post }
            tts?.setAudioAttributes(attributes)
            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) { handler.post {
                    val owner = id
                    if (owner != null && utteranceId?.startsWith("$owner:") == true) emit(mapOf("id" to owner, "playing" to true))
                } }
                override fun onDone(utteranceId: String?) { handler.post {
                    if (utteranceId == "$id:last") finishPlayback(id)
                } }
                @Deprecated("Required by Android")
                override fun onError(utteranceId: String?) { handler.post {
                    val owner = id
                    if (owner != null && utteranceId?.startsWith("$owner:") == true) finishPlayback(owner, "Android could not generate speech with this voice.")
                } }
            })
            finish(true)
        } }
    }
    private fun voices() = tts?.voices.orEmpty().filter {
        !it.isNetworkConnectionRequired && !it.features.orEmpty().contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)
    }.sortedBy { "${it.locale.toLanguageTag()} ${it.name}" }
    fun voiceChoices() = voices().map { mapOf("id" to it.name, "label" to "${it.locale.getDisplayName(Locale.getDefault())} · ${it.name}") }

    private fun claim(owner: String, response: MethodChannel.Result) {
        check(!closed) { "Voice playback is unavailable." }
        stop()
        @Suppress("DEPRECATION")
        val granted = if (Build.VERSION.SDK_INT >= 26) {
            focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes).setOnAudioFocusChangeListener(focusListener).build()
            audio.requestAudioFocus(focus!!)
        } else audio.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
        check(granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) { "Audio is in use by another app. Please retry." }
        id = owner; result = response
        timeout = Runnable { finishPlayback(owner, "Speech playback timed out.") }
        handler.postDelayed(timeout!!, 600000)
    }
    fun speak(owner: String, text: String, voiceName: String, rate: Float, response: MethodChannel.Result) {
        claim(owner, response)
        withTts { ready ->
            if (id != owner) return@withTts
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
                val chunks = text.chunked(TextToSpeech.getMaxSpeechInputLength() - 1)
                chunks.forEachIndexed { index, chunk ->
                    val tag = if (index == chunks.lastIndex) "$owner:last" else "$owner:$index"
                    check(tts!!.speak(chunk, TextToSpeech.QUEUE_ADD, null, tag) == TextToSpeech.SUCCESS) { "Could not generate speech." }
                }
            } catch (error: Exception) { finishPlayback(owner, error.message ?: "Could not generate speech.") }
        }
    }
    fun play(owner: String, bytes: ByteArray, response: MethodChannel.Result) {
        check(bytes.isNotEmpty() && bytes.size <= 25 * 1024 * 1024) { "Invalid speech audio size." }
        claim(owner, response)
        try {
            file = File.createTempFile("playback-", ".audio", voiceDirectory(activity)).also { it.writeBytes(bytes) }
            player = MediaPlayer().apply {
                setAudioAttributes(attributes)
                setDataSource(file!!.absolutePath)
                setOnPreparedListener { if (id == owner) { it.start(); emit(mapOf("id" to owner, "playing" to true)) } }
                setOnCompletionListener { finishPlayback(owner) }
                setOnErrorListener { _, _, _ -> finishPlayback(owner, "Could not play the Hermes audio."); true }
                prepareAsync()
            }
        } catch (_: Exception) { finishPlayback(owner, "Could not play the Hermes audio.") }
    }
    private fun finishPlayback(owner: String?, failure: String? = null) {
        if (owner == null || id != owner) return
        val response = result; result = null
        stop()
        if (failure == null) response?.success(null) else response?.error("voice_playback", failure, null)
    }
    fun stop(owner: String? = null) {
        if (owner != null && id != owner) return
        id = null
        timeout?.let { handler.removeCallbacks(it) }; timeout = null
        tts?.stop(); player?.release(); player = null
        file?.delete(); file = null
        if (Build.VERSION.SDK_INT >= 26) focus?.let { audio.abandonAudioFocusRequest(it) }
        else { @Suppress("DEPRECATION") audio.abandonAudioFocus(focusListener) }
        focus = null
        result?.success(null); result = null
    }
    fun close() {
        closed = true; stop()
        val pending = waiters.toList(); waiters.clear(); pending.forEach { it(false) }
        tts?.shutdown(); tts = null
        activity.unregisterReceiver(noisyReceiver)
    }
}
