package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.playback.PlaybackMode
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.coroutines.cancellation.CancellationException

/**
 * Aggregates the per-row [RowSourceResolver]s and walks them in [Rung] order (ties keep
 * registration order). Packages register their rung from their own sidecar graph: burned-first
 * (SVC-4), studio-local (STU-7), Apple Music (PB-8), cloud / rip-on-demand (PB-3). The default
 * ladder is local-file seam -> manifest.
 *
 * Device mode consults ONLY the local rungs (`LOCAL_FILE`, `STUDIO_LOCAL`): a row with no on-device
 * file is [UnplayableSource.Reason.NOT_ON_DEVICE].
 *
 * Deliberately NO 30 s preview rung: inside a run a preview would advance the set every 30 s.
 */
class RowResolverRegistry(
    initial: List<RowSourceResolver> = emptyList(),
    /** True when a manifest rip exists for the id (the `ripStartsNow` input). */
    private val manifestHit: (String) -> Boolean = { false },
    private val ripServerConfigured: () -> Boolean = { false },
    /** P2-MM-9: Mix Mode is buffering (the coordinator's `buffering`). */
    private val preferLocalAudio: () -> Boolean = { false },
    /** P2-MM-9: the row is Apple-Music-sourced (it has an Apple Music identity). */
    private val isAppleMusicSourced: (QueueItem) -> Boolean = { false },
    /** P2-MM-9: the row's rip would start INSTANTLY (complete local copy / cached presign / public url). */
    private val localCopyInstant: suspend (QueueItem) -> Boolean = { false },
) {
    private val resolvers = CopyOnWriteArrayList<RowSourceResolver>()

    init {
        initial.forEach(::register)
    }

    fun register(resolver: RowSourceResolver) {
        require(resolvers.none { it.id == resolver.id }) { "Duplicate row resolver id ${resolver.id}" }
        resolvers.add(resolver)
    }

    /** The ladder in the order it is walked. */
    fun ladder(): List<RowSourceResolver> = resolvers.sortedBy { it.rung.order }

    /** [ladder], with the Apple Music rung moved to the front when [PreferLocalAudio] says so (every other rung keeps its order). */
    fun ladderFor(appleMusicFirst: Boolean): List<RowSourceResolver> {
        val l = ladder()
        if (!appleMusicFirst) return l
        val (am, rest) = l.partition { it.rung == Rung.APPLE_MUSIC }
        return am + rest
    }

    /** The backend each row was last resolved to (resolveId -> backend): a re-resolve of a rip that did not sound walks Apple Music next. */
    private val lastBackend = java.util.concurrent.ConcurrentHashMap<String, String>()

    /**
     * [reResolve] = the supervisor's retry of a row that was already resolved. For an Apple-Music-sourced row whose last pick
     * was the rip (expired presign / 403 / stall), the retry walks the Apple Music rung FIRST: the rip-first ladder's real fallback.
     */
    suspend fun resolve(item: QueueItem, mode: PlaybackMode, reResolve: Boolean = false): RowSource {
        val ripStartsNow = manifestHit(item.resolveId)
        val prefer = preferLocalAudio()
        val sourced = prefer && ripStartsNow && isAppleMusicSourced(item)
        val instant = if (sourced) localCopyInstant(item) else false
        val ripFailedOnce = reResolve && sourced && lastBackend[item.resolveId] == "rip"
        val amFirst = ripFailedOnce || PreferLocalAudio.appleMusicFirst(
            PreferLocalAudio.Facts(preferLocalAudio = prefer, appleMusicSourced = sourced, ripped = ripStartsNow, localCopyInstant = instant),
        )
        val ctx = ResolveContext(
            mode = mode,
            ripServerConfigured = ripServerConfigured(),
            ripStartsNow = ripStartsNow,
            preferLocalAudio = prefer,
            localCopyInstant = instant && !ripFailedOnce, // a rip that did not sound is no longer 'instant'
            appleMusicFirst = amFirst,
        )
        for (r in ladderFor(amFirst)) {
            if (mode == PlaybackMode.DEVICE && r.rung != Rung.LOCAL_FILE && r.rung != Rung.STUDIO_LOCAL) continue
            val hit = try {
                r.resolve(item, ctx)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null // a broken rung passes the row down the ladder, never crashes the set
            }
            if (hit != null) { lastBackend[item.resolveId] = hit.backend; return hit }
        }
        return UnplayableSource(
            if (mode == PlaybackMode.DEVICE) UnplayableSource.Reason.NOT_ON_DEVICE
            else UnplayableSource.Reason.METADATA_ONLY,
        )
    }
}

/**
 * P2-MM-9 `preferLocalAudio` (iOS `PlaybackCoordinator.providers(for:preferLocalAudio:)` / `streamsAppleMusicFirst`).
 *
 * Mix Mode buffering makes a RIPPED Apple-Music-sourced row prefer its local rip, because only a local file can be
 * mixed. The one rule that bounds it is the dead-air rule: an instant Apple Music start is never traded for a slow
 * presign. So the rip goes first only when its copy is INSTANT (a complete local file - the LOCAL_FILE rung already
 * wins - or a cached presign / a url that needs none); otherwise Apple Music starts the row and the first control
 * touch hands it off to the local copy ([com.levi.pocketdj.playback.npmix.AppleMusicHandOff]).
 *
 * Off (Mix Mode off / suspended / not Apple-Music-sourced / not ripped) the ladder is exactly the old one.
 */
object PreferLocalAudio {
    data class Facts(
        val preferLocalAudio: Boolean,
        val appleMusicSourced: Boolean,
        /** A manifest rip exists for the row. */
        val ripped: Boolean,
        /** That rip would start instantly. */
        val localCopyInstant: Boolean,
    )

    /** Should the Apple Music rung be walked BEFORE the rip rungs? */
    fun appleMusicFirst(f: Facts): Boolean =
        f.preferLocalAudio && f.appleMusicSourced && f.ripped && !f.localCopyInstant
}
