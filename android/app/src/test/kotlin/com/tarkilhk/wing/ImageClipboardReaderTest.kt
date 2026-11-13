package com.tarkilhk.wing

import java.io.ByteArrayInputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class ImageClipboardReaderTest {
    private fun await(latch: CountDownLatch) = assertTrue(latch.await(3, TimeUnit.SECONDS))
    private fun ignoreInterruptions(latch: CountDownLatch) {
        while (true) try { latch.await(); return } catch (_: InterruptedException) { }
    }

    @Test fun timeoutSettlesBeforeUncooperativeOpenAndClosesItsLateStream() {
        val work = BoundedProviderWork(deadlineMillis = 500)
        val reader = ImageClipboardReader({ it() }, work)
        val entered = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val failed = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val completions = AtomicInteger()
        try {
            assertTrue(reader.read({
                entered.countDown()
                ignoreInterruptions(unblock)
                object : ByteArrayInputStream(byteArrayOf(1, 2)) {
                    override fun close() { super.close(); closed.countDown() }
                }
            }) { bytes, error ->
                completions.incrementAndGet()
                assertNull(bytes)
                assertTrue(error is java.util.concurrent.CancellationException)
                failed.countDown()
            })
            await(entered)
            await(failed)
            assertEquals(1, work.outstanding())
            unblock.countDown()
            await(closed)
            assertEquals(1, completions.get())
        } finally { unblock.countDown(); reader.dispose() }
    }

    @Test fun disposalSettlesHeldReadAndRejectsFurtherAdmission() {
        val reader = ImageClipboardReader({ it() }, BoundedProviderWork(deadlineMillis = 60_000))
        val entered = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val failed = CountDownLatch(1)
        val closed = CountDownLatch(1)
        try {
            reader.read({
                entered.countDown()
                ignoreInterruptions(unblock)
                object : ByteArrayInputStream(byteArrayOf(1)) {
                    override fun close() { super.close(); closed.countDown() }
                }
            }) { bytes, error ->
                assertNull(bytes); assertNotNull(error); failed.countDown()
            }
            await(entered)
            reader.dispose()
            await(failed)
            assertFalse(reader.read({ fail("retired provider must not open"); null }) { _, _ ->
                fail("rejected operation must not complete")
            })
            unblock.countDown()
            await(closed)
        } finally { unblock.countDown(); reader.dispose() }
    }

    @Test fun disposalBetweenReadyAndUiDeliveryCannotPublishBytes() {
        val ui = LinkedBlockingQueue<() -> Unit>()
        val reader = ImageClipboardReader({ ui.add(it) }, BoundedProviderWork(deadlineMillis = 60_000))
        val completions = AtomicInteger()
        reader.read({ ByteArrayInputStream(byteArrayOf(1, 2)) }) { bytes, error ->
            completions.incrementAndGet()
            assertNull(bytes)
            assertTrue(error is java.util.concurrent.CancellationException)
        }
        val delivery = ui.poll(3, TimeUnit.SECONDS)
        assertNotNull(delivery)
        reader.dispose()
        delivery!!()
        assertEquals(1, completions.get())
        assertTrue(ui.isEmpty())
    }

    @Test fun oversizedClipboardContentIsRejectedAndClosed() {
        val reader = ImageClipboardReader({ it() }, BoundedProviderWork(deadlineMillis = 60_000), maxBytes = 4)
        val rejected = CountDownLatch(1)
        val closed = CountDownLatch(1)
        reader.read({
            object : ByteArrayInputStream(byteArrayOf(1, 2, 3, 4, 5)) {
                override fun close() { super.close(); closed.countDown() }
            }
        }) { bytes, error ->
            assertNull(bytes)
            assertTrue(error is IllegalArgumentException)
            rejected.countDown()
        }
        await(rejected)
        await(closed)
        reader.dispose()
    }

    @Test fun exactClipboardByteLimitReturnsTheOriginalBytes() {
        val reader = ImageClipboardReader({ it() }, BoundedProviderWork(deadlineMillis = 60_000), maxBytes = 4)
        val delivered = CountDownLatch(1)
        try {
            reader.read({ ByteArrayInputStream(byteArrayOf(1, 2, 3, 4)) }) { bytes, error ->
                assertNull(error)
                assertArrayEquals(byteArrayOf(1, 2, 3, 4), bytes)
                delivered.countDown()
            }
            await(delivered)
        } finally { reader.dispose() }
    }
}
