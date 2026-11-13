package com.tarkilhk.wing

import org.junit.Assert.*
import org.junit.Test

class VoiceOperationTest {
    @Test fun reusedPublicIdCannotAuthorizeOldRecognizerPlayerOrTtsCallback() {
        val owner = VoiceOperations()
        val old = owner.begin("same")
        val fresh = owner.begin("same")
        assertFalse(owner.owns(old))
        assertTrue(owner.owns(fresh))
        assertNotEquals(old.generation, fresh.generation)
        assertFalse(owner.retire(old))
        assertTrue(owner.owns(fresh))
        assertTrue(owner.retire(fresh))
        assertFalse(owner.owns(fresh))
    }
    @Test fun resultSettlesOnceEvenIfCallbackReentersThenLateSuccessArrives() {
        var calls = 0
        lateinit var reply: VoiceReply<String>
        reply = VoiceReply { value, error ->
            calls++
            assertNull(value)
            assertNotNull(error)
            assertFalse(reply.settle("late"))
        }
        assertTrue(reply.settle(error = IllegalStateException("disposed")))
        assertFalse(reply.settle("encoded"))
        assertEquals(1, calls)
    }
    @Test fun cancelledPermissionDoesNotBindOldSystemCallbackToNewRequest() {
        val requests = VoicePermissionRequests<String>()
        val old = requests.begin("first")
        old.cancel()
        assertNull(old.value)
        try { requests.begin("second"); fail("Android slot is still occupied") } catch (_: IllegalStateException) {}
        assertSame(old, requests.finish())
        assertTrue(old.cancelled)
        val fresh = requests.begin("second")
        assertSame(fresh, requests.finish())
        assertFalse(fresh.cancelled)
    }

    @Test fun recreatedOwnerCannotAcquireCancelledProcessSlotWithReusedId() {
        data class Permission(val owner: Any, val id: String)
        val process = VoicePermissionRequests<Permission>()
        val disposedOwner = Any()
        val recreatedOwner = Any()
        val outstanding = process.begin(Permission(disposedOwner, "same"))
        outstanding.cancel()
        assertNull(outstanding.value) // A held OS slot does not retain the Activity.
        try {
            process.begin(Permission(recreatedOwner, "same"))
            fail("Recreation cannot authorize an old Android result")
        } catch (_: IllegalStateException) {}
        assertSame(outstanding, process.finish()) // The real OS callback retires it.
        val fresh = process.begin(Permission(recreatedOwner, "same"))
        assertSame(recreatedOwner, fresh.value!!.owner)
        assertNotSame(outstanding, fresh)
    }

}
