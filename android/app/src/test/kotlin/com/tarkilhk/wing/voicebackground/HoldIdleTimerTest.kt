package com.tarkilhk.wing.voicebackground

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HoldIdleTimerTest {
    @Test
    fun `not expired before the timeout elapses`() {
        val subject = HoldIdleTimer(timeoutMs = 60_000L)
        subject.start(now = 1_000L)
        assertFalse(subject.expired(now = 1_000L + 59_999L))
    }

    @Test
    fun `expired once the timeout has fully elapsed since start`() {
        val subject = HoldIdleTimer(timeoutMs = 60_000L)
        subject.start(now = 1_000L)
        assertTrue(subject.expired(now = 1_000L + 60_000L))
    }

    @Test
    fun `touch pushes the deadline back from the activity time`() {
        val subject = HoldIdleTimer(timeoutMs = 60_000L)
        subject.start(now = 0L)
        subject.touch(now = 50_000L)
        assertFalse(subject.expired(now = 100_000L))
        assertTrue(subject.expired(now = 110_000L))
    }

    @Test
    fun `stopped timer never reports expired`() {
        val subject = HoldIdleTimer(timeoutMs = 60_000L)
        subject.start(now = 0L)
        subject.stop()
        assertFalse(subject.expired(now = 1_000_000L))
    }
}
