package com.tarkilhk.wing.voiceoffline

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.UiModeManager
import android.bluetooth.BluetoothManager
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Where read-aloud plays (spec 2026-10-14 barge-in §3.4.1). Returns raw facts only; Dart decides what
 * counts as headphones. The attributes match VoicePlayback (USAGE_MEDIA, CONTENT_TYPE_SPEECH). Never
 * returns or logs a Bluetooth address or device name.
 */
class HeadphoneRouteChannel(private val activity: Activity, messenger: BinaryMessenger) {
    companion object { const val PERMISSION_REQUEST = 7315 }
    private val channel = MethodChannel(messenger, "com.tarkilhk.wing/headphone_route")
    private val audio = activity.getSystemService(AudioManager::class.java)
    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private var pending: MethodChannel.Result? = null
    private val devices = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) { changed() }
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) { changed() }
    }

    init {
        channel.setMethodCallHandler(::handle)
        audio.registerAudioDeviceCallback(devices, Handler(Looper.getMainLooper()))
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "current" -> result.success(current())
            "bluetoothAllowed" -> result.success(bluetoothAllowed())
            "requestBluetooth" -> requestBluetooth(result)
            else -> result.notImplemented()
        }
    }

    private fun changed() { channel.invokeMethod("changed", current()) }

    private fun current(): Map<String, Any?> {
        val unsupported = mapOf<String, Any?>("supported" to false, "type" to 0)
        if (Build.VERSION.SDK_INT < 33) return unsupported
        val device = try { audio.getAudioDevicesForAttributes(attributes).firstOrNull() } catch (_: Exception) { null }
            ?: return unsupported
        val ui = activity.getSystemService(UiModeManager::class.java)
        return mapOf(
            "supported" to true,
            "type" to device.type,
            "bluetoothClass" to bluetoothClass(device),
            "androidCarMode" to (ui?.currentModeType == Configuration.UI_MODE_TYPE_CAR),
        )
    }

    private fun bluetoothAllowed() = Build.VERSION.SDK_INT < 31 ||
        activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    /** Null unless the device is a Bluetooth sink whose class Android lets Wing read. */
    @SuppressLint("MissingPermission")
    private fun bluetoothClass(device: AudioDeviceInfo): Int? {
        if (device.type != AudioDeviceInfo.TYPE_BLUETOOTH_A2DP && device.type != AudioDeviceInfo.TYPE_BLE_HEADSET) return null
        if (!bluetoothAllowed()) return null
        return try {
            val adapter = activity.getSystemService(BluetoothManager::class.java)?.adapter ?: return null
            adapter.getRemoteDevice(device.address).bluetoothClass?.deviceClass
        } catch (_: Exception) { null }
    }

    private fun requestBluetooth(result: MethodChannel.Result) {
        if (bluetoothAllowed()) return result.success(true)
        if (pending != null) return result.success(false)
        pending = result
        activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), PERMISSION_REQUEST)
    }

    fun permissionResult(grants: IntArray) {
        pending?.success(grants.firstOrNull() == PackageManager.PERMISSION_GRANTED); pending = null
        changed()
    }

    fun close() {
        audio.unregisterAudioDeviceCallback(devices)
        pending?.success(false); pending = null
        channel.setMethodCallHandler(null)
    }
}
