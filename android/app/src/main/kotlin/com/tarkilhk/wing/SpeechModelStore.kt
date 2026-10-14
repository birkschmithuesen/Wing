package com.tarkilhk.wing

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.CancellationException
import java.util.concurrent.Executors

/** Parakeet TDT 0.6B v3 int8 in app-private storage. Per-file hashes are not
 *  published, so the archive hash is verified first and the per-file hashes in
 *  manifest.json are derived from the verified archive during extraction. */
class SpeechModelStore(private val context: Context, private val emit: (Map<String, Any>) -> Unit) {
    companion object {
        const val ARCHIVE_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"
        const val ARCHIVE_SHA256 = "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf"
        const val ARCHIVE_BYTES = 487_170_055L
        const val ARCHIVE_NAME = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"
        const val ARCHIVE_ROOT = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/"
        val FILES = listOf("encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt")
        private const val EXTRACTED_BYTES = 700L * 1000 * 1000
    }

    private val root = File(context.filesDir, "models")
    val modelDir = File(root, "parakeet-tdt-0.6b-v3-int8")
    private val download = File(root, "download/archive.tar.bz2.part")
    private val staging = File(root, "staging")
    private val executor = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var cancelled = false
    @Volatile private var busy = false
    @Volatile private var current: Map<String, Any> = idleStatus()

    fun status(): Map<String, Any> = current

    private fun idleStatus(): Map<String, Any> =
        if (verifyManifest() == null) mapOf("state" to "installed", "bytes" to 0L, "total" to 0L)
        else mapOf("state" to "absent", "bytes" to download.length(), "total" to ARCHIVE_BYTES)

    /** null when the model can be loaded, else a message for the user. */
    fun verifyManifest(): String? {
        val manifest = File(modelDir, "manifest.json")
        if (!manifest.isFile) return "Download the speech model in App settings → Voice."
        return try {
            val files = JSONObject(manifest.readText()).getJSONObject("files")
            val broken = FILES.any { name ->
                val file = File(modelDir, name)
                !file.isFile || file.length() != files.getJSONObject(name).getLong("size")
            }
            if (broken) "Speech model is incomplete. Download it again." else null
        } catch (_: Exception) { "Speech model is incomplete. Download it again." }
    }

    private fun publish(state: String, bytes: Long = 0, total: Long = 0, error: String? = null) {
        val status = buildMap<String, Any> {
            put("state", state); put("bytes", bytes); put("total", total)
            if (error != null) put("error", error)
        }
        current = status
        handler.post { emit(mapOf("model" to status)) }
    }

    fun install() {
        if (busy) return
        busy = true
        cancelled = false
        executor.execute {
            try {
                val imported = context.getExternalFilesDir("import")?.let { File(it, ARCHIVE_NAME) }?.takeIf { it.isFile }
                val archive = imported ?: fetch()
                publish("verifying")
                if (sha256(archive) != ARCHIVE_SHA256) {
                    archive.delete()
                    error("Download was corrupted. Retry.")
                }
                publish("unpacking")
                extract(archive)
                archive.delete()
                publish("installed")
            } catch (_: CancellationException) {
                publish("absent", download.length(), ARCHIVE_BYTES)
            } catch (error: Exception) {
                publish("failed", error = error.message ?: "Speech model download failed. Retry.")
            } finally { busy = false }
        }
    }

    fun cancel() { cancelled = true }

    fun remove() {
        cancelled = true
        executor.execute {
            modelDir.deleteRecursively(); staging.deleteRecursively(); download.delete()
            publish("absent", 0, ARCHIVE_BYTES)
        }
    }

    fun close() { cancelled = true; executor.shutdown() }

    private fun fetch(): File {
        download.parentFile?.mkdirs()
        var have = download.length()
        check(root.usableSpace >= (ARCHIVE_BYTES - have) + EXTRACTED_BYTES) { "Needs about 1.2 GB free space." }
        var connection = URL(ARCHIVE_URL).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        if (have > 0) connection.setRequestProperty("Range", "bytes=$have-")
        val code = connection.responseCode
        if (code == 416 && have == ARCHIVE_BYTES) return download
        val append = code == HttpURLConnection.HTTP_PARTIAL
        check(code == HttpURLConnection.HTTP_OK || append) { "Download failed (HTTP $code). Retry." }
        if (!append) have = 0
        var lastReport = 0L
        connection.inputStream.use { input ->
            FileOutputStream(download, append).use { output ->
                val buffer = ByteArray(1 shl 16)
                while (true) {
                    if (cancelled) throw CancellationException()
                    val n = input.read(buffer)
                    if (n < 0) break
                    output.write(buffer, 0, n)
                    have += n
                    val now = SystemClock.elapsedRealtime()
                    if (now - lastReport >= 500) { lastReport = now; publish("downloading", have, ARCHIVE_BYTES) }
                }
            }
        }
        connection.disconnect()
        check(download.length() == ARCHIVE_BYTES) { "Download was interrupted. Retry." }
        return download
    }

    private fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                if (cancelled) throw CancellationException()
                val n = stream.read(buffer)
                if (n < 0) break
                md.update(buffer, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun extract(archive: File) {
        staging.deleteRecursively(); staging.mkdirs()
        val manifest = JSONObject()
        TarArchiveInputStream(BZip2CompressorInputStream(BufferedInputStream(archive.inputStream(), 1 shl 16))).use { tar ->
            while (true) {
                val entry = tar.nextEntry ?: break
                val name = entry.name
                require(!name.contains("..") && !name.startsWith("/")) { "Unexpected file in the speech model archive." }
                if (!name.startsWith(ARCHIVE_ROOT)) continue
                val base = name.removePrefix(ARCHIVE_ROOT)
                if (base !in FILES) continue
                val md = MessageDigest.getInstance("SHA-256")
                var size = 0L
                FileOutputStream(File(staging, base)).use { out ->
                    val buffer = ByteArray(1 shl 16)
                    while (true) {
                        if (cancelled) throw CancellationException()
                        val n = tar.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n); md.update(buffer, 0, n); size += n
                    }
                }
                manifest.put(base, JSONObject().put("size", size)
                    .put("sha256", md.digest().joinToString("") { "%02x".format(it) }))
            }
        }
        val missing = FILES.filter { !manifest.has(it) }
        check(missing.isEmpty()) { "Speech model archive is missing ${missing.joinToString()}." }
        File(staging, "manifest.json").writeText(
            JSONObject().put("archiveSha256", ARCHIVE_SHA256).put("files", manifest).toString(1))
        modelDir.deleteRecursively()
        check(staging.renameTo(modelDir)) { "Could not install the speech model." }
    }
}
