package com.tarkilhk.wing

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/** Debug recordings of vad rounds (opt-in): 16 kHz mono PCM16 WAV + JSON timing.
 *  Private app storage only; the newest [KEEP] rounds are kept; never uploaded. */
class VoiceDebugStore(context: Context) {
    companion object { const val KEEP = 30 }
    private val dir = File(context.filesDir, "voice-debug")
    private val executor = Executors.newSingleThreadExecutor()

    fun write(roundId: String, startedAt: Long, pcm: ShortArray, length: Int, meta: JSONObject) {
        executor.execute {
            try {
            dir.mkdirs()
            val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date(startedAt))
            val base = "$stamp-${roundId.take(8)}"
            writeWav(File(dir, "$base.wav"), pcm, length)
            File(dir, "$base.json").writeText(meta.toString())
            prune()
            } catch (t: Throwable) { Log.w("VoiceDebugStore", "debug recording failed", t) }
        }
    }

    fun deleteAll(): Int {
        val rounds = dir.listFiles { file -> file.name.endsWith(".json") }?.size ?: 0
        dir.listFiles()?.forEach { it.delete() }
        return rounds
    }

    private fun prune() {
        val rounds = dir.listFiles { file -> file.name.endsWith(".json") }?.sortedBy { it.name } ?: return
        rounds.dropLast(KEEP).forEach { json ->
            json.delete(); File(dir, json.name.removeSuffix(".json") + ".wav").delete()
        }
    }

    private fun writeWav(file: File, pcm: ShortArray, length: Int) {
        RandomAccessFile(file, "rw").use { out ->
            out.setLength(0)
            val dataBytes = length * 2
            fun le32(v: Int) { out.write(v and 0xff); out.write(v shr 8 and 0xff); out.write(v shr 16 and 0xff); out.write(v shr 24 and 0xff) }
            fun le16(v: Int) { out.write(v and 0xff); out.write(v shr 8 and 0xff) }
            out.writeBytes("RIFF"); le32(36 + dataBytes); out.writeBytes("WAVE")
            out.writeBytes("fmt "); le32(16); le16(1); le16(1); le32(16000); le32(32000); le16(2); le16(16)
            out.writeBytes("data"); le32(dataBytes)
            // Stream in blocks: a 30 minute round must not get a second 57 MB copy.
            val block = ByteArray(2 * 16384)
            var at = 0
            while (at < length) {
                val n = minOf(16384, length - at)
                for (i in 0 until n) { block[2 * i] = (pcm[at + i].toInt() and 0xff).toByte(); block[2 * i + 1] = (pcm[at + i].toInt() shr 8).toByte() }
                out.write(block, 0, 2 * n)
                at += n
            }
        }
    }

    fun close() { executor.shutdown() }
}
