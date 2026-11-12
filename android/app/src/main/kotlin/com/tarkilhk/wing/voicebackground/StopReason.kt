package com.tarkilhk.wing.voicebackground

/** First-wins bookkeeping for [BackgroundVoiceService]: whichever trigger (stop
 * command, silence, call, idle timeout, ...) resolves first decides the stop
 * reason; later triggers racing for the same shutdown are told no. */
class StopReason {
    var reason: String? = null
        private set

    /** Returns [reason] if this call is the first to resolve, else null. */
    fun resolve(reason: String): String? {
        if (this.reason != null) return null
        this.reason = reason
        return reason
    }
}
