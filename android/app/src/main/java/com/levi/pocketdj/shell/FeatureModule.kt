package com.levi.pocketdj.shell

import android.content.Intent
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.navigation.NavGraphBuilder
import com.levi.pocketdj.data.settings.AppSettings
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.CoroutineScope

/**
 * The extension point every area plugs into (decision D3). One sidecar graph per area
 * (`di/{Playback,Mix,Studio,Games,Collections,Browse,Services,Shell}Graph.kt`) implements
 * this; `AppGraph` lists the eight ONCE and consumers read the aggregated lists, so a
 * later package adds files and edits only its area's sidecar.
 *
 * Every member defaults to empty: an area contributes only what it has.
 */
interface FeatureModule {
    /** Stable area id (also the aggregation-order label). */
    val area: String

    val navEntries: List<NavEntry> get() = emptyList()
    val settingsSections: List<SettingsSection> get() = emptyList()
    val deepLinkHandlers: List<DeepLinkHandler> get() = emptyList()
    val flushables: List<Flushable> get() = emptyList()
    val resetHooks: List<ResetHook> get() = emptyList()
    val syncEntries: List<SyncEntry> get() = emptyList()
    val rowResolvers: List<RowResolver> get() = emptyList()
    val playOutcomeListeners: List<PlayOutcomeListener> get() = emptyList()
    val periodicWork: List<PeriodicWorkSpec> get() = emptyList()
}

/** Navigation actions handed to nav entries (keeps entries free of NavController). */
interface ShellNavActions {
    fun navigate(route: String)
    fun pop()
}

/** A pushed (non-tab) route an area contributes to the shell NavHost. [routeId] is unique. */
class NavEntry(
    val routeId: String,
    val register: NavGraphBuilder.(ShellNavActions) -> Unit,
)

/** What a section composable gets from the Settings screen. */
interface SettingsHost {
    val graph: AppGraph

    /** Latest persisted settings; null until the first emission. */
    val settings: AppSettings?
    val snackbar: SnackbarHostState
    val scope: CoroutineScope
    fun openStorage()
}

/**
 * A Settings block. [order] sorts the registry (ties keep registration order); [id] is
 * unique. Pre-existing blocks occupy 100..800 in steps of 100, leaving room between.
 */
class SettingsSection(
    val id: String,
    val order: Int,
    val content: @Composable ColumnScope.(SettingsHost) -> Unit,
)

/** Handles an incoming launch/new intent (deep link, file open). true ⇒ consumed. */
fun interface DeepLinkHandler {
    fun handle(intent: Intent): Boolean
}

/** Persists in-memory state when the app backgrounds (ON_STOP funnel). */
fun interface Flushable {
    suspend fun flush()
}

/** Wipes an area's state for "Reset everything". */
fun interface ResetHook {
    suspend fun reset()
}

/** A document the profile-sync engine unions across devices (file name = iOS name). */
data class SyncEntry(
    val key: String,
    val fileName: String,
    /** Called after a pull rewrote [fileName] on disk (iOS `register(..) { reloadFromDisk() }` clobber guard).
     * Return `true` when the reload merged and re-saved the file (the store's `reloadFromDisk(): Boolean`). */
    val onPulled: (() -> Any?)? = null,
    /**
     * OPTIONAL write seam for the pulled bytes, for a store whose own writer runs off-thread (so the
     * pull is ordered against queued stragglers). MUST write the payload to the file synchronously.
     */
    val applyPayload: ((ByteArray) -> Unit)? = null,
)

/** Resolves an item id with a given prefix (e.g. `amrec_`, `perf:`) to a displayable row. */
class RowResolver(val prefix: String, val resolve: (String) -> Any?)

/** Observes how a play ended (skip tracker, history, pocket game). PB-5 supplies the producer. */
fun interface PlayOutcomeListener {
    fun onOutcome(songId: String, wasSkipped: Boolean, listenedFraction: Double)
}

/** A WorkManager periodic job request. */
data class PeriodicWorkSpec(
    val id: String,
    val repeatMinutes: Long,
    val requiresNetwork: Boolean = false,
)

/**
 * Aggregated view over [modules], in the order given (the AppGraph passes area order).
 * Duplicate nav route ids, settings section ids, sync keys and work ids fail fast at
 * construction — a collision between two packages is a build-time bug, not a silent
 * last-writer-wins.
 */
class FeatureModuleRegistry(val modules: List<FeatureModule>) {
    val navEntries: List<NavEntry> = modules.flatMap { it.navEntries }
        .also { requireUnique("nav route", it.map(NavEntry::routeId)) }

    val settingsSections: List<SettingsSection> = modules.flatMap { it.settingsSections }
        .also { requireUnique("settings section", it.map(SettingsSection::id)) }

    val deepLinkHandlers: List<DeepLinkHandler> = modules.flatMap { it.deepLinkHandlers }
    val flushables: List<Flushable> = modules.flatMap { it.flushables }
    val resetHooks: List<ResetHook> = modules.flatMap { it.resetHooks }

    val syncEntries: List<SyncEntry> = modules.flatMap { it.syncEntries }
        .also { requireUnique("sync key", it.map(SyncEntry::key)) }

    val rowResolvers: List<RowResolver> = modules.flatMap { it.rowResolvers }
    val playOutcomeListeners: List<PlayOutcomeListener> = modules.flatMap { it.playOutcomeListeners }

    val periodicWork: List<PeriodicWorkSpec> = modules.flatMap { it.periodicWork }
        .also { requireUnique("periodic work id", it.map(PeriodicWorkSpec::id)) }

    /** First resolver whose prefix matches [itemId], resolved; null if none/unresolved. */
    fun resolveRow(itemId: String): Any? =
        rowResolvers.firstOrNull { itemId.startsWith(it.prefix) }?.resolve?.invoke(itemId)

    suspend fun flushAll() {
        flushables.forEach { runCatching { it.flush() } }
    }

    suspend fun resetAll() {
        resetHooks.forEach { runCatching { it.reset() } }
    }

    private fun requireUnique(what: String, ids: List<String>) {
        val dup = ids.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        require(dup.isEmpty()) { "Duplicate $what id(s): ${dup.joinToString()}" }
    }
}
