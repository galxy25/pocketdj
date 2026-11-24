package com.levi.pocketdj.mix.nowplaying

import android.net.ConnectivityManager

/**
 * The network class the Now Playing prefetch plan sizes itself to (iOS `NowPlayingPrefetcher.Network`,
 * `NWPathMonitor`: satisfied / isConstrained / isExpensive).
 */
enum class NetworkClass {
    /** Wi-Fi / wired (NOT_METERED): the whole prefetch window. */
    UNMETERED,
    /** Cellular / metered: the NEXT track only (its song + all its stems). */
    EXPENSIVE,
    /** Data Saver on a metered path: the next track's song + ENABLED stems only. */
    CONSTRAINED,
    /** No path: nothing. */
    OFFLINE;

    /** Lower-case name used in the `prefetch order net=...` lane line (iOS rawValue). */
    val raw: String get() = name.lowercase()

    companion object {
        /**
         * PURE classification. [hasNetwork] = an active network exists; [metered] = it is NOT
         * `NET_CAPABILITY_NOT_METERED`; [dataSaver] = `restrictBackgroundStatus == ENABLED`. Data Saver
         * only throttles a metered path, so it constrains only there.
         */
        fun classify(hasNetwork: Boolean, metered: Boolean, dataSaver: Boolean): NetworkClass = when {
            !hasNetwork -> OFFLINE
            metered && dataSaver -> CONSTRAINED
            metered -> EXPENSIVE
            else -> UNMETERED
        }

        /** Read the live class off a [ConnectivityManager] (null manager = unknown = optimistic). */
        fun current(cm: ConnectivityManager?): NetworkClass {
            if (cm == null) return UNMETERED
            val has = runCatching { cm.activeNetwork != null }.getOrDefault(false)
            val metered = runCatching { cm.isActiveNetworkMetered }.getOrDefault(false)
            val saver = runCatching {
                cm.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
            }.getOrDefault(false)
            return classify(has, metered, saver)
        }
    }
}
