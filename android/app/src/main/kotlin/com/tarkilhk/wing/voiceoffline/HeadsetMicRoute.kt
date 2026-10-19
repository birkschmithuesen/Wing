package com.tarkilhk.wing.voiceoffline

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * Microphone for explicit vad rounds (spec 2026-10-16 bt-headset-mic §4): the connected headset's mic if
 * there is one, otherwise the phone. Wing requests the communication route only while a round runs and
 * clears it on every exit. No audio mode change: BackgroundVoiceService treats MODE_IN_COMMUNICATION as
 * a call. Logs numbers, types and reasons only; never an address or a device name.
 *
 * Birk's E2 = 2 decision (t_4450aa3b, t_3954f61f): a hands-free/car-kit mic (class 0x0408/0x0420) counts
 * as a valid mic source alongside a wearable headset/headphones (0x0404/0x0418). There is no car-mode-only
 * phone-mic switch; the decision never looks at Wing car mode or Android car mode.
 */
class HeadsetMicRoute(private val activity: Activity) {
    companion object {
        const val PERMISSION_REQUEST = 7316
        const val TAG = "WingMic"
        private const val READY_TIMEOUT_MS = 2500L
        private const val ASKED_KEY = "bt_connect_asked"
        // Mirrors _headphoneClasses in lib/voice_offline/headphone_route.dart, widened for E2 = 2
        // (t_4450aa3b): hands-free/car-kit classes also count as a mic source.
        private val headsetClasses = setOf(0x0404, 0x0408, 0x0418, 0x0420)
        private val bluetoothOutputs = setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET,
        )
    }

    /** [link] is the communication sink to request; the phone mic when [headset] is false.
     *  [fallback] is true only when a manual preference could not be honored and this
     *  decision fell back to the automatic rule (spec 2026-10-18 manual mic). */
    class Decision(val headset: Boolean, val reason: String, val link: AudioDeviceInfo?, val fallback: Boolean = false)

    private val audio = activity.getSystemService(AudioManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val prefs = activity.getSharedPreferences("wing_voice_route", Context.MODE_PRIVATE)
    private val media = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()

    private var held: AudioDeviceInfo? = null
    private var heldAt = 0L
    private var ready = false
    private var onReady: ((AudioDeviceInfo?) -> Unit)? = null
    private var timeout: Runnable? = null
    private var watcher: Any? = null
    private var afterPermission: (() -> Unit)? = null

    fun bluetoothAllowed() = Build.VERSION.SDK_INT < 31 ||
        activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    /** [preference] is the saved [com.tarkilhk.wing.VadCapture.Options.mic] string: "auto" keeps this
     *  method's own BT-vs-phone rule unchanged; "phone" and "wired" never attempt the BT link; "bluetooth"
     *  takes the automatic rule's own BT branch and, if it found no headset mic, falls back to that same
     *  automatic result with [Decision.fallback] set so the caller can tell the user once. */
    fun decide(preference: String = "auto"): Decision {
        if (preference == "phone") {
            Log.i(TAG, "decide mic=phone reason=manualPhone")
            return Decision(false, "manualPhone", null)
        }
        if (preference == "wired") {
            // HeadsetMicRoute only ever drives the classic-SCO link (see the class doc): skipping it
            // entirely lets the default engine route a wired, USB or LE Audio mic by itself, or the
            // phone mic if none is plugged in - there is no separate wired detection to duplicate here.
            Log.i(TAG, "decide mic=phone reason=manualWired")
            return Decision(false, "manualWired", null)
        }
        val automatic = automaticDecision()
        if (preference == "bluetooth" && !automatic.headset) {
            Log.i(TAG, "decide mic=phone reason=${automatic.reason} fallback=1")
            return Decision(false, automatic.reason, null, fallback = true)
        }
        return automatic
    }

    private fun automaticDecision(): Decision {
        if (Build.VERSION.SDK_INT < 31) return Decision(false, "sdk", null)
        val output = if (Build.VERSION.SDK_INT >= 33) {
            try { audio.getAudioDevicesForAttributes(media).firstOrNull() } catch (_: Exception) { null }
        } else null
        // Classic SCO only: the default engine routes wired, USB and LE Audio mics by itself, but takes the SCO
        // mic only while the communication device is SCO (Engine::getDeviceForInputSource, spec §1).
        val links = audio.availableCommunicationDevices.filter { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
        val link = links.firstOrNull { output != null && it.address == output.address } ?: links.firstOrNull()
        val allowed = bluetoothAllowed()
        val deviceClass = link?.let { bluetoothClass(it) }
        val reason = when {
            link == null -> "noHeadsetMic"
            !allowed -> "noPermission"
            deviceClass == null -> "classUnknown"
            deviceClass !in headsetClasses -> "notHeadset"
            else -> "headset"
        }
        val headset = reason == "headset"
        val btClass = deviceClass?.let { "0x" + it.toString(16).padStart(4, '0') } ?: "none"
        Log.i(TAG, "decide mic=${if (headset) "headset" else "phone"} reason=$reason out=${output?.type ?: 0} " +
            "comm=${link?.type ?: "none"} btClass=$btClass perm=${if (allowed) 1 else 0}")
        return Decision(headset, reason, if (headset) link else null)
    }

    @SuppressLint("MissingPermission")
    private fun bluetoothClass(device: AudioDeviceInfo): Int? {
        if (!bluetoothAllowed()) return null
        return try {
            val adapter = activity.getSystemService(BluetoothManager::class.java)?.adapter ?: return null
            adapter.getRemoteDevice(device.address).bluetoothClass?.deviceClass
        } catch (_: Exception) { null }
    }

    fun acquire(decision: Decision, ready: (AudioDeviceInfo?) -> Unit) {
        release()
        val link = decision.link
        if (!decision.headset || link == null || Build.VERSION.SDK_INT < 31) { ready(null); return }
        heldAt = SystemClock.elapsedRealtime()
        onReady = ready
        val listener = AudioManager.OnCommunicationDeviceChangedListener { device -> changed(link, device) }
        audio.addOnCommunicationDeviceChangedListener(activity.mainExecutor, listener)
        watcher = listener
        val accepted = try { audio.setCommunicationDevice(link) } catch (_: Exception) { false }
        Log.i(TAG, "acquire result=$accepted")
        if (!accepted) {
            Log.i(TAG, "fallback reason=rejected")
            release()
            return
        }
        held = link
        timeout = Runnable { Log.i(TAG, "fallback reason=timeout"); release() }
            .also { handler.postDelayed(it, READY_TIMEOUT_MS) }
        if (audio.communicationDevice?.id == link.id) changed(link, link)
    }

    private fun changed(link: AudioDeviceInfo, device: AudioDeviceInfo?) {
        if (held?.id != link.id) return
        if (device?.id == link.id) {
            if (ready) return
            ready = true
            timeout?.let { handler.removeCallbacks(it) }
            timeout = null
            Log.i(TAG, "ready readyMs=${SystemClock.elapsedRealtime() - heldAt}")
            val callback = onReady
            onReady = null
            callback?.invoke(inputFor(link))
        } else if (ready) {
            Log.i(TAG, "lost")
        }
    }

    private fun inputFor(link: AudioDeviceInfo): AudioDeviceInfo? =
        audio.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .firstOrNull { it.type == link.type && it.address == link.address }

    /** Idempotent. A pending [acquire] answers null (phone mic). */
    fun release() {
        timeout?.let { handler.removeCallbacks(it) }
        timeout = null
        if (Build.VERSION.SDK_INT >= 31) {
            (watcher as? AudioManager.OnCommunicationDeviceChangedListener)
                ?.let { audio.removeOnCommunicationDeviceChangedListener(it) }
        }
        watcher = null
        val link = held
        held = null
        ready = false
        if (link != null && Build.VERSION.SDK_INT >= 31) {
            // Clears Wing's own request only; other apps' requests stay.
            try { audio.clearCommunicationDevice() } catch (_: Exception) {}
            Log.i(TAG, "release heldMs=${SystemClock.elapsedRealtime() - heldAt}")
        }
        val callback = onReady
        onReady = null
        callback?.invoke(null)
    }

    /** Spec §3 F1: ask once, in the foreground, while a Bluetooth audio device is connected. */
    fun needsPermission(): Boolean = Build.VERSION.SDK_INT >= 31 && afterPermission == null &&
        !bluetoothAllowed() && !prefs.getBoolean(ASKED_KEY, false) && activity.hasWindowFocus() &&
        audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in bluetoothOutputs }

    fun requestOnce(then: () -> Unit) {
        prefs.edit().putBoolean(ASKED_KEY, true).apply()
        afterPermission = then
        Log.i(TAG, "permission ask")
        activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), PERMISSION_REQUEST)
    }

    fun permissionResult(grants: IntArray) {
        val granted = grants.firstOrNull() == PackageManager.PERMISSION_GRANTED
        Log.i(TAG, "permission granted=${if (granted) 1 else 0}")
        val then = afterPermission
        afterPermission = null
        then?.invoke()
    }

    fun close() {
        afterPermission = null
        release()
    }
}
