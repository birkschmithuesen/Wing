package com.tarkilhk.wing

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.AssetManager
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.os.Message
import android.view.View
import android.webkit.HttpAuthHandler
import android.webkit.PermissionRequest
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import java.io.ByteArrayInputStream

internal class MermaidDiagramViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        MermaidDiagramView(context, args as? Map<*, *>)
}

private class MermaidDiagramView(
    context: Context,
    creationParams: Map<*, *>?,
) : PlatformView {
    private val assets: AssetManager = context.assets
    private val webView = WebView(context)
    private val dark = creationParams?.get("dark") as? Boolean ?: false
    private val palette = requireNotNull(creationParams?.get("palette") as? Map<*, *>)
    private fun themeColor(role: String): Int = (palette[role] as Number).toInt()
    private fun cssColor(role: String): String = "#%06X".format(themeColor(role) and 0xFFFFFF)
    private val themeJson: String get() = JSONObject().apply {
        for (role in listOf("canvas", "panel", "text", "muted", "border", "error", "error-surface", "accent")) {
            put(role, cssColor(role))
        }
    }.toString()
    private val source = creationParams?.get("source") as? String
    private val format = (creationParams?.get("format") as? String)
        ?.takeIf { it == SVG_FORMAT || it == HTML_FORMAT || it == MERMAID_FORMAT }
        ?: MERMAID_FORMAT
    private val sourceError = when {
        source == null -> if (format == SVG_FORMAT) {
            "There is no SVG to preview."
        } else if (format == HTML_FORMAT) {
            "There is no HTML to preview."
        } else {
            "This diagram has no source."
        }
        source.length > maxSourceChars() -> if (format == SVG_FORMAT) {
            "This SVG is too large to preview."
        } else if (format == HTML_FORMAT) {
            "This HTML file is too large to preview."
        } else {
            "This diagram is too large to display."
        }
        else -> null
    }

    init {
        configureWebView()
        webView.loadUrl(ENTRY_URL)
    }

    override fun getView(): View = webView

    override fun dispose() {
        webView.stopLoading()
        webView.webChromeClient = null
        webView.webViewClient = WebViewClient()
        webView.loadUrl("about:blank")
        webView.clearHistory()
        webView.removeAllViews()
        webView.destroy()
    }

    @SuppressLint("SetJavaScriptEnabled")
    @Suppress("DEPRECATION")
    private fun configureWebView() {
        webView.setBackgroundColor(themeColor("canvas"))
        webView.isVerticalScrollBarEnabled = true
        webView.isHorizontalScrollBarEnabled = true
        webView.setDownloadListener { _, _, _, _, _ -> }
        webView.removeJavascriptInterface("searchBoxJavaBridge_")
        webView.removeJavascriptInterface("accessibility")
        webView.removeJavascriptInterface("accessibilityTraversal")

        webView.settings.apply {
            javaScriptEnabled = true
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            allowFileAccess = false
            allowContentAccess = false
            blockNetworkLoads = true
            // Local blob/data images need decoding; network requests stay blocked.
            blockNetworkImage = false
            domStorageEnabled = false
            databaseEnabled = false
            setGeolocationEnabled(false)
            cacheMode = WebSettings.LOAD_NO_CACHE
            saveFormData = false
            builtInZoomControls = true
            displayZoomControls = false
            setSupportZoom(true)
            useWideViewPort = true
            loadWithOverviewMode = true
            mediaPlaybackRequiresUserGesture = true
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            webView.settings.safeBrowsingEnabled = true
        }

        webView.webViewClient = object : WebViewClient() {
            private var deliveredSource = false

            override fun shouldInterceptRequest(
                view: WebView,
                request: WebResourceRequest,
            ): WebResourceResponse = assetResponse(request)

            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest,
            ): Boolean = request.isForMainFrame ||
                format != HTML_FORMAT ||
                request.url.buildUpon().fragment(null).build().toString() != HTML_URL

            override fun onPageFinished(view: WebView, url: String) {
                if (deliveredSource || url != ENTRY_URL) return
                deliveredSource = true
                val script = sourceError?.let {
                    "if (typeof window.showDiagramError === 'function') {" +
                        "window.showDiagramError(${javascriptString(it)});" +
                        "} else { ${viewerUnavailableScript()} }"
                } ?: "if (typeof window.${renderFunction()} === 'function') {" +
                    (if (format == HTML_FORMAT) {
                        // The iframe reads a local response; never embed a large
                        // report in an evaluateJavascript command.
                        "window.renderHtml($dark);"
                    } else {
                        "window.${renderFunction()}(${javascriptString(source)}, $dark);"
                    }) +
                    "} else { ${viewerUnavailableScript()} }"
                val themeScript = "if (typeof window.setStudioTheme === 'function') {" +
                    "window.setStudioTheme($dark, $themeJson); }"
                view.evaluateJavascript(themeScript + script, null)
            }

            override fun onReceivedSslError(
                view: WebView,
                handler: SslErrorHandler,
                error: SslError,
            ) {
                handler.cancel()
            }

            override fun onReceivedHttpAuthRequest(
                view: WebView,
                handler: HttpAuthHandler,
                host: String,
                realm: String,
            ) {
                handler.cancel()
            }

            override fun onFormResubmission(view: WebView, dontResend: Message, resend: Message) {
                dontResend.sendToTarget()
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) {
                request.deny()
            }

            override fun onGeolocationPermissionsShowPrompt(
                origin: String,
                callback: android.webkit.GeolocationPermissions.Callback,
            ) {
                callback.invoke(origin, false, false)
            }

            override fun onCreateWindow(
                view: WebView,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: Message,
            ): Boolean = false

            override fun onShowFileChooser(
                webView: WebView,
                filePathCallback: ValueCallback<Array<Uri>>,
                fileChooserParams: FileChooserParams,
            ): Boolean {
                filePathCallback.onReceiveValue(null)
                return true
            }
        }
    }

    private fun assetResponse(request: WebResourceRequest): WebResourceResponse {
        if (request.method != "GET") return deniedResponse()
        if (request.url.toString() == HTML_URL && format == HTML_FORMAT && sourceError == null) {
            return WebResourceResponse(
                "text/html",
                "UTF-8",
                200,
                "OK",
                mapOf(
                    "Cache-Control" to "no-store",
                    "X-Content-Type-Options" to "nosniff",
                    "Content-Security-Policy" to HTML_POLICY,
                ),
                ByteArrayInputStream(requireNotNull(source).toByteArray(Charsets.UTF_8)),
            )
        }
        val asset = ASSETS[request.url.toString()] ?: return deniedResponse()
        return try {
            WebResourceResponse(
                asset.mimeType,
                "UTF-8",
                200,
                "OK",
                mapOf(
                    "Cache-Control" to "no-store",
                    "X-Content-Type-Options" to "nosniff",
                ),
                assets.open("diagrams/${asset.filename}"),
            )
        } catch (_: Exception) {
            WebResourceResponse(
                "text/plain",
                "UTF-8",
                404,
                "Not Found",
                emptyMap(),
                ByteArrayInputStream(ByteArray(0)),
            )
        }
    }

    private fun deniedResponse(): WebResourceResponse = WebResourceResponse(
        "text/plain",
        "UTF-8",
        403,
        "Forbidden",
        emptyMap(),
        ByteArrayInputStream(ByteArray(0)),
    )

    private fun javascriptString(value: String?): String = JSONObject.quote(value)
        .replace("\u2028", "\\u2028")
        .replace("\u2029", "\\u2029")

    private fun viewerUnavailableScript(): String =
        "document.getElementById('diagram').hidden=true;" +
            "document.getElementById('status').hidden=false;"

    private fun renderFunction(): String =
        when (format) {
            SVG_FORMAT -> "renderSvg"
            HTML_FORMAT -> "renderHtml"
            else -> "renderDiagram"
        }

    private fun maxSourceChars(): Int =
        when (format) {
            SVG_FORMAT -> MAX_SVG_SOURCE_CHARS
            HTML_FORMAT -> MAX_HTML_SOURCE_CHARS
            else -> MAX_SOURCE_CHARS
        }

    private data class Asset(val filename: String, val mimeType: String)

    companion object {
        private const val MAX_SOURCE_CHARS = 50_000
        private const val MAX_SVG_SOURCE_CHARS = 256 * 1024
        private const val MAX_HTML_SOURCE_CHARS = 32 * 1024 * 1024
        private const val MERMAID_FORMAT = "mermaid"
        private const val SVG_FORMAT = "svg"
        private const val HTML_FORMAT = "html"
        private const val ORIGIN = "https://wing-diagrams.invalid"
        private const val ENTRY_URL = "$ORIGIN/index.html"
        private const val HTML_URL = "$ORIGIN/report.html"
        private const val HTML_POLICY = "default-src 'none'; script-src 'unsafe-inline'; " +
            "style-src 'unsafe-inline'; img-src data:; connect-src 'none'; font-src 'none'; " +
            "media-src 'none'; form-action 'none'; base-uri 'none'; frame-src 'none'; " +
            "object-src 'none'; worker-src 'none'; sandbox allow-scripts"
        private val ASSETS = mapOf(
            ENTRY_URL to Asset("index.html", "text/html"),
            "$ORIGIN/app.js" to Asset("app.js", "application/javascript"),
            "$ORIGIN/mermaid.min.js" to Asset("mermaid.min.js", "application/javascript"),
        )
    }
}
