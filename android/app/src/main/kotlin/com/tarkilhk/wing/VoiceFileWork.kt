package com.tarkilhk.wing

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CancellationException
import java.util.concurrent.Semaphore
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

const val MAX_VOICE_BYTES = 25 * 1024 * 1024

/** The only native voice file API owner. Streams close on the transfer thread. */
interface VoiceFiles {
    fun prepare(directory: String)
    fun create(directory: String, prefix: String): File
    fun write(file: File, bytes: ByteArray, check: () -> Unit)
    fun read(file: File, check: () -> Unit): ByteArray
    fun delete(file: File): Boolean
}

object LocalVoiceFiles : VoiceFiles {
    override fun prepare(directory: String) {
        val root = File(directory)
        check(root.isDirectory || root.mkdirs()) { "Voice cache is unavailable." }
        // Once per process, before any current-process lease can create a file.
        root.listFiles()?.forEach { check(it.delete() || !it.exists()) { "Voice cache cleanup failed." } }
    }
    override fun create(directory: String, prefix: String): File = File.createTempFile(prefix, ".audio", File(directory))
    override fun write(file: File, bytes: ByteArray, check: () -> Unit) {
        require(bytes.isNotEmpty() && bytes.size <= MAX_VOICE_BYTES) { "Invalid speech audio size." }
        FileOutputStream(file).use { output ->
            var offset = 0
            while (offset < bytes.size) {
                check()
                val count = minOf(65536, bytes.size - offset)
                output.write(bytes, offset, count)
                offset += count
            }
            check()
        }
        check(file.length() == bytes.size.toLong()) { "Speech audio write was incomplete." }
    }
    override fun read(file: File, check: () -> Unit): ByteArray {
        // Recording has stopped. Capture its actual size, allocate no more than
        // the stock cap, and reject growth/truncation instead of trusting stat.
        val length = file.length()
        require(length in 1..MAX_VOICE_BYTES.toLong()) { "Recording is empty or too large." }
        check()
        val bytes = ByteArray(length.toInt())
        FileInputStream(file).use { input ->
            var offset = 0
            while (offset < bytes.size) {
                check()
                val count = input.read(bytes, offset, minOf(65536, bytes.size - offset))
                check(count > 0) { "Recording changed during transfer." }
                offset += count
            }
            check()
            check(input.read() == -1) { "Recording grew during transfer." }
        }
        return bytes
    }
    override fun delete(file: File) = file.delete() || !file.exists()
}

/** One process-wide thread, two leases, no worker replacement on cancellation.
 * An uninterruptible transfer or failed deletion keeps its admission charged. */
