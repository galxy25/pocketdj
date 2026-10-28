package com.levi.pocketdj.mix.stream

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities

/**
 * "Does the device have a usable network path?" - the Android stand-in for iOS `NWPathMonitor`.
 * [MixStreamLoader.canStream] is false while this reports false so an offline mix runs on what is
 * on disk. Seeded from the active network at construction.
 */
interface NetworkMonitor {
    val available: Boolean
}

/** Fixed/test monitor and the state holder behind [ConnectivityNetworkMonitor]. */
class SettableNetworkMonitor(initial: Boolean = true) : NetworkMonitor {
    @Volatile override var available: Boolean = initial
}

/**
 * Pure tracker of the CURRENT default network (no set: a stale entry for a replaced network could
 * pin `available` true). [onAvailable]/[onCapabilities] adopt the network the system reports as
 * default; [onLost] clears only when it names the tracked network.
 */
class DefaultNetworkTracker<N : Any>(initial: N? = null, initialHasInternet: Boolean = false) {
    private var current: N? = if (initialHasInternet) initial else null
    @Volatile var available: Boolean = initialHasInternet && initial != null
        private set

    @Synchronized fun onCapabilities(network: N, hasInternet: Boolean) {
        if (hasInternet) { current = network; available = true }
        else if (current == network) { current = null; available = false }
    }

    @Synchronized fun onLost(network: N) {
        if (current == network) { current = null; available = false }
    }
}

/**
 * [ConnectivityManager] default-network callback. Seeded from the active network at construction
 * (the callback delivers nothing when launched offline), then follows the default network.
 */
class ConnectivityNetworkMonitor(context: Context) : NetworkMonitor {
    private val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    private val tracker: DefaultNetworkTracker<Network>

    private val unknown = cm == null
    override val available: Boolean get() = unknown || tracker.available

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            tracker.onCapabilities(network, caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET))
        }

        override fun onLost(network: Network) = tracker.onLost(network)
    }

    init {
        val active = runCatching { cm?.activeNetwork }.getOrNull()
        val hasInternet = active != null && runCatching {
            cm?.getNetworkCapabilities(active)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        }.getOrDefault(false)
        // Without a readable ConnectivityManager the answer is unknown: stay optimistic (a missing
        // signal must never block streaming); with one, offline at launch reads as offline.
        tracker = DefaultNetworkTracker(active, hasInternet)
        runCatching { cm?.registerDefaultNetworkCallback(callback) }
    }

    fun close() {
        runCatching { cm?.unregisterNetworkCallback(callback) }
    }
}
