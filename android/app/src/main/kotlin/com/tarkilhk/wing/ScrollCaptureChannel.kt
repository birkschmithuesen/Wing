package com.tarkilhk.wing

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.Rect
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.ScrollCaptureCallback
import android.view.ScrollCaptureSession
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.function.Consumer
import kotlin.math.roundToInt

/** Android discovers a real scroll target rather than an opaque Flutter surface.
 * The route token and generation fence every late Dart/raster callback. */
class ScrollCaptureChannel(private val activity: Activity, messenger: BinaryMessenger) : AutoCloseable {
    private val channel = MethodChannel(messenger, "com.tarkilhk.wing/scroll_capture")
    private val handler = Handler(Looper.getMainLooper())
    private var target: View? = null
    private var routeId: Number? = null
    private var bounds = Rect()
    private var generation = 0
    private var activeId: Number? = null
    private var active = false
    private var baseline = 0.0

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "register" -> {
                    if (Build.VERSION.SDK_INT >= 31) {
                        val args = call.arguments as? Map<*, *>
                        val id = args?.get("id") as? Number
                        val rect = rectFrom(args)
                        if (id != null && rect != null) {
                            if (routeId != id) generation++
                            routeId = id
                            bounds = rect
                            val view = findFlutterView(activity.window.decorView)
                            if (view != target) {
                                target?.setScrollCaptureCallback(null)
                                target = view
                            }
                            view?.setScrollCaptureHint(View.SCROLL_CAPTURE_HINT_INCLUDE)
                            view?.setScrollCaptureCallback(callback)
                        }
                    }
                    result.success(null)
                }
                "unregister" -> {
                    if (call.argument<Number>("id") == routeId) detach()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun rectFrom(data: Map<*, *>?): Rect? {
        fun coordinate(key: String) = (data?.get(key) as? Number)?.toDouble()?.takeIf { it.isFinite() }?.roundToInt()
        val left = coordinate("left") ?: return null
        val top = coordinate("top") ?: return null
        val right = coordinate("right") ?: return null
        val bottom = coordinate("bottom") ?: return null
        return Rect(left, top, right, bottom).takeUnless { it.isEmpty }
    }

    private fun findFlutterView(view: View): View? {
        if (view is FlutterView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) {
            findFlutterView(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    // Android callbacks must always complete, including a detached engine.
    private fun invoke(method: String, id: Number?, values: Map<String, Any> = emptyMap(), done: (Map<*, *>?) -> Unit) {
        var settled = false
        fun complete(value: Map<*, *>?) {
            if (settled) return
            settled = true
            done(value)
        }
        val deadline = Runnable { complete(null) }
        handler.postDelayed(deadline, 1500)
        channel.invokeMethod(method, mapOf("id" to id) + values, object : MethodChannel.Result {
            override fun success(result: Any?) {
                handler.removeCallbacks(deadline)
                complete(result as? Map<*, *>)
            }
            override fun error(code: String, message: String?, details: Any?) {
                handler.removeCallbacks(deadline)
                complete(null)
            }
            override fun notImplemented() {
                handler.removeCallbacks(deadline)
                complete(null)
            }
        })
    }

    private val callback: ScrollCaptureCallback by lazy {
        object : ScrollCaptureCallback {
            override fun onScrollCaptureSearch(signal: CancellationSignal, ready: Consumer<Rect>) {
                val captured = generation
                invoke("metrics", routeId) { data ->
                    val max = (data?.get("max") as? Number)?.toDouble() ?: 0.0
                    val min = (data?.get("min") as? Number)?.toDouble() ?: 0.0
                    ready.accept(if (!signal.isCanceled && captured == generation && max > min) rectFrom(data) ?: Rect() else Rect())
                }
            }

            override fun onScrollCaptureStart(session: ScrollCaptureSession, signal: CancellationSignal, ready: Runnable) {
                val captured = ++generation
                activeId = routeId
                active = true
                invoke("start", activeId) { data ->
                    if (captured == generation && !signal.isCanceled && data != null) {
                        baseline = (data["offset"] as? Number)?.toDouble() ?: 0.0
                    } else {
                        active = false
                        invoke("end", activeId) {}
                    }
                    ready.run()
                }
            }

            override fun onScrollCaptureImageRequest(session: ScrollCaptureSession, signal: CancellationSignal, area: Rect, ready: Consumer<Rect>) {
                val captured = generation
                if (!active || signal.isCanceled || area.isEmpty) {
                    ready.accept(Rect())
                    return
                }
                invoke("scroll", activeId, mapOf("offset" to (baseline + area.top))) { data ->
                    val view = target
                    val viewport = rectFrom(data)
                    val offset = (data?.get("offset") as? Number)?.toDouble()
                    if (!active || captured != generation || signal.isCanceled || view == null || viewport == null || offset == null) {
                        ready.accept(Rect())
                        return@invoke
                    }
                    val delta = (offset - baseline).roundToInt()
                    val available = Rect(0, delta, viewport.width(), delta + viewport.height())
                    if (!available.intersect(area)) {
                        ready.accept(Rect())
                        return@invoke
                    }
                    // PixelCopy reads the final Flutter raster, including textures.
                    val location = IntArray(2)
                    view.getLocationInWindow(location)
                    val source = Rect(available).apply {
                        offset(viewport.left + location[0], viewport.top + location[1] - delta)
                    }
                    val bitmap = Bitmap.createBitmap(available.width(), available.height(), Bitmap.Config.ARGB_8888)
                    try {
                        PixelCopy.request(activity.window, source, bitmap, { status ->
                            var delivered = Rect()
                            try {
                                if (status == PixelCopy.SUCCESS && active && captured == generation && !signal.isCanceled && session.surface.isValid) {
                                    val canvas = session.surface.lockCanvas(null)
                                    try {
                                        canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
                                        canvas.drawBitmap(bitmap, 0f, 0f, Paint())
                                    } finally {
                                        session.surface.unlockCanvasAndPost(canvas)
                                    }
                                    delivered = available
                                }
                            } catch (_: Exception) {
                                // A canceled system capture can destroy its Surface.
                            } finally {
                                bitmap.recycle()
                                ready.accept(delivered)
                            }
                        }, handler)
                    } catch (_: Exception) {
                        bitmap.recycle()
                        ready.accept(Rect())
                    }
                }
            }

            override fun onScrollCaptureEnd(ready: Runnable) {
                active = false
                generation++
                invoke("end", activeId) { ready.run() }
                activeId = null
            }
        }
    }

    private fun detach() {
        active = false
        generation++
        if (Build.VERSION.SDK_INT >= 31) {
            target?.setScrollCaptureCallback(null)
            target?.setScrollCaptureHint(View.SCROLL_CAPTURE_HINT_AUTO)
        }
        target = null
        routeId = null
    }

    override fun close() {
        if (active) invoke("end", activeId) {}
        detach()
        channel.setMethodCallHandler(null)
    }
}
