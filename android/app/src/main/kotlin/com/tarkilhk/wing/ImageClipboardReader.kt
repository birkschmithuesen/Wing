package com.tarkilhk.wing

import java.io.ByteArrayOutputStream
import java.io.InputStream

/** Clipboard provider I/O has the same bounded retirement and late-close owner
 * as file intake. Uninterruptible calls remain charged; they never block delivery. */
class ImageClipboardReader(
    private val dispatch: (() -> Unit) -> Unit,
    private val work: BoundedProviderWork = sharedWork,
    private val maxBytes: Int = 64 * 1024 * 1024,
) {
    private val authority = Any()
    private var closed = false

    fun read(open: () -> InputStream?, completed: (ByteArray?, Exception?) -> Unit): Boolean {
        if (closed) return false
        return work.submit(authority, { true }, { lease ->
            val input = open()?.let { lease.own(it) }
                ?: throw IllegalStateException("image_unavailable")
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                lease.check()
                val count = input.read(buffer)
                lease.check()
                if (count < 0) break
                if (count > maxBytes - output.size()) {
                    throw IllegalArgumentException("too_large")
                }
                // Account for the accumulator and its delivered byte-array copy.
                lease.reserveBytes(count * 2)
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }, { lease, bytes, error ->
            dispatch {
                val failure = error ?: try { lease.check(); null } catch (retired: Exception) { retired }
                try { completed(if (failure == null) bytes else null, failure) }
                finally { lease.finish() }
            }
        })
    }

    fun dispose() {
        closed = true
        work.cancel(authority)
    }

    companion object {
        // Application-wide admission survives Activity recreation. A stuck foreign
        // provider cannot acquire a new pool of workers by reopening the Activity.
        private val sharedWork = BoundedProviderWork()
    }
}
