package com.tarkilhk.wing

import android.app.Activity
import android.graphics.Typeface
import android.graphics.Color
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.RippleDrawable
import androidx.core.graphics.ColorUtils
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.WindowCompat
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.MediaController
import android.widget.ImageButton
import android.widget.SeekBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.VideoView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import java.io.File

internal class MediaPreviewActivity : Activity() {
    private lateinit var mediaFile: File
    private lateinit var mimeType: String
    private lateinit var playerArea: FrameLayout
    private lateinit var player: VideoView
    private lateinit var status: TextView
    private lateinit var statusContainer: ScrollView
    private lateinit var controls: MediaController
    private var prepared = false
    private var started = false
    private var preparationGeneration = 0
    private var savedPosition = 0
    private var ownsMediaFile = false
    private var canvasColor = Color.BLACK
    private var inkColor = Color.WHITE
    private var errorColor = Color.RED

    override fun onCreate(savedInstanceState: Bundle?) {
        val systemDark = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val dark = intent.getIntExtra("studio_dark", if (systemDark) 1 else 0) == 1
        setTheme(if (dark) R.style.StudioMediaDark else R.style.StudioMediaLight)
        super.onCreate(savedInstanceState)
        savedPosition = savedInstanceState?.getInt(STATE_POSITION) ?: 0
        mimeType = intent.getStringExtra(EXTRA_MIME_TYPE)?.lowercase().orEmpty()
        val resolvedFile = resolveMediaFile(intent.getStringExtra(EXTRA_FILE_NAME))
        ownsMediaFile = resolvedFile != null
        mediaFile = resolvedFile ?: File(cacheDir, "invalid")
        buildLayout(intent.getStringExtra(EXTRA_TITLE).orEmpty())
        if (!isValidMedia()) showError()
    }

    override fun onStart() {
        super.onStart()
        started = true
        if (isValidMedia()) prepareMedia()
    }

    override fun onPause() {
        if (prepared) {
            savedPosition = runCatching { player.currentPosition }.getOrDefault(savedPosition)
            runCatching { if (player.isPlaying) player.pause() }
        }
        super.onPause()
    }

    override fun onStop() {
        started = false
        preparationGeneration++
        player.setOnPreparedListener(null)
        player.setOnErrorListener(null)
        player.stopPlayback()
        prepared = false
        controls.hide()
        super.onStop()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        if (prepared) {
            savedPosition = runCatching { player.currentPosition }.getOrDefault(savedPosition)
        }
        outState.putInt(STATE_POSITION, savedPosition)
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        if (!isChangingConfigurations && ownsMediaFile) mediaFile.delete()
        super.onDestroy()
    }

