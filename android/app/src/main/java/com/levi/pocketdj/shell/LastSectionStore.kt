package com.levi.pocketdj.shell

import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.LegacyPrefKeys
import com.levi.pocketdj.data.settings.PrefKey
import com.levi.pocketdj.navigation.PocketDjDestination
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Last-visited section persistence (iOS `settings.lastSection`). Restores on cold launch;
 * nothing valid persisted ⇒ History.
 *
 * The retired "Remote" section token (iOS 1.0.5 merged Remote into the Jukebox panel) restores to the Jukebox tab AND
 * flips the panel to its Remote half, like the iOS deep entries do.
 */
class LastSectionStore(private val settings: AppSettingsStore) {
    suspend fun restore(): PocketDjDestination {
        val token = settings.get(LegacyPrefKeys.LAST_SECTION)
        if (PocketDjDestination.isRetiredRemoteToken(token)) {
            runCatching { settings.set(JukeboxPanelModeStore.KEY, JukeboxPanelMode.REMOTE.raw) }
        }
        return PocketDjDestination.fromToken(token)
    }

    suspend fun save(destination: PocketDjDestination) {
        settings.set(LegacyPrefKeys.LAST_SECTION, destination.token)
    }
}

/** The Jukebox panel's two halves (iOS `JukeboxPanelMode`). Raw values are persisted and PINNED. */
enum class JukeboxPanelMode(val raw: String, val label: String) {
    HERO("Jukebox Hero", "Jukebox Hero"),
    REMOTE("Remote", "Remote");

    companion object {
        /** Unknown / blank ⇒ Hero (iOS `JukeboxPanelMode(rawValue:) ?? .hero`). */
        fun fromRaw(raw: String?): JukeboxPanelMode = entries.firstOrNull { it.raw == raw } ?: HERO
    }
}

/** Persistence + the pure transitions of the panel mode. */
object JukeboxPanelModeStore {
    /** iOS `JukeboxPanelMode.storageKey`. */
    val KEY = PrefKey.string("jukeboxPanelMode", JukeboxPanelMode.HERO.raw)

    /** The mode the panel actually shows: Remote only while the Remote surface is available. */
    fun effective(stored: JukeboxPanelMode, remoteAvailable: Boolean): JukeboxPanelMode =
        if (remoteAvailable) stored else JukeboxPanelMode.HERO

    /** A session going active flips the panel to Remote; going inactive leaves the choice alone. */
    fun afterSessionChange(current: JukeboxPanelMode, active: Boolean): JukeboxPanelMode =
        if (active) JukeboxPanelMode.REMOTE else current
}

/** A request, from outside the UI tree, to show the Jukebox panel's Remote half. */
data class RemotePanelRequest(val seq: Long, val joinCode: String? = null, val showcase: Boolean = false)

/**
 * `pocketdj://remote[/join/<code>]` and the debug showcase seed park a request here; the Jukebox hub consumes it
 * (it may not be composed yet on a cold start, so the request must outlive the tap).
 */
object RemotePanelRequests {
    private var seq = 0L
    private val _pending = MutableStateFlow<RemotePanelRequest?>(null)
    val pending: StateFlow<RemotePanelRequest?> = _pending.asStateFlow()

    @Synchronized fun request(joinCode: String? = null, showcase: Boolean = false) {
        _pending.value = RemotePanelRequest(++seq, joinCode, showcase)
    }

    /** Clears the request iff it is still [req] (a newer one stays parked). */
    fun consume(req: RemotePanelRequest) { _pending.compareAndSet(req, null) }
}
