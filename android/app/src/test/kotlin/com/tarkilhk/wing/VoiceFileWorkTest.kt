package com.tarkilhk.wing

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test
import org.junit.Rule
import org.junit.rules.TemporaryFolder

class VoiceFileWorkTest {
    private fun await(latch: CountDownLatch) = assertTrue(latch.await(5, TimeUnit.SECONDS))
    private fun hold(latch: CountDownLatch) { while (true) try { latch.await(); return } catch (_: InterruptedException) {} }
    @get:Rule val temporary = TemporaryFolder()
    private fun root() = temporary.newFolder()

    @Test fun fileGrowthBeyondCapturedReadSizeIsRejected() {
        val real = File(root(), "audio").apply { writeBytes(byteArrayOf(1, 2, 3, 4, 5)) }
        val changed = object : File(real.absolutePath) { override fun length() = 2L }
        assertThrows(IllegalStateException::class.java) { LocalVoiceFiles.read(changed) {} }
    }

    @Test fun stableRecordingReadsItsExactBytes() {
        val real = File(root(), "audio").apply { writeBytes(byteArrayOf(1, 2, 3, 4, 5)) }
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5), LocalVoiceFiles.read(real) {})
    }

    @Test fun oversizedRecordingIsRejectedBeforeReading() {
        val real = File(root(), "audio").apply { writeBytes(byteArrayOf(1)) }
        val oversized = object : File(real.absolutePath) { override fun length() = MAX_VOICE_BYTES.toLong() + 1 }
        assertThrows(IllegalArgumentException::class.java) { LocalVoiceFiles.read(oversized) {} }
    }

    @Test fun cancelledHeldWriteRetainsAdmissionAndCleansLateFileWithoutPublication() {
        val directory = root()
        val entered = CountDownLatch(1); val unblock = CountDownLatch(1)
        val cancelled = CountDownLatch(1); val deleted = CountDownLatch(1)
        val writes = AtomicInteger(); val success = AtomicInteger()
        val io = object : VoiceFiles by LocalVoiceFiles {
            override fun write(file: File, bytes: ByteArray, check: () -> Unit) {
                entered.countDown(); hold(unblock)
                check()
                writes.incrementAndGet()
                LocalVoiceFiles.write(file, bytes, check)
            }
            override fun delete(file: File): Boolean = LocalVoiceFiles.delete(file).also { deleted.countDown() }
        }
        val work = VoiceFileWork(io)
        try {
            val lease = work.create(directory.path, "playback-", byteArrayOf(1), { it() }) { _, error ->
                if (error == null) success.incrementAndGet() else cancelled.countDown()
            }
            await(entered); lease.cancel(); await(cancelled)
            assertEquals(1, work.outstanding()); assertEquals(1L, deleted.count)
            unblock.countDown(); await(deleted)
            assertEquals(0, success.get()); assertEquals(0, writes.get())
            assertTrue(directory.listFiles()!!.isEmpty())
        } finally { unblock.countDown(); directory.deleteRecursively() }
    }
    @Test fun saturatedUninterruptibleWorkerDoesNotSpawnReplacementOrGrowQueue() {
        val directory = root()
        val entered = CountDownLatch(1); val unblock = CountDownLatch(1)
        val cancelled = CountDownLatch(2); val deleted = CountDownLatch(1)
        val calls = AtomicInteger()
        val io = object : VoiceFiles by LocalVoiceFiles {
            override fun write(file: File, bytes: ByteArray, check: () -> Unit) {
                calls.incrementAndGet(); entered.countDown(); hold(unblock); check()
            }
            override fun delete(file: File): Boolean = LocalVoiceFiles.delete(file).also { deleted.countDown() }
        }
        val work = VoiceFileWork(io)
        try {
            val first = work.create(directory.path, "playback-", byteArrayOf(1), { it() }) { _, _ -> cancelled.countDown() }
            await(entered)
            val second = work.create(directory.path, "playback-", byteArrayOf(2), { it() }) { _, _ -> cancelled.countDown() }
            first.cancel(); second.cancel(); await(cancelled)
            try { work.create(directory.path, "playback-", byteArrayOf(3), { it() }) { _, _ -> }; fail("Third lease must be rejected") }
            catch (_: IllegalStateException) {}
            assertEquals(1, calls.get()); assertEquals(2, work.outstanding())
            unblock.countDown(); await(deleted)
            assertEquals(1, calls.get())
        } finally { unblock.countDown(); directory.deleteRecursively() }
    }
    @Test fun deleteAcknowledgementRetainsLeaseAndPayloadAdmission() {
        val directory = root()
        val ready = CountDownLatch(1); val closing = CountDownLatch(1); val unblock = CountDownLatch(1)
        lateinit var lease: VoiceFileWork.Lease
        val io = object : VoiceFiles by LocalVoiceFiles {
            override fun delete(file: File): Boolean { closing.countDown(); hold(unblock); return LocalVoiceFiles.delete(file) }
        }
        val work = VoiceFileWork(io)
        try {
            lease = work.create(directory.path, "playback-", byteArrayOf(1), { it() }) { _, error -> assertNull(error); ready.countDown() }
            await(ready); lease.cancel(); await(closing)
            assertEquals(1, work.outstanding()); assertTrue(directory.listFiles()!!.isNotEmpty())
            unblock.countDown()
        } finally { unblock.countDown() }
    }
    @Test fun readAndWriteRunOnTransferThreadAndPreparedPublicationCanBeCancelled() {
        val directory = root()
        val prepared = CountDownLatch(1); val posted = java.util.concurrent.LinkedBlockingQueue<() -> Unit>()
        val main = Thread.currentThread()
        val io = object : VoiceFiles by LocalVoiceFiles {
            override fun create(directory: String, prefix: String): File {
                assertNotSame(main, Thread.currentThread())
                return LocalVoiceFiles.create(directory, prefix)
            }
            override fun write(file: File, bytes: ByteArray, check: () -> Unit) {
                assertNotSame(main, Thread.currentThread()); LocalVoiceFiles.write(file, bytes, check)
            }
        }
        val work = VoiceFileWork(io)
        val calls = AtomicInteger(); val success = AtomicInteger()
        val lease = work.create(directory.path, "playback-", byteArrayOf(1), { posted.add(it); prepared.countDown() }) { _, error -> calls.incrementAndGet(); if(error == null) success.incrementAndGet() }
        try {
            await(prepared); lease.cancel()
            repeat(2) { posted.poll(5, TimeUnit.SECONDS)?.invoke() ?: fail("Expected completion/cancellation") }
            assertEquals(1, calls.get()); assertEquals(0, success.get())
        } finally { lease.cancel() }
    }
    @Test fun heldReadRunsOffMainAndRetainsLeaseUntilProducerAndDeliveryExit() {
        val directory = root()
        val ready = CountDownLatch(1); val entered = CountDownLatch(1); val unblock = CountDownLatch(1)
        val delivered = CountDownLatch(1); val cleaned = CountDownLatch(1)
        val main = Thread.currentThread()
        val io = object : VoiceFiles by LocalVoiceFiles {
            override fun read(file: File, check: () -> Unit): ByteArray {
                assertNotSame(main, Thread.currentThread()); entered.countDown(); hold(unblock)
                return LocalVoiceFiles.read(file, check)
            }
            override fun delete(file: File): Boolean = LocalVoiceFiles.delete(file).also { cleaned.countDown() }
        }
        val work = VoiceFileWork(io)
        val lease = work.create(directory.path, "capture-", dispatch = { it() }) { _, error -> assertNull(error); ready.countDown() }
        try {
            await(ready); File(lease.path).writeBytes(byteArrayOf(1, 2, 3))
            lease.read { bytes, error -> assertNull(bytes); assertNotNull(error); delivered.countDown() }
            await(entered); lease.cancel(); await(delivered)
            assertEquals(1, work.outstanding()); assertEquals(1L, cleaned.count)
            unblock.countDown(); await(cleaned)
        } finally { unblock.countDown() }
    }
    @Test fun queuedResultDeliveryKeepsAdmissionEvenAfterFileDeletion() {
        val directory = root()
        val posted = java.util.concurrent.LinkedBlockingQueue<() -> Unit>()
        val ready = CountDownLatch(1); val cleaned = CountDownLatch(1)
        val acknowledgeDeletion = CountDownLatch(1)
        val io = object : VoiceFiles by LocalVoiceFiles {
            override fun delete(file: File): Boolean = LocalVoiceFiles.delete(file).also {
                cleaned.countDown(); hold(acknowledgeDeletion)
            }
        }
        val work = VoiceFileWork(io)
        val lease = work.create(directory.path, "playback-", byteArrayOf(1), { posted.add(it); ready.countDown() }) { _, _ -> }
        try {
            await(ready); lease.cancel(); await(cleaned)
            assertTrue(directory.listFiles()!!.isEmpty())
            assertEquals(1, work.outstanding())
            repeat(2) { posted.poll(5, TimeUnit.SECONDS)?.invoke() ?: fail("Missing queued delivery") }
            // The file is gone, but cleanup still owns admission until delete returns.
            assertEquals(1, work.outstanding())
            acknowledgeDeletion.countDown()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (work.outstanding() != 0 && System.nanoTime() < deadline) Thread.sleep(1)
            assertEquals(0, work.outstanding())
        } finally { acknowledgeDeletion.countDown(); lease.cancel(); directory.deleteRecursively() }
    }

    @Test fun failedDeletionRetainsOwnedFileAndAdmission() {
        val directory = root()
        val ready = CountDownLatch(1); val attempted = CountDownLatch(1)
        val work = VoiceFileWork(object : VoiceFiles by LocalVoiceFiles {
            override fun delete(file: File): Boolean { attempted.countDown(); return false }
        })
        val lease = work.create(directory.path, "playback-", byteArrayOf(1), { it() }) { _, error -> assertNull(error); ready.countDown() }
        try {
            await(ready); lease.cancel(); await(attempted)
            assertEquals(1, work.outstanding())
            assertEquals(1, directory.listFiles()!!.size)
        } finally { directory.deleteRecursively() }
    }

}
