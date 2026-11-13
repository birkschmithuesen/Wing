package com.tarkilhk.wing

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class BoundedProviderWorkTest {
    private fun await(latch: CountDownLatch) = assertTrue(latch.await(3, TimeUnit.SECONDS))
    private fun ignoreInterruptions(latch: CountDownLatch) {
        while (true) try { latch.await(); return } catch (_: InterruptedException) { }
    }

    @Test fun timeoutRetainsUninterruptibleProviderAndFencesLateWrite() {
        val owner = BoundedProviderWork(deadlineMillis = 60_000)
        val entered = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val failed = CountDownLatch(1)
        val released = CountDownLatch(1)
        val writes = AtomicInteger()
        val closed = AtomicInteger()
        lateinit var lease: BoundedProviderWork.Lease
        try {
            assertTrue(owner.submit(Any(), { released.countDown(); true }, { attempt ->
                lease = attempt
                attempt.reserveBytes(8)
                entered.countDown()
                ignoreInterruptions(unblock) // malicious read/open ignoring Future.cancel.
                attempt.own(AutoCloseable { closed.incrementAndGet() })
                attempt.publish { writes.incrementAndGet() }
            }, { _, _, error -> assertNotNull(error); failed.countDown() }))
            await(entered)
            lease.retire()
            await(failed)
            assertEquals(1, owner.outstanding())
            assertEquals(8L, owner.stagedBytes())
            assertEquals(1L, released.count)
            unblock.countDown()
            await(released)
            assertEquals(0, writes.get())
            assertEquals(1, closed.get())
        } finally { unblock.countDown() }
    }

    @Test fun stalledCloseKeepsAdmissionAndStageCharged() {
        val owner = BoundedProviderWork(deadlineMillis = 60_000)
        val closing = CountDownLatch(1)
        val allowClose = CountDownLatch(1)
        val delivered = CountDownLatch(1)
        val deleted = CountDownLatch(1)
        try {
            owner.submit(Any(), { deleted.countDown(); true }, { lease ->
                lease.reserveBytes(4)
                lease.own(AutoCloseable { closing.countDown(); ignoreInterruptions(allowClose) })
                "ready"
            }, { lease, value, error ->
                assertNull(error)
                assertEquals("ready", value)
                lease.finish()
                delivered.countDown()
            })
            await(delivered)
            await(closing)
            assertEquals(1, owner.outstanding())
            assertEquals(4L, owner.stagedBytes())
            assertEquals(1L, deleted.count)
            allowClose.countDown()
            await(deleted)
        } finally { allowClose.countDown() }
    }

    @Test fun saturatedWorkersAndQueuedExpiryNeverInvokeQueuedProviders() {
        val owner = BoundedProviderWork(deadlineMillis = 60_000)
        val entered = CountDownLatch(2)
        val unblock = CountDownLatch(1)
        val finished = CountDownLatch(4)
        val failures = CountDownLatch(4)
        val authority = Any()
        val providers = AtomicInteger()
        try {
            repeat(4) {
                assertTrue(owner.submit(authority, { finished.countDown(); true }, { lease ->
                    providers.incrementAndGet()
                    entered.countDown()
                    ignoreInterruptions(unblock)
                    lease.check()
                }, { _, _, error -> assertNotNull(error); failures.countDown() }))
            }
            await(entered)
            assertFalse(owner.submit(Any(), { true }, { _ -> fail("capacity must reject") }, { _, _, _ -> }))
            owner.cancel(authority)
            await(failures)
            assertEquals(2, providers.get())
            unblock.countDown()
            await(finished)
            assertEquals(2, providers.get())
        } finally { unblock.countDown() }
    }

    @Test fun cancellationAfterReadyCannotPublishAndByteBudgetRejectsOvershoot() {
        val owner = BoundedProviderWork(deadlineMillis = 60_000, stagingByteLimit = 4)
        val ready = CountDownLatch(1)
        val release = CountDownLatch(1)
        lateinit var lease: BoundedProviderWork.Lease
        val authority = Any()
        assertTrue(owner.submit(authority, { release.countDown(); true }, { attempt ->
            attempt.reserveBytes(4)
            try { attempt.reserveBytes(1); fail("expected budget rejection") }
            catch (_: IllegalStateException) { }
            "complete"
        }, { attempt, _, error -> assertNull(error); lease = attempt; ready.countDown() }))
        await(ready)
        owner.cancel(authority)
        try { lease.publish { fail("late durable publication") }; fail("expected retirement") }
        catch (_: java.util.concurrent.CancellationException) { }
        lease.finish()
        await(release)
    }

    @Test fun absoluteDeadlineFiresWithoutProviderCooperation() {
        val owner = BoundedProviderWork(deadlineMillis = 50)
        val entered = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val failed = CountDownLatch(1)
        try {
            owner.submit(Any(), { true }, { _ -> entered.countDown(); ignoreInterruptions(unblock) },
                { _, _, error -> assertNotNull(error); failed.countDown() })
            await(entered)
            await(failed) // No wall-clock assertion; deterministic outcome has a generous test watchdog.
            assertEquals(1, owner.outstanding())
        } finally { unblock.countDown() }
    }
}
