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

    fun transcribe(samples: FloatArray, done: (Result<String>, Long, Boolean) -> Unit) {
        val readyAtStart = ready
        executor.execute {
            val started = SystemClock.elapsedRealtime()
            val result = runCatching {
                val model = load()
                val stream = model.createStream()
                try {
                    stream.acceptWaveform(samples, 16000)
                    model.decode(stream)
                    model.getResult(stream).text.trim()
                } finally { stream.release() }
            }
            done(result, SystemClock.elapsedRealtime() - started, readyAtStart)
        }
    }

    fun release() { executor.execute { recognizer?.release(); recognizer = null; ready = false } }

    fun close() { release(); executor.shutdown() }
}
