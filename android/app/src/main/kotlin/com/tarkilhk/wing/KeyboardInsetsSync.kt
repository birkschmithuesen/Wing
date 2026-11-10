package com.tarkilhk.wing

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsAnimationCompat
import androidx.core.view.WindowInsetsCompat
import io.flutter.embedding.android.FlutterView

/** Settled window geometry belongs to Android, not a deferred IME animation snapshot. */
internal class KeyboardInsetsSync(activity: Activity) : AutoCloseable {
    private val root = activity.window.decorView
    private val animations = mutableSetOf<WindowInsetsAnimationCompat>()
    private var closed = false
    private val synchronize = Runnable {
        if (!closed && root.isAttachedToWindow && root.hasWindowFocus() && animations.isEmpty()) {
            val view = findFlutterView(root)
            val current = view?.rootWindowInsets
            // Dispatching through the deferring listener can consume these again.
            // Use the same public entry point Flutter uses for animation progress.
            if (current != null) view.onApplyWindowInsets(current)
        }
    }

    init {
        ViewCompat.setWindowInsetsAnimationCallback(root, object : WindowInsetsAnimationCompat.Callback(
            DISPATCH_MODE_CONTINUE_ON_SUBTREE,
        ) {
            override fun onPrepare(animation: WindowInsetsAnimationCompat) {
                root.removeCallbacks(synchronize)
                animations.add(animation)
            }

            override fun onProgress(
                insets: WindowInsetsCompat,
                runningAnimations: MutableList<WindowInsetsAnimationCompat>,
            ): WindowInsetsCompat = insets

            override fun onEnd(animation: WindowInsetsAnimationCompat) {
                animations.remove(animation)
                // Parent callbacks run before Flutter's child callback. Reconcile
                // afterward, when it may have replayed an obsolete cached inset.
                schedule()
            }
        })
    }

    fun onWindowFocusChanged(hasFocus: Boolean) {
        root.removeCallbacks(synchronize)
        if (hasFocus) schedule()
        else animations.clear() // A detached/covered window may never receive onEnd.
    }

    private fun schedule() {
        if (closed) return
        root.removeCallbacks(synchronize)
        root.post(synchronize)
    }

    private fun findFlutterView(view: View): FlutterView? {
        if (view is FlutterView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) {
            findFlutterView(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    override fun close() {
        closed = true
        root.removeCallbacks(synchronize)
        animations.clear()
        ViewCompat.setWindowInsetsAnimationCallback(root, null)
    }
}
