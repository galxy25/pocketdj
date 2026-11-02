package com.levi.pocketdj.data.profile

import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.store.StudioFileRef
import com.levi.pocketdj.studio.store.StudioLease
import com.levi.pocketdj.studio.store.StudioPlayable
import com.levi.pocketdj.studio.store.StudioStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch

/**
 * Q125 (iOS `PocketDJApp` Stage 5): every NEW sampler sample is auto-filed as a first-class item of the "Pocket DJ
 * Samples" profile album ([ProfileSourceStore.Kind.SAMPLE]; the album itself is synthesized, so it always exists).
 *
 * iOS parity, deliberately:
 * - NEW-only: driven by [StudioStore.onSampleAdded], which fires once per newly created sample id (never on an upsert /
 *   crash-retry re-file); no backfill of samples that existed before.
 * - The item is an INDEPENDENT byte-exact copy of the sample's playable audio (its fresh render, else the raw file):
 *   title = the sample name, length = `effectiveDurationMs` (null when 0), bpm = the beat-grid bpm, no key/camelot,
 *   artist = the profile name (derived). Renaming or deleting the Studio sample later does not touch it.
 * - Any container is accepted (Q116: non-mp3 originals play in Now Playing; only mp3 is offered to Mix decks).
 *
 * Android specifics: a SAF-stored sample is materialized to a local copy first (whose cache name ends `.audio`, so the
 * sample's REAL extension is passed through); one lease failure is retried once (the file may have just been moved to
 * its final folder); a duplicate announcement for the same sample id in this process files at most once.
 */
class SampleAlbumFiler(
    private val resolve: (String) -> StudioPlayable?,
    private val lease: suspend (StudioFileRef) -> StudioLease?,
    private val audio: () -> ProfileAudioStore,
    private val scope: CoroutineScope,
) {
    private val claimed = HashSet<String>()
    private val jobs = HashSet<Job>()

    /** The [StudioStore.onSampleAdded] hook: never blocks the caller (the copy runs on [scope]). */
    fun onSampleAdded(sample: StudioSample): Job {
        val job = scope.launch(Dispatchers.IO) { file(sample) }
        synchronized(jobs) { jobs += job }
        job.invokeOnCompletion { synchronized(jobs) { jobs -= job } }
        return job
    }

    /** Copy + file [sample] into the album. Null when nothing was filed (already claimed, gone, unreadable, copy failed). */
    suspend fun file(sample: StudioSample): ProfileSourceStore.SongEntry? {
        if (!synchronized(claimed) { claimed.add(sample.id) }) return null
        var filed: ProfileSourceStore.SongEntry? = null
        try {
            for (attempt in 0 until 2) {
                val p = resolve(sample.id) ?: break          // deleted / never had audio: nothing to file
                val l = try { lease(p.ref) } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
                    ?: continue
                try {
                    val ext = l.file.extension.takeIf { it.isNotEmpty() && it != "audio" }
                        ?: p.ref.file?.extension?.takeIf { it.isNotEmpty() }
                        ?: sample.fileName.substringAfterLast('.', "").ifEmpty { null }
                    val dur = p.lengthMs.takeIf { it > 0 } ?: sample.effectiveDurationMs.takeIf { it > 0 }
                    filed = audio().ingest(
                        kind = ProfileSourceStore.Kind.SAMPLE, title = p.title.ifBlank { sample.name }, original = l.file,
                        durationMs = dur?.toLong(), bpm = sample.grid?.bpm, ext = ext,
                    )
                } finally { l.release() }
                if (filed != null) break
            }
        } finally {
            // A failed attempt releases the claim so a later genuine re-announcement may still file it.
            if (filed == null) synchronized(claimed) { claimed.remove(sample.id) }
        }
        return filed
    }

    /** Suspends until every filing launched by [onSampleAdded] so far has finished (tests / orderly shutdown). */
    suspend fun awaitIdle() {
        while (true) {
            val snapshot = synchronized(jobs) { jobs.toList() }
            if (snapshot.isEmpty()) return
            snapshot.joinAll()
        }
    }

    companion object {
        /** Build the filer over [store] and install it as the store's new-sample hook (StudioGraph wiring). */
        fun attach(
            store: StudioStore,
            lease: suspend (StudioFileRef) -> StudioLease?,
            audio: () -> ProfileAudioStore,
            scope: CoroutineScope,
        ): SampleAlbumFiler = SampleAlbumFiler(store::localUrlForPlayback, lease, audio, scope)
            .also { f -> store.onSampleAdded = { s -> f.onSampleAdded(s) } }
    }
}
