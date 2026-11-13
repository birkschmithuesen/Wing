package com.tarkilhk.wing

/** IDs belong to Flutter; identity belongs to one exact native attempt. */
class VoiceOperation(val id: String, val generation: Long)

class VoiceOperations {
    private var generation = 0L
    var current: VoiceOperation? = null
        private set
    fun begin(id: String): VoiceOperation = VoiceOperation(id, ++generation).also { current = it }
    fun owns(operation: VoiceOperation) = current === operation
    fun retire(operation: VoiceOperation): Boolean {
        if (!owns(operation)) return false
        current = null
        return true
    }
}

/** Mark completed before invoking a callback: callback reentrancy cannot settle twice. */
class VoiceReply<T>(callback: (T?, Exception?) -> Unit) {
    private var callback: ((T?, Exception?) -> Unit)? = callback
    fun settle(value: T? = null, error: Exception? = null): Boolean {
        val deliver = synchronized(this) { callback.also { callback = null } } ?: return false
        deliver(value, error)
        return true
    }
}

/** Android returns only a request code, so cancellation cannot free that slot
 * until the operating system's callback has actually consumed it. */
class VoicePermissionRequests<T> {
    class Request<T>(value: T) {
        var value: T? = value
            private set
        var cancelled = false
            private set
        fun cancel() { cancelled = true; value = null }
    }
    var current: Request<T>? = null
        private set
    fun begin(value: T): Request<T> {
        check(current == null) { "Wait for microphone permission." }
        return Request(value).also { current = it }
    }
    fun finish(): Request<T>? = current.also { current = null }
}
