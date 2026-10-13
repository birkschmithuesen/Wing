package com.tarkilhk.wing

import android.os.SystemClock
import android.util.Log
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineTransducerModelConfig
import java.io.File
import java.util.concurrent.Executors

/** Parakeet TDT 0.6B v3 int8 (sherpa-onnx nemo_transducer). Every call runs on
 *  one executor, so loading and decoding never overlap. */
class OfflineSpeech(private val store: SpeechModelStore) {
    private val executor = Executors.newSingleThreadExecutor()
    private var recognizer: OfflineRecognizer? = null
    @Volatile var ready = false
        private set

    fun prepare() { executor.execute { runCatching { load() }.onFailure { Log.w("WingVad", "preload failed: ${it.message}") } } }

    private fun load(): OfflineRecognizer {
        recognizer?.let { return it }
        store.verifyManifest()?.let { error(it) }
        val dir = store.modelDir
        val started = SystemClock.elapsedRealtime()
        val config = OfflineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = 16000, featureDim = 80),
            modelConfig = OfflineModelConfig(
                transducer = OfflineTransducerModelConfig(
                    encoder = File(dir, "encoder.int8.onnx").path,
                    decoder = File(dir, "decoder.int8.onnx").path,
                    joiner = File(dir, "joiner.int8.onnx").path,
                ),
                tokens = File(dir, "tokens.txt").path,
                numThreads = 4,
                modelType = "nemo_transducer",
            ),
            decodingMethod = "greedy_search",
        )
        return OfflineRecognizer(assetManager = null, config = config).also {
            recognizer = it
            ready = true
            Log.i("WingVad", "model loaded in ${SystemClock.elapsedRealtime() - started} ms")
        }
    }

    /** Decodes [ranges] (sample offsets `[start, end)` into [pcm]) one after the other, one stream per
     *  chunk released right after it, so a long round never needs one huge float copy. Chunk texts are
     *  joined with a single space. [cancelled] is checked between chunks and stops further decoding.
     *  [done] gets the text, the total ms, whether the model was ready at the call, and per chunk
     *  `[startSample, endSample, decodeMs]`. */
    fun transcribeChunks(
        pcm: ShortArray,
        ranges: List<IntArray>,
        cancelled: () -> Boolean,
        done: (Result<String>, Long, Boolean, List<LongArray>) -> Unit,
    ) {
        val readyAtStart = ready
        executor.execute {
            val started = SystemClock.elapsedRealtime()
            val timings = ArrayList<LongArray>()
            val result = runCatching {
                val model = load()
                val texts = ArrayList<String>()
                for (range in ranges) {
                    if (cancelled()) break
                    val chunkStarted = SystemClock.elapsedRealtime()
                    val from = range[0]
                    val samples = FloatArray(range[1] - from) { pcm[from + it] / 32768f }
                    val stream = model.createStream()
                    try {
                        stream.acceptWaveform(samples, 16000)
                        model.decode(stream)
                        model.getResult(stream).text.trim().takeIf { it.isNotEmpty() }?.let { texts.add(it) }
                    } finally { stream.release() }
                    timings.add(longArrayOf(range[0].toLong(), range[1].toLong(), SystemClock.elapsedRealtime() - chunkStarted))
                }
                texts.joinToString(" ").trim()
            }
            done(result, SystemClock.elapsedRealtime() - started, readyAtStart, timings)
        }
    }

    fun release() { executor.execute { recognizer?.release(); recognizer = null; ready = false } }

    fun close() { release(); executor.shutdown() }
}
