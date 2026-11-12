package com.tarkilhk.wing

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Local durable mutations stay ordered, independently of all provider workers.
 * Overload is explicit; this owner never runs rejected work on its caller. */
class BoundedIntakeQueue {
    private val executor = ThreadPoolExecutor(
        1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(32),
        { runnable -> Thread(runnable, "Wing intake").apply { isDaemon = true } },
    )

    fun submit(action: () -> Unit): Boolean = try {
        executor.execute { action() }
        true
    } catch (_: RejectedExecutionException) {
        false
    }
}
