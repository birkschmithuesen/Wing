package com.tarkilhk.wing.porterwake

import android.app.Activity
import android.app.KeyguardManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import com.tarkilhk.wing.MainActivity
import org.json.JSONObject

/** Handles porter notification taps; rate/snooze never open the app. */
class PorterActionActivity : Activity() {
    private var sent = false
    private var resumed = false

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        if (Build.VERSION.SDK_INT >= 27) setShowWhenLocked(true)
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (keyguard.isKeyguardLocked && Build.VERSION.SDK_INT >= 26) {
            keyguard.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() { deliver() }
                override fun onDismissCancelled() { finish() }
                override fun onDismissError() { finish() }
            })
        } else if (keyguard.isKeyguardLocked) openMain()
    }

    override fun onResume() { super.onResume(); resumed = true; deliver() }
    override fun onPause() { resumed = false; super.onPause() }

    private fun deliver() {
        if (!resumed || sent || getSystemService(KeyguardManager::class.java).isKeyguardLocked) return
        sent = true
        val raw = intent.getStringExtra(PorterWakeNative.extra) ?: return finish()
        val value = JSONObject(raw)
        if (value.optString("action") == "open") return openMain()
        val event = PorterWakeNative.asMap(value)
        // Stay resumed until Dart replied: a resumed activity keeps network access.
        PorterWakeNative.interact(this, event) { runOnUiThread { finish() } }
    }

    private fun openMain() {
        startActivity(Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(PorterWakeNative.extra, intent.getStringExtra(PorterWakeNative.extra)))
        finish()
    }
}
