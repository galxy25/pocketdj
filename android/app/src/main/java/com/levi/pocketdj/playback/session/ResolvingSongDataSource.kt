package com.levi.pocketdj.playback.session

import android.net.Uri
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.ResolvingDataSource
import com.levi.pocketdj.data.rips.RipJob
import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.playback.sequencer.RipOnDemandSource
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking

/** What a `POST /rip` turned into. */
sealed interface RipResolution {
    /** The finished mp3 (seekable, has a duration). */
    data class Durable(val url: String) : RipResolution

    /** An in-progress capture, playable now as live HLS (unseekable). [jobId] keeps the tracker polling. */
    data class Live(val url: String, val jobId: String?) : RipResolution
}

/**
 * Rip-on-demand for a row that has no rip yet (iOS `RipsStore.ensureURL`): `POST /rip`; already-ready ->
 * durable url; a live stream available -> [RipResolution.Live]; else poll until the durable mp3 lands.
 * Pure over its seams so the ordering is unit-testable without a server.
 */
class RipOnDemandResolver(
    private val requestRip: suspend (songId: String) -> RipJob,
    /** Polls the job to its durable url (suspends for as long as the rip takes; throws on a rip error). */
    private val awaitDurable: suspend (job: RipJob) -> String,
    /** Relative `/hls/<id>/index.m3u8` -> absolute playable url (server base + token). */
    private val liveUrl: suspend (streamPath: String) -> String,
    /** The server queued a playback rip (the session tracks it for the rip window). */
    private val onQueued: suspend (songId: String) -> Unit = {},
    private val log: (String) -> Unit = { NPLog.lane(NPLog.RIPREQ, it) },
) {
    suspend fun resolve(songId: String): RipResolution {
        log("rip-post begin song=$songId")
        val job = requestRip(songId)
        log("rip-post end song=$songId phase=${job.phase} live=${if (job.streamUrl != null) 1 else 0}")
        val ready = job.url
        if (job.isReady && ready != null) return RipResolution.Durable(ready)
        if (job.phase == RipJob.PHASE_ERROR) throw IOException(job.error ?: "Rip failed")
        if (job.jobId != null) onQueued(songId)
        job.streamUrl?.let { return RipResolution.Live(liveUrl(it), job.jobId) }
        if (job.jobId == null) throw IOException(job.error ?: "Rip did not start")
        return RipResolution.Durable(awaitDurable(job))
    }
}

/**
 * One in-flight resolution per song, shared by the player-side watcher (which swaps a [RipResolution.Live]
 * result in) and the data source (which reads a [RipResolution.Durable] one). Cancelled cleanly on skip.
 */
class RipOnDemandSession(
    private val scope: CoroutineScope,
    private val resolver: RipOnDemandResolver,
) {
    private val inflight = ConcurrentHashMap<String, Deferred<RipResolution>>()

    /** Start (or join) the resolution for [songId]; every other song's entry is dropped and cancelled. */
    fun begin(songId: String): Deferred<RipResolution> {
        for ((id, d) in inflight) if (id != songId) {
            inflight.remove(id, d)
            d.cancel()
        }
        return inflight.computeIfAbsent(songId) {
            val d = scope.async(start = CoroutineStart.LAZY) { resolver.resolve(songId) }
            d.invokeOnCompletion { t -> if (t != null) inflight.remove(songId, d) }
            d.start()
            d
        }
    }

    /** Join an EXISTING resolution (loader thread): never starts one, never cancels another song's. */
    fun join(songId: String): Deferred<RipResolution>? = inflight[songId]

    /** True while any resolution is still pending (the supervisor reads this as "a rip-wait is in flight"). */
    fun isResolving(): Boolean = inflight.values.any { it.isActive }

    /** Skip / stop: abandon [songId]'s resolution (null = all). The rip itself is the rip window's concern. */
    fun cancel(songId: String? = null) {
        if (songId == null) {
            for ((id, d) in inflight) { inflight.remove(id, d); d.cancel() }
        } else {
            inflight.remove(songId)?.cancel()
        }
    }

    /** Forget a finished resolution so a retry-in-place re-POSTs (fresh url). */
    fun forget(songId: String) {
        inflight.remove(songId)
    }

    /**
     * Blocking read for the loader thread. A Live result has no progressive bytes: the player-side watcher is
     * about to replace the item (which interrupts this thread); wait for that instead of failing the load.
     */
    fun blockingDurable(songId: String, liveWaitMs: Long = LIVE_WAIT_MS): String {
        val r = try {
            val d = join(songId) ?: throw IOException("rip resolve not in flight for $songId")
            runBlocking { d.await() }
        } catch (e: CancellationException) {
            throw IOException("rip resolve cancelled", e)
        }
        return when (r) {
            is RipResolution.Durable -> r.url
            is RipResolution.Live -> {
                try {
                    Thread.sleep(liveWaitMs)
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw IOException("superseded by the live stream", e)
                }
                throw IOException("live stream was not swapped in")
            }
        }
    }

    companion object {
        const val LIVE_WAIT_MS = 30_000L
    }
}

/** Service-side hook: the session is installed by the playback graph (same process as the service). */
object RipOnDemandBridge {
    @Volatile var session: RipOnDemandSession? = null
}

/**
 * Media3 resolver for `pdj-resolve://song/<id>`: swaps in the durable mp3 url at load time, on the loader
 * thread. Interruption (a skip replacing the item) cancels the wait. Any other uri passes through untouched.
 */
class ResolvingSongDataSource(
    private val sessionProvider: () -> RipOnDemandSession? = { RipOnDemandBridge.session },
) : ResolvingDataSource.Resolver {
    override fun resolveDataSpec(dataSpec: DataSpec): DataSpec {
        val songId = RipOnDemandSource.songIdFrom(dataSpec.uri.toString()) ?: return dataSpec
        val session = sessionProvider() ?: throw IOException("rip-on-demand is not available")
        val url = session.blockingDurable(songId)
        return dataSpec.withUri(Uri.parse(url))
    }

    override fun resolveReportedUri(uri: Uri): Uri = uri

    companion object {
        /** Wrap [upstream] so `pdj-resolve://` items load. */
        fun wrap(upstream: DataSource.Factory, resolver: ResolvingSongDataSource = ResolvingSongDataSource()): DataSource.Factory =
            ResolvingDataSource.Factory(upstream, resolver)

    }
}