class VoiceFileWork(private val files: VoiceFiles = LocalVoiceFiles) {
    private val permits = Semaphore(2)
    private val leases = mutableSetOf<Lease>()
    private val executor = ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS,
        ArrayBlockingQueue<Runnable>(2), { task -> Thread(task, "Wing voice transfer").apply { isDaemon = true } })
    private var directory: String? = null
    private var preparationFailure: Exception? = null

    inner class Lease internal constructor(private val dispatch: (() -> Unit) -> Unit) {
        private var active = true
        private var busy = true
        private var cleanupQueued = false
        private var released = false
        private var cleanupDone = false
        private var posted = 0
        private var file: File? = null
        private var worker: Thread? = null
        private var pending: VoiceReply<Any>? = null
        val path: String get() = synchronized(this) { checkActive(); file?.absolutePath ?: error("Voice file is not ready.") }
        private fun checkActive() { if (!active) throw CancellationException("Voice transfer cancelled.") }
        private fun checkAuthority() = synchronized(this) { checkActive() }
        internal fun create(root: String, prefix: String, bytes: ByteArray?, callback: (Lease?, Exception?) -> Unit) {
            val reply = VoiceReply<Any> { value, error -> callback(value as Lease?, error) }
            synchronized(this) { pending = reply }
            executor.execute { run(reply) {
                preparationFailure?.let { throw it }
                checkAuthority()
                val created = files.create(root, prefix)
                synchronized(this) { file = created; checkActive() }
                if (bytes != null) files.write(created, bytes, ::checkAuthority)
                this
            } }
        }
        fun read(callback: (ByteArray?, Exception?) -> Unit) {
            val reply = VoiceReply<Any> { value, error -> callback(value as ByteArray?, error) }
            synchronized(this) { checkActive(); check(!busy) { "Voice file transfer is already running." }; busy = true; pending = reply }
            executor.execute { run(reply) { files.read(synchronized(this) { file ?: error("No recording is available.") }, ::checkAuthority) } }
        }
        private fun run(reply: VoiceReply<Any>, action: () -> Any) {
            synchronized(this) { worker = Thread.currentThread() }
            var value: Any? = null
            var error: Exception? = null
            try { checkAuthority(); value = action(); checkAuthority() }
            catch (failure: Throwable) { error = failure as? Exception ?: IllegalStateException("Voice transfer failed.", failure); synchronized(this) { active = false } }
            finally {
                synchronized(this) { worker = null; busy = false }
                // Clear interruption before this fixed thread takes the next lease.
                Thread.interrupted()
                post {
                    val retired = synchronized(this) { !active }
                    reply.settle(if (retired) null else value, if (retired) error ?: CancellationException("Voice transfer cancelled.") else error)
                    synchronized(this) { if (pending === reply) pending = null }
                }
                cleanupIfRetired()
            }
        }
        private fun post(action: () -> Unit) {
            synchronized(this) { posted++ }
            dispatch { try { action() } finally { synchronized(this) { posted-- }; releaseIfDone() } }
        }
        fun cancel() {
            val reply = synchronized(this) {
                if (!active) return
                active = false; worker?.interrupt(); pending
            }
            if (reply != null) post { reply.settle(error = CancellationException("Voice transfer cancelled.")) }
            cleanupIfRetired()
        }
        private fun cleanupIfRetired() {
            synchronized(this) {
                if (active || busy || cleanupQueued || released) return
                cleanupQueued = true
            }
            // One cleanup per admitted lease; at most two fit this fixed queue.
            executor.execute {
                val owned = synchronized(this) { file }
                val deleted = try { owned == null || files.delete(owned) } catch (_: Throwable) { false }
                if (deleted) {
                    synchronized(this) { file = null; cleanupDone = true }
                    releaseIfDone()
                }
                // Failed cleanup deliberately retains admission and file ownership.
            }
        }
        private fun releaseIfDone() {
            val release = synchronized(this) {
                if (released || !cleanupDone || busy || posted != 0) false
                else { released = true; true }
            }
            if (release) { synchronized(leases) { leases.remove(this) }; permits.release() }
        }
    }
    @Synchronized fun prepare(root: String) {
        if (directory != null) { check(directory == root) { "Voice file root changed within this process." }; return }
        directory = root
        executor.execute { try { files.prepare(root) } catch (error: Throwable) { preparationFailure = error as? Exception ?: IllegalStateException("Voice cache preparation failed.", error) } }
    }
    fun create(root: String, prefix: String, bytes: ByteArray? = null, dispatch: (() -> Unit) -> Unit, callback: (Lease?, Exception?) -> Unit): Lease {
        require(bytes == null || bytes.isNotEmpty() && bytes.size <= MAX_VOICE_BYTES) { "Invalid speech audio size." }
        prepare(root)
        check(permits.tryAcquire()) { "Voice file capacity is busy. Please retry." }
        return Lease(dispatch).also { lease ->
            synchronized(leases) { leases.add(lease) }
            lease.create(root, prefix, bytes, callback)
        }
    }
    internal fun outstanding() = 2 - permits.availablePermits()
    companion object { val process = VoiceFileWork() }
}
