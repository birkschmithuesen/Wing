package com.tarkilhk.wing

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Network validation only triggers a retry; Dart verifies actual server access. */
class NetworkAvailabilityChannel(context: Context, messenger: BinaryMessenger) {
    private val manager = context.getSystemService(ConnectivityManager::class.java)
    private val channel = MethodChannel(messenger, "com.tarkilhk.wing/network")
    private val main = Handler(Looper.getMainLooper())
    private var validated: Network? = null
    private var closed = false
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            val available = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            if (validated != network || !available) {
                Log.i("WingConnection", "network.capabilities network=$network validated=$available " +
                    "wifi=${capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)} " +
                    "cellular=${capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)} " +
                    "vpn=${capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)}")
            }
            if (available && validated != network) {
                validated = network
                main.post { if (!closed) channel.invokeMethod("available", null) }
            } else if (!available && validated == network) {
                validated = null
            }
        }
        override fun onLost(network: Network) {
            Log.i("WingConnection", "network.lost network=$network previously_validated=${validated == network}")
            if (validated == network) {
                validated = null
                main.post { if (!closed) channel.invokeMethod("unavailable", null) }
            }
        }
    }
    init { manager.registerDefaultNetworkCallback(callback) }
    fun close() {
        closed = true
        manager.unregisterNetworkCallback(callback)
        main.removeCallbacksAndMessages(null)
    }
}
