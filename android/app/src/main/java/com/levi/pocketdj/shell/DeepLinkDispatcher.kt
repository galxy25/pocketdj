package com.levi.pocketdj.shell

import android.content.Intent
import android.provider.OpenableColumns
import com.levi.pocketdj.navigation.PocketDjDestination
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.getAndUpdate
import kotlinx.coroutines.launch

/** What the dispatcher needs from onboarding (SURF-3 `OnboardingStore` implements it via the graph). */
interface OnboardingGate {
    val isComplete: Boolean
    suspend fun waitUntilComplete()
}

/**
 * Replaceable seams for the features that arrive in later packages. Each default is a safe,
 * visible fallback (never a crash, never a silent drop):
 *  - [playItem]: SURF-5 `ShellActions.playPlaylist/...` — default opens the item's screen
 *    (the resolver reports the iOS-style message for an unknown id). Returns a failure message or null.
 *  - [joinJukebox]: JBX-2 `JoinedSessionsStore.addJoined` + open the join panel — default opens the Jukebox tab with a
 *    "coming soon" message (JBX-2 must assign this seam).
 *  - [importCollection]: SET-2/COL-15 collection import — default "Import coming soon".
 *  - [mwf]: Games MwF consumer — default parks the link in [DeepLinkDispatcher.pendingMwf].
 *  - [game]: Games puzzle / In the Pocket opener — default parks in [DeepLinkDispatcher.pendingGame]
 *    and lands on the Games tab.
 */
class DeepLinkSeams {
    @Volatile var playItem: ((PlayKind, String, Boolean) -> String?)? = null
    @Volatile var joinJukebox: ((id: String, guestBase: String?) -> Unit)? = null
    @Volatile var importCollection: ((uri: String) -> Unit)? = null
    @Volatile var mwf: ((DeepLink.Mwf) -> Unit)? = null
    @Volatile var game: ((GameLink) -> Unit)? = null
}

/**
 * Routes a [DeepLink]. Everything except a diag key is parked in [PendingOpenStore] until
 * onboarding completes, then drained exactly once (iOS `onChange(of: onboarding.isComplete)`).
 */
class DeepLinkDispatcher(
    private val scope: CoroutineScope,
    private val gate: OnboardingGate,
    private val seams: DeepLinkSeams = DeepLinkSeams(),
    private val pending: PendingOpenStore = PendingOpenStore(),
    private val postRoute: (ShellRoute) -> Unit = NavRequestBus::post,
    private val postMessage: (String) -> Unit = NavRequestBus::postMessage,
    private val displayName: (Intent) -> String? = { null },
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val _pendingMwf = MutableStateFlow<DeepLink.Mwf?>(null)

    /** An MwF link nobody has consumed yet (Games area takes it with [takePendingMwf]). */
    val pendingMwf: StateFlow<DeepLink.Mwf?> = _pendingMwf

    fun takePendingMwf(): DeepLink.Mwf? = _pendingMwf.getAndUpdate { null }

    private val _pendingGame = MutableStateFlow<GameLink?>(null)

    /** A game-open link nobody has consumed yet (Games area takes it with [takePendingGame]). */
    val pendingGame: StateFlow<GameLink?> = _pendingGame

    fun takePendingGame(): GameLink? = _pendingGame.getAndUpdate { null }

    /** The [DeepLinkHandler] registered through `FeatureModule.deepLinkHandlers`. */
    val intentHandler = DeepLinkHandler { intent -> handle(intent) }

    fun handle(intent: Intent): Boolean {
        if (intent.action != Intent.ACTION_VIEW) return false
        val data = intent.data?.toString() ?: return false
        if (intent.data?.scheme == "content") {
            // The DISPLAY_NAME query can block on a remote provider: never on the main thread.
            val type = intent.type
            scope.launch {
                val name = withContext(ioDispatcher) { displayName(intent) }
                handle(DeepLinkParser.parse(data, name, type))
            }
            return true
        }
        return handle(DeepLinkParser.parse(data, null, intent.type))
    }

    /** @return true if the link is ours (executed or parked); false for None / diag keys. */
    fun handle(link: DeepLink): Boolean {
        if (link is DeepLink.None || link is DeepLink.DiagKey) return false
        if (gate.isComplete) {
            execute(link)
        } else {
            pending.park(link)
            // One waiter per park is fine: drain() is atomic, so a link runs once.
            scope.launch {
                gate.waitUntilComplete()
                pending.drain().forEach(::execute)
            }
        }
        return true
    }

    private fun execute(link: DeepLink) {
        when (link) {
            is DeepLink.JukeboxJoin -> {
                val join = seams.joinJukebox
                if (join != null) {
                    join(link.id, link.guestBase)
                } else {
                    // JBX-2 not landed: land on the tab with an honest message, not a join-list error.
                    postRoute(ShellRoute.Tab(PocketDjDestination.Jukebox))
                    postMessage("Joining jukeboxes is coming soon")
                }
            }
            is DeepLink.Mwf -> {
                val consumer = seams.mwf
                if (consumer != null) consumer(link) else _pendingMwf.value = link
            }
            is DeepLink.Game -> {
                val opener = seams.game
                if (opener != null) opener(link.kind) else {
                    _pendingGame.value = link.kind
                    postRoute(ShellRoute.Tab(PocketDjDestination.Games))
                }
            }
            is DeepLink.Play -> {
                val play = seams.playItem
                if (play != null) {
                    play(link.kind, link.id, link.shuffle)?.let(postMessage)
                } else {
                    // SURF-5 not landed: open the screen (setlist autoplays); say playback isn't wired.
                    postRoute(
                        when (link.kind) {
                            PlayKind.Playlist -> ShellRoute.Playlist(link.id)
                            PlayKind.Pocket -> ShellRoute.Pocket(link.id)
                            PlayKind.Setlist -> ShellRoute.Setlist(link.id, autoplay = true)
                            PlayKind.Album -> ShellRoute.Album(link.id)
                        },
                    )
                    if (link.kind != PlayKind.Setlist) postMessage("Playing from links is coming soon")
                }
            }
            is DeepLink.Navigate -> postRoute(link.route)
            is DeepLink.CollectionFile -> {
                val import = seams.importCollection
                if (import != null) import(link.uri) else postMessage("Import coming soon")
            }
            is DeepLink.DiagKey, DeepLink.None -> Unit
        }
    }

    companion object {
        /** Reads DISPLAY_NAME for an opaque content:// URI (Files/Downloads hand out no filename). */
        fun contentDisplayName(resolver: android.content.ContentResolver): (Intent) -> String? = { intent ->
            val uri = intent.data
            if (uri == null) null else runCatching {
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) it.getString(0) else null
                }
            }.getOrNull()
        }
    }
}
