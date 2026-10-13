package com.tarkilhk.wing

import android.app.Activity
import android.content.Intent
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.view.KeyEvent

/** Steering-wheel / headset play-pause as a talk button on the vad route.
 *  The MediaSession exists only while Dart enabled it and the activity is resumed;
 *  otherwise it is released so music apps receive the keys again. */
class VoiceMediaKeys(private val activity: Activity, private val emit: (Map<String, Any>) -> Unit) {
    private val keys = setOf(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY,
        KeyEvent.KEYCODE_MEDIA_PAUSE, KeyEvent.KEYCODE_HEADSETHOOK)
    private var enabled = false
    private var resumed = true
    private var session: MediaSession? = null

    private fun create(): MediaSession = MediaSession(activity, "WingVoice").apply {
        setCallback(object : MediaSession.Callback() {
            override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                val key = if (Build.VERSION.SDK_INT >= 33) mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
                    else @Suppress("DEPRECATION") mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                if (key == null || key.keyCode !in keys) return super.onMediaButtonEvent(mediaButtonIntent)
                if (key.action == KeyEvent.ACTION_DOWN && key.repeatCount == 0) emit(mapOf("mediaKey" to "playPause"))
                return true
            }
        })
        setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE)
            .setState(PlaybackState.STATE_PAUSED, 0, 1f).build())
    }

    fun enable(on: Boolean) { enabled = on; sync() }
    fun resume() { resumed = true; sync() }
    fun pause() { resumed = false; sync() }
    private fun sync() {
        if (enabled && resumed) {
            val current = session ?: create().also { session = it }
            current.isActive = true
        } else release()
    }
    private fun release() {
        val current = session ?: return
        session = null
        current.isActive = false
        current.release()
    }
    fun close() { enabled = false; release() }
}