    private fun buildLayout(rawTitle: String) {
        val systemDark = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val dark = intent.getIntExtra("studio_dark", if (systemDark) 1 else 0) == 1
        val canvas = intent.getIntExtra("studio_surface", Color.parseColor(if (dark) "#101B24" else "#F7F7F4"))
        val ink = intent.getIntExtra("studio_text", Color.parseColor(if (dark) "#EBF1F2" else "#1B2D36"))
        val accent = intent.getIntExtra("studio_accent", Color.parseColor(if (dark) "#65C7BC" else "#126D70"))
        val onAccent = intent.getIntExtra("studio_onAccent", Color.parseColor(if (dark) "#102C32" else "#FFFFFF"))
        canvasColor = canvas
        inkColor = ink
        errorColor = intent.getIntExtra("studio_error", Color.parseColor(if (dark) "#F87171" else "#B3261E"))
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = !dark
            isAppearanceLightNavigationBars = !dark
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(canvas)
        }
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout(),
            )
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        val header = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(4), dp(16), dp(4))
        }
        header.addView(Button(this).apply {
            text = "Back"
            contentDescription = "Return to Outputs"
            minHeight = dp(48)
            minWidth = dp(48)
            minimumWidth = dp(48)
            isAllCaps = false
            textSize = 14f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(onAccent)
            setPadding(dp(16), 0, dp(16), 0)
            elevation = 0f
            stateListAnimator = null
            val face = GradientDrawable().apply {
                setColor(accent)
                cornerRadius = dp(6).toFloat()
            }
            background = RippleDrawable(
                ColorStateList.valueOf((onAccent and 0x00ffffff) or 0x33000000),
                InsetDrawable(face, 0, dp(4), 0, dp(4)),
                null,
            )
            backgroundTintList = null
            setOnClickListener { finish() }
        })
        header.addView(TextView(this).apply {
            text = rawTitle.ifBlank { "Media preview" }.take(120)
            textSize = 24f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(ink)
            maxLines = 2
            setPadding(dp(8), 0, 0, 0)
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        root.addView(header, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ))

        playerArea = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }
        player = VideoView(this)
        status = TextView(this).apply {
            gravity = Gravity.CENTER
            textSize = 16f
            setTextColor(ink)
            setBackgroundColor(canvas)
            setPadding(dp(16), dp(16), dp(16), dp(16))
        }
        val audio = mimeType.startsWith("audio/")
        playerArea.addView(
            player,
            FrameLayout.LayoutParams(
                if (audio) 1 else ViewGroup.LayoutParams.MATCH_PARENT,
                if (audio) 1 else ViewGroup.LayoutParams.MATCH_PARENT,
                Gravity.CENTER,
            ),
        )
        statusContainer = ScrollView(this).apply {
            isFillViewport = true
            setBackgroundColor(canvas)
            addView(LinearLayout(this@MediaPreviewActivity).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                addView(status, LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply {
                    marginStart = dp(16)
                    marginEnd = dp(16)
                })
            })
        }
        playerArea.addView(statusContainer, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        ))
        root.addView(playerArea, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            0,
            1f,
        ))
        setContentView(root)

        controls = object : MediaController(this) {
            override fun show(timeout: Int) {
                super.show(timeout)
                setBackgroundColor(canvas)
                stylePlaybackControls(this, accent, ink, canvas)
            }
        }.apply { setAnchorView(playerArea) }
        player.setMediaController(controls)
        playerArea.setOnClickListener { if (prepared) controls.show(0) }
        status.setOnClickListener { if (prepared) controls.show(0) }
        statusContainer.setOnClickListener { if (prepared) controls.show(0) }
    }

    private fun stylePlaybackControls(view: View, accent: Int, ink: Int, canvas: Int) {
        when (view) {
            is LinearLayout, is FrameLayout -> view.setBackgroundColor(canvas)
            is SeekBar -> {
                view.progressTintList = ColorStateList.valueOf(accent)
                view.thumbTintList = ColorStateList.valueOf(accent)
            }
            is ImageButton -> view.imageTintList = ColorStateList.valueOf(accent)
            is TextView -> {
                view.setTextColor(ink)
                view.textSize = 13f
                view.typeface = Typeface.create("sans-serif", Typeface.NORMAL)
            }
        }
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) stylePlaybackControls(view.getChildAt(index), accent, ink, canvas)
        }
    }

    private fun prepareMedia() {
        val generation = ++preparationGeneration
        prepared = false
        controls.hide()
        status.setBackgroundColor(canvasColor)
        status.setCompoundDrawables(null, null, null, null)
        if (mimeType.startsWith("audio/")) {
            status.text = "Preparing audio..."
        } else {
            statusContainer.visibility = View.VISIBLE
            status.text = "Preparing video..."
        }
        player.visibility = View.VISIBLE
        player.setOnPreparedListener {
            if (!started || generation != preparationGeneration) {
                player.stopPlayback()
                return@setOnPreparedListener
            }
            prepared = true
            if (savedPosition > 0) player.seekTo(savedPosition)
            if (mimeType.startsWith("audio/")) {
                status.text = "Audio ready\nUse Play and the timeline below."
            } else {
                statusContainer.visibility = View.GONE
            }
            controls.setAnchorView(playerArea)
            controls.show(0)
        }
        player.setOnErrorListener { _, _, _ ->
            if (started && generation == preparationGeneration) {
                prepared = false
                showError()
            }
            true
        }
        player.setVideoPath(mediaFile.absolutePath)
        player.requestFocus()
    }

    private fun showError() {
        controls.hide()
        player.visibility = View.GONE
        statusContainer.visibility = View.VISIBLE
        val error = errorColor
        status.setTextColor(inkColor)
        status.background = GradientDrawable().apply {
            cornerRadius = dp(18).toFloat()
            setColor(ColorUtils.blendARGB(canvasColor, error, .09f))
            setStroke(dp(1), ColorUtils.blendARGB(canvasColor, error, .42f))
        }
        val icon = getDrawable(android.R.drawable.ic_dialog_alert)?.mutate()?.apply {
            setTint(error)
            setBounds(0, 0, dp(24), dp(24))
        }
        status.setCompoundDrawables(null, icon, null, null)
        status.compoundDrawablePadding = dp(12)
        status.text = "This media format could not be played here.\n\n" +
            "Return to Outputs to open it in another app or save/share it."
    }

    private fun resolveMediaFile(fileName: String?): File? {
        if (fileName == null || !SAFE_FILE_NAME.matches(fileName)) return null
        val directory = File(cacheDir, MEDIA_PREVIEW_CACHE_DIRECTORY)
        val file = File(directory, fileName)
        return file.takeIf {
            runCatching { it.parentFile?.canonicalFile == directory.canonicalFile }.getOrDefault(false)
        }
    }

    private fun isValidMedia(): Boolean =
        mimeType in supportedMediaPreviewTypes && mediaFile.isFile &&
            mediaFile.extension == extensionForMediaPreview(mimeType) &&
            mediaFile.length() in 1..MAX_MEDIA_BYTES

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        internal const val EXTRA_FILE_NAME = "media_file_name"
        internal const val EXTRA_TITLE = "media_title"
        internal const val EXTRA_MIME_TYPE = "media_mime_type"
        private const val STATE_POSITION = "media_position"
        private const val MAX_MEDIA_BYTES = 32L * 1024L * 1024L
        private val SAFE_FILE_NAME = Regex(
            "^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-" +
                "[0-9a-f]{12}\\.[a-z0-9]{2,5}$",
        )
    }
}
