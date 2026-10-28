package com.levi.pocketdj.shell

import android.content.Intent
import android.provider.OpenableColumns
import kotlinx.coroutines.CoroutineScope
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
 *  - [joinJukebox]: JBX-2 `JoinedSessionsStore.addJoined` + open the join panel — default posts
 *    [ShellRoute.JukeboxJoin] (resolves only for already-joined sessions).
 *  - [importCollection]: SET-2/COL-15 collection import — default "Import coming soon".
 *  - [mwf]: Games MwF consumer — default parks the link in [DeepLinkDispatcher.pendingMwf].
 */
class DeepLinkSeams {
    @Volatile var playItem: ((PlayKind, String, Boolean) -> String?)? = null
    @Volatile var joinJukebox: ((id: String, guestBase: String?) -> Unit)? = null
    @Volatile var importCollection: ((uri: String) -> Unit)? = null
    @Volatile var mwf: ((DeepLink.Mwf) -> Unit)? = null
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
) {
    private val _pendingMwf = MutableStateFlow<DeepLink.Mwf?>(null)

    /** An MwF link nobody has consumed yet (Games area takes it with [takePendingMwf]). */
    val pendingMwf: StateFlow<DeepLink.Mwf?> = _pendingMwf

    fun takePendingMwf(): DeepLink.Mwf? = _pendingMwf.getAndUpdate { null }

    /** The [DeepLinkHandler] registered through `FeatureModule.deepLinkHandlers`. */
    val intentHandler = DeepLinkHandler { intent -> handle(intent) }

    fun handle(intent: Intent): Boolean {
        if (intent.action != Intent.ACTION_VIEW) return false
        val data = intent.data?.toString() ?: return false
        val name = if (intent.data?.scheme == "content") displayName(intent) else null
        return handle(DeepLinkParser.parse(data, name, intent.type))
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
                if (join != null) join(link.id, link.guestBase) else postRoute(ShellRoute.JukeboxJoin(link.id))
            }
            is DeepLink.Mwf -> {
                val consumer = seams.mwf
                if (consumer != null) consumer(link) else _pendingMwf.value = link
            }
            is DeepLink.Play -> {
                val play = seams.playItem
                if (play != null) {
                    play(link.kind, link.id, link.shuffle)?.let(postMessage)
                } else {
                    postRoute(
                        when (link.kind) {
                            PlayKind.Playlist -> ShellRoute.Playlist(link.id)
                            PlayKind.Pocket -> ShellRoute.Pocket(link.id)
                            PlayKind.Setlist -> ShellRoute.Setlist(link.id, autoplay = true)
                            PlayKind.Album -> ShellRoute.Album(link.id)
                        },
                    )
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
