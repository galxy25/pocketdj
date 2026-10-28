package com.levi.pocketdj.mix.stream

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities

/**
 * "Does the device have a usable network path?" - the Android stand-in for iOS `NWPathMonitor`.
 * [MixStreamLoader.canStream] is false while this reports false so an offline mix runs on what is
 * on disk. Optimistic until the first update (a missing signal must never block streaming).
 */
interface NetworkMonitor {
    val available: Boolean
}

/** Fixed/test monitor and the state holder behind [ConnectivityNetworkMonitor]. */
class SettableNetworkMonitor(initial: Boolean = true) : NetworkMonitor {
    @Volatile override var available: Boolean = initial
}

/**
 * [ConnectivityManager] default-network callback. Tracks the set of live networks that advertise
 * INTERNET, so a Wi-Fi to cellular handover (lost + available in either order) never reads as offline.
 */
class ConnectivityNetworkMonitor(context: Context) : NetworkMonitor {
    private val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    private val live = HashSet<Network>()

    @Volatile override var available: Boolean = true
        private set

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            synchronized(live) {
                if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) live += network else live -= network
                available = live.isNotEmpty()
            }
        }

        override fun onLost(network: Network) {
            synchronized(live) { live -= network; available = live.isNotEmpty() }
        }
    }

    init {
        // Never throws into the app: a denied/unsupported registration leaves the optimistic default.
        runCatching { cm?.registerDefaultNetworkCallback(callback) }
    }

    fun close() {
        runCatching { cm?.unregisterNetworkCallback(callback) }
    }
}
