package com.tarkilhk.wing

/** Captured method replies for one Activity host of the retained engine.
 * Retirement cancels work still waiting for admission. An admitted local
 * mutation drains its real outcome; Activity visibility cannot undo its commit.
 * Completion is captured before posting and delivered exactly once. */
internal class IntakeMethodReplies(private val dispatch: (() -> Unit) -> Unit) {
    private var active = true
    private val replies = mutableSetOf<Reply>()

    inner class Reply internal constructor(private val cancelled: () -> Unit) {
        private var started = false
        private var completion: (() -> Unit)? = null
        private var delivered = false
        val isActive: Boolean get() = synchronized(this@IntakeMethodReplies) { active }

        fun admit(): Boolean = synchronized(this@IntakeMethodReplies) {
            if (!active || started || delivered || completion != null) false
            else { started = true; true }
        }

        fun complete(action: () -> Unit) {
            synchronized(this@IntakeMethodReplies) {
                if (delivered || completion != null) return
                completion = action
            }
            dispatch(::deliver)
        }

        internal fun retire() {
            synchronized(this@IntakeMethodReplies) {
                if (started || delivered || completion != null) return
                completion = cancelled
            }
            dispatch(::deliver)
        }

        private fun deliver() {
            val action = synchronized(this@IntakeMethodReplies) {
                if (delivered) null else completion?.also {
                    delivered = true
                    completion = null
                    replies.remove(this)
                }
            } ?: return
            action()
        }
    }

    fun register(cancelled: () -> Unit): Reply {
        val reply = Reply(cancelled)
        val retired = synchronized(this) {
            replies.add(reply)
            !active
        }
        if (retired) reply.retire()
        return reply
    }

    fun retire() {
        val pending = synchronized(this) {
            active = false
            replies.toList()
        }
        pending.forEach { it.retire() }
    }
}
