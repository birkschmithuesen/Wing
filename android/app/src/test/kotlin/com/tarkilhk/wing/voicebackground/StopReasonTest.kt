package com.tarkilhk.wing.voicebackground

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StopReasonTest {
    @Test
    fun `first resolve wins and returns its reason`() {
        val subject = StopReason()
        assertEquals("silence", subject.resolve("silence"))
        assertEquals("silence", subject.reason)
    }

    @Test
    fun `later resolve calls are ignored once a reason won`() {
        val subject = StopReason()
        subject.resolve("silence")
        assertNull(subject.resolve("call"))
        assertEquals("silence", subject.reason)
    }

    @Test
    fun `no reason recorded before the first resolve`() {
        val subject = StopReason()
        assertNull(subject.reason)
    }
}
