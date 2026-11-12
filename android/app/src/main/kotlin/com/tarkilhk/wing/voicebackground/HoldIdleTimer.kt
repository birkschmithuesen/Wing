package com.tarkilhk.wing.voicebackground

/** Safety backstop for [BackgroundVoiceService]: expires [timeoutMs] after the
 * last recorded activity, independent of whether the conversation loop told
 * the service to stop. Guards against a hold that outlives its conversation
 * because some other end-of-loop signal never arrived. Clock values are
 * caller-supplied (`SystemClock.elapsedRealtime()` in production) so this
 * stays a plain, unit-testable value holder. */
class HoldIdleTimer(private val timeoutMs: Long) {
    private var deadline: Long? = null

    fun start(now: Long) {
        deadline = now + timeoutMs
    }

    /** Records fresh activity (a `listening()` call), pushing the deadline out. */
    fun touch(now: Long) {
        if (deadline != null) deadline = now + timeoutMs
    }

    fun stop() {
        deadline = null
    }

    fun expired(now: Long): Boolean {
        val at = deadline ?: return false
        return now > at
    }
}
