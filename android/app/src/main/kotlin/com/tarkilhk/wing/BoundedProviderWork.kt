package com.tarkilhk.wing

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CancellationException
import java.util.concurrent.FutureTask
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.Semaphore
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/** Foreign calls cannot be made interruptible by a Future. Retired workers and
 * cleanup remain charged to admission until both actually finish; none are replaced. */
class BoundedProviderWork(
    private val deadlineMillis: Long = 15_000,
    private val stagingByteLimit: Long = 256L * 1024 * 1024,
) {
    init { require(deadlineMillis > 0 && stagingByteLimit > 0) }

    private val permits = Semaphore(4)
    private val bytes = AtomicLong()
    private val workers = pool("Wing provider")
    private val cleanup = pool("Wing provider cleanup", 4)
    private val deadlines = ScheduledThreadPoolExecutor(1, daemon("Wing provider deadline")).apply {
        removeOnCancelPolicy = true
    }
    private val operations = mutableSetOf<Lease>()

    inner class Lease internal constructor(
        val authority: Any,
        private val releaseStage: () -> Boolean,
        private val failure: (Exception) -> Unit,
    ) {
        // Java monitor supplies the condition needed for late resource handoff.
        @Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN")
        private val lock = Object()
        private var active = true
        private var delivered = false
        private var producerDone = false
        private var cleanupStarted = false
        private var cleanupDone = false
        private var publicationDone = false
        private var chargedBytes = 0L
        private val resources = ArrayDeque<AutoCloseable>()
        internal var task: FutureTask<Unit>? = null
        @Volatile internal var started = false
        internal var timer: java.util.concurrent.ScheduledFuture<*>? = null

        fun check() = synchronized(lock) {
            if (!active) throw CancellationException("Provider attempt retired")
        }

        /** Only local bounded writes/commits belong here, never a provider call. */
        fun <T> publish(action: () -> T): T = synchronized(lock) {
            check()
            action()
        }

        fun reserveBytes(count: Int) = synchronized(lock) {
            require(count >= 0)
            check()
            val total = bytes.addAndGet(count.toLong())
            if (total > stagingByteLimit) {
                bytes.addAndGet(-count.toLong())
                throw IllegalStateException("Provider staging capacity exhausted")
            }
            chargedBytes += count
        }

        fun <T : AutoCloseable> own(resource: T): T = synchronized(lock) {
            // A late open still transfers its resource to the existing cleanup owner.
            resources.addLast(resource)
            lock.notifyAll()
            check()
            resource
        }

        fun finish() {
            synchronized(lock) { active = false; publicationDone = true }
            releaseIfFinished()
        }

        internal fun succeed(deliver: () -> Unit) {
            val accepted = synchronized(lock) {
                if (!active || delivered) false else { delivered = true; true }
            }
            if (!accepted) return
            timer?.cancel(false)
            try { deliver() } catch (error: Exception) { retire(error) }
        }

        internal fun retire(error: Exception = CancellationException("Provider attempt retired")) {
            val notify = synchronized(lock) {
                active = false
                publicationDone = true
                if (delivered) false else { delivered = true; true }
            }
            timer?.cancel(false)
            task?.cancel(true) // Best effort only: does not release a running worker's permit.
            if (task != null && workers.remove(task)) producerFinished()
            startCleanup()
            if (notify) try { failure(error) } catch (_: Exception) { }
            releaseIfFinished()
        }

        internal fun producerFinished() {
            synchronized(lock) { producerDone = true; lock.notifyAll() }
            startCleanup()
        }

        private fun startCleanup() {
            synchronized(lock) {
                if (cleanupStarted) return
                cleanupStarted = true
            }
            // Four admitted leases plus workers finishing after permit release fit this
            // fixed queue; rejected cleanup must never lose resource ownership.
            cleanup.execute {
                while (true) {
                    val resource = synchronized(lock) {
                        while (resources.isEmpty() && !producerDone) lock.wait()
                        if (resources.isEmpty()) null else resources.removeFirst()
                    } ?: break
                    try { resource.close() } catch (_: Exception) { }
                }
                synchronized(lock) { cleanupDone = true }
                releaseIfFinished()
            }
        }

        private var released = false
        private fun releaseIfFinished() {
            synchronized(lock) {
                if (released || !producerDone || !cleanupDone || !publicationDone) return
                // Do not delete a stage while a retired provider can still return/write.
                // Failed deletion retains admission and its byte charge rather than leaking.
                if (!releaseStage()) return
                released = true
                bytes.addAndGet(-chargedBytes)
            }
            synchronized(operations) { operations.remove(this) }
            permits.release()
        }
    }

    fun <T> submit(
        authority: Any,
        releaseStage: () -> Boolean,
        work: (Lease) -> T,
        completed: (Lease, T?, Exception?) -> Unit,
    ): Boolean {
        if (!permits.tryAcquire()) return false
        lateinit var lease: Lease
        lease = Lease(authority, releaseStage) { completed(lease, null, it) }
        synchronized(operations) { operations.add(lease) }
        val task = object : FutureTask<Unit>({
            lease.started = true
            try {
                lease.check()
                val value = work(lease)
                lease.succeed { completed(lease, value, null) }
            } catch (error: Exception) {
                lease.retire(error)
            } finally {
                lease.producerFinished()
            }
        }) {
            override fun done() {
                if (!lease.started) lease.producerFinished()
            }
        }
        lease.task = task
        lease.timer = deadlines.schedule({ lease.retire() }, deadlineMillis, TimeUnit.MILLISECONDS)
        try { if (!task.isCancelled) workers.execute(task) } catch (error: java.util.concurrent.RejectedExecutionException) {
            lease.retire(error)
            lease.producerFinished()
        }
        // If admission expired before execute, a canceled FutureTask never invokes work.
        if (task.isCancelled && workers.remove(task)) lease.producerFinished()
        return true
    }

    fun cancel(authority: Any) {
        val owned = synchronized(operations) { operations.filter { it.authority === authority } }
        owned.forEach { it.retire() }
    }

    internal fun outstanding(): Int = 4 - permits.availablePermits()
    internal fun stagedBytes(): Long = bytes.get()

    companion object {
        private fun daemon(name: String) = ThreadFactory { runnable ->
            Thread(runnable, name).apply { isDaemon = true }
        }
        private fun pool(name: String, queueSize: Int = 2) = ThreadPoolExecutor(
            2, 2, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(queueSize), daemon(name),
        )
    }
}
