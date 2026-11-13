package com.tarkilhk.wing

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class BoundedIntakeQueueTest {
    @Test fun oneWorkerAndThirtyTwoQueuedActionsRejectInsteadOfRunningOnCaller() {
        val owner = BoundedIntakeQueue()
        val entered = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val complete = CountDownLatch(32)
        val rejectedWrites = AtomicInteger()
        try {
            assertTrue(owner.submit { entered.countDown(); unblock.await() })
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            repeat(32) { assertTrue(owner.submit { complete.countDown() }) }
            assertFalse(owner.submit { rejectedWrites.incrementAndGet() })
            assertEquals(0, rejectedWrites.get())
            unblock.countDown()
            assertTrue(complete.await(3, TimeUnit.SECONDS))
        } finally { unblock.countDown() }
    }
}
