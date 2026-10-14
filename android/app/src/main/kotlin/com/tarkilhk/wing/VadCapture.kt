package com.tarkilhk.wing

import android.app.Activity
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import kotlin.concurrent.thread

/** Route vad: 16 kHz mono capture, one Silero probability per 32 ms window
 *  (sent to Dart in batches of 4), cut + on-phone recognition on request.
 *  The end-of-utterance decision lives in Dart (vad_endpoint.dart).
 *  Records from whatever input Android routes; never changes audio routing. */
class VadCapture(
    private val activity: Activity,
    private val models: SpeechModelStore,
    private val speech: OfflineSpeech,
    private val debug: VoiceDebugStore,
    private val emit: (Map<String, Any>) -> Unit,
) {
    data class Options(val cues: Boolean, val debug: Boolean, val source: String, val maxMs: Int,
                       val startCue: Boolean = cues)

    private class Round(val id: String, val options: Options, val startedAt: Long, capacity: Int) {
        val pcm = ShortArray(capacity)
        @Volatile var length = 0
        val probabilities = ArrayList<Float>()
        @Volatile var stopped = false
        var computeErrors = 0
        var record: AudioRecord? = null
        var reader: Thread? = null
        var vad: Vad? = null
        var sourceName = ""
        var inputDevice = "unknown"
    }

    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var round: Round? = null

    fun start(id: String, options: Options) {
        cancelCurrent()
        models.verifyManifest()?.let { error(it) }
        val r = Round(id, options, System.currentTimeMillis(), (options.maxMs + 5_000) * 16)
        round = r
        try {
            if (options.startCue) cue(ToneGenerator.TONE_PROP_BEEP, wait = true)
            r.vad = Vad(
                assetManager = activity.assets,
                config = VadModelConfig(
                    sileroVadModelConfig = SileroVadModelConfig(model = "silero_vad.onnx", windowSize = 512),
                    sampleRate = 16000,
                    numThreads = 1,
                ),
            )
            r.record = openRecord(r)
            r.record!!.startRecording()
            // Read-only diagnosis: which input Android routed this recording to.
            r.inputDevice = r.record!!.routedDevice?.let { "${it.productName} (type ${it.type})" } ?: "unknown"
            r.reader = thread(name = "WingVad") { read(r) }
        } catch (error: Exception) { release(r); round = null; throw error }
    }

    /** [wait] keeps the "listening" cue out of the recording (about 250 ms before capture starts). */
    private fun cue(tone: Int, wait: Boolean) {
        try {
            val generator = ToneGenerator(AudioManager.STREAM_MUSIC, 70)
            generator.startTone(tone, 150)
            handler.postDelayed({ generator.release() }, 400)
            if (wait) Thread.sleep(250)
        } catch (_: Exception) {}
    }

    // VoiceChannel only calls start() after RECORD_AUDIO was granted.
    @android.annotation.SuppressLint("MissingPermission")
    private fun openRecord(r: Round): AudioRecord {
        val minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val sources = if (r.options.source == "recognition") listOf(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            else listOf(MediaRecorder.AudioSource.VOICE_COMMUNICATION, MediaRecorder.AudioSource.VOICE_RECOGNITION)
        for (source in sources) {
            val record = AudioRecord(source, 16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minimum, 16000))
            if (record.state == AudioRecord.STATE_INITIALIZED) {
                r.sourceName = if (source == MediaRecorder.AudioSource.VOICE_COMMUNICATION) "VOICE_COMMUNICATION" else "VOICE_RECOGNITION"
                return record
            }
            record.release()
        }
        error("Microphone is unavailable.")
    }

    /** The reader thread owns the native resources: it releases them when it leaves the loop,
     *  so nothing is freed while record.read or vad.compute may still be running. */
    private fun read(r: Round) {
        try { readLoop(r) } finally { release(r) }
    }

    private fun readLoop(r: Round) {
        val frame = ShortArray(512)
        // 512 samples exactly: the pinned model is the legacy Silero layout (x[1,512], h, c),
        // which sherpa-onnx v1.13.8 runs as "v4" with window_overlap 0 (docs/VAD_INPUT.md).
        val window = FloatArray(512)
        val batch = ArrayList<Double>(4)
        var first = 0
        val record = r.record ?: return
        val vad = r.vad ?: return
        while (!r.stopped) {
            var filled = 0
            while (filled < 512 && !r.stopped) {
                val n = record.read(frame, filled, 512 - filled)
                if (n < 0) {
                    handler.post { if (round === r) fail(r, "Microphone recording failed. Please retry.") }
                    return
                }
                filled += n
            }
            if (r.stopped) break
            if (r.length + 512 > r.pcm.size) {
                handler.post { if (round === r) fail(r, "Recording reached its time limit. Please try a shorter recording.") }
                return
            }
            System.arraycopy(frame, 0, r.pcm, r.length, 512)
            r.length += 512
            for (k in 0 until 512) window[k] = frame[k] / 32768f
            val raw = vad.compute(window)
            val p = if (raw < 0f) { r.computeErrors++; 0f } else raw
            synchronized(r.probabilities) { r.probabilities.add(p) }
            batch.add(p.toDouble())
            if (batch.size == 4) {
                val send = ArrayList(batch); val at = first
                first += batch.size; batch.clear()
                handler.post { if (round === r) emit(mapOf("id" to r.id, "first" to at, "windows" to send)) }
            }
        }
    }

    fun finish(id: String, startWindow: Int, endWindow: Int, atWindow: Int, reason: String,
               config: Map<String, Any?>, chunks: List<List<Int>>?, response: MethodChannel.Result) {
        val r = round?.takeIf { it.id == id } ?: run { response.error("cancelled", "Recording cancelled.", null); return }
        stopReading(r)
        if (reason == "noSpeech") {
            // Nothing was said: no cue, no recognition; keep the timing for diagnosis.
            if (r.options.debug) writeDebug(r, JSONObject().put("reason", reason).put("atWindow", atWindow), config, JSONObject())
            round = null
            response.success("")
            return
        }
        if (r.options.cues) cue(ToneGenerator.TONE_PROP_ACK, wait = false)
        val start = (startWindow * 512).coerceIn(0, r.length)
        val end = (endWindow * 512).coerceIn(start, r.length)
        // Dart decides the chunks (window indices); without them the whole cut is one chunk.
        val ranges = chunks?.mapNotNull { c ->
            if (c.size < 2) return@mapNotNull null
            val from = (c[0] * 512).coerceIn(start, end)
            val to = (c[1] * 512).coerceIn(from, end)
            if (to > from) intArrayOf(from, to) else null
        }?.takeIf { it.isNotEmpty() } ?: listOf(intArrayOf(start, end))
        speech.transcribeChunks(r.pcm, ranges, { round !== r }) { result, decodeMs, readyAtStart, timings ->
            handler.post {
                if (r.options.debug) writeDebug(r, JSONObject().put("reason", reason).put("startWindow", startWindow)
                    .put("endWindow", endWindow).put("atWindow", atWindow), config, JSONObject()
                    .put("segmentMs", (end - start) / 16).put("decodeMs", decodeMs).put("modelReadyAtFinish", readyAtStart)
                    .put("chunks", JSONArray(timings.map { JSONArray(listOf(it[0] / 512, it[1] / 512, it[2])) }))
                    .put("textLength", result.getOrNull()?.length ?: 0).put("error", result.exceptionOrNull()?.message ?: JSONObject.NULL))
                val current = round === r
                if (current) round = null
                result.fold(
                    onSuccess = { text -> if (current) response.success(text) else response.error("cancelled", "Recording cancelled.", null) },
                    onFailure = { failure -> response.error("voice_unavailable", "Speech model could not be loaded (${failure.message}).", null) },
                )
            }
        }
    }

    private fun stopReading(r: Round) {
        r.stopped = true
        try { r.record?.stop() } catch (_: Exception) {}
        // Never release here: the reader releases its own resources when it exits (see read).
        try { r.reader?.join(500) } catch (_: InterruptedException) {}
    }

    private fun release(r: Round) {
        r.record?.release(); r.record = null
        r.vad?.release(); r.vad = null
    }

    private fun writeDebug(r: Round, decision: JSONObject, config: Map<String, Any?>, recognition: JSONObject) {
        val probabilities = synchronized(r.probabilities) { JSONArray(r.probabilities.map { Math.round(it * 1000) / 1000.0 }) }
        debug.write(r.id, r.startedAt, r.pcm, r.length, JSONObject()
            .put("version", 1).put("roundId", r.id).put("startedAt", Instant.ofEpochMilli(r.startedAt).toString())
            .put("sampleRate", 16000).put("windowSamples", 512).put("windowMs", 32)
            .put("source", r.sourceName).put("inputDevice", r.inputDevice)
            .put("config", JSONObject(config)).put("probabilities", probabilities)
            .put("computeErrors", r.computeErrors).put("decision", decision).put("recognition", recognition))
    }

    private fun fail(r: Round, message: String) {
        stopReading(r)
        if (r.options.debug) writeDebug(r, JSONObject().put("reason", "error").put("error", message), emptyMap(), JSONObject())
        round = null
        emit(mapOf("id" to r.id, "error" to message))
    }

    fun cancel(id: String) { round?.takeIf { it.id == id }?.let { cancelRound(it) } }

    private fun cancelRound(r: Round) {
        stopReading(r)
        if (r.options.debug) writeDebug(r, JSONObject().put("reason", "cancelled"), emptyMap(), JSONObject())
        round = null
    }

    private fun cancelCurrent() { round?.let { cancelRound(it) } }

    fun pause() { round?.let { r -> fail(r, "Recording stopped because Wing left the foreground.") } }

    fun close() { cancelCurrent() }
}
