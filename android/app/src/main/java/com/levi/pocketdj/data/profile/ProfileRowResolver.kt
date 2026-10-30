package com.levi.pocketdj.data.profile

import com.levi.pocketdj.data.burns.BurnFileNames
import com.levi.pocketdj.mix.engine.MixTrackResolver
import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.mix.engine.ResolvedTrack
import com.levi.pocketdj.mix.engine.StemParts
import com.levi.pocketdj.mix.engine.StemProvider
import com.levi.pocketdj.mix.engine.StemStream
import com.levi.pocketdj.playback.sequencer.LocalFile
import com.levi.pocketdj.playback.sequencer.LocalFileResolver
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.ResolveContext
import com.levi.pocketdj.playback.sequencer.Rung
import com.levi.pocketdj.playback.sequencer.RowSource
import com.levi.pocketdj.playback.sequencer.RowSourceResolver
import com.levi.pocketdj.playback.sequencer.UnplayableSource
import java.io.File

/**
 * Playback + Mix lookups for `pdj_` profile items (iOS `profileResolve` lane). A `pdj_` id resolves ONLY through the
 * profile audio store - never the burn ledger, the rips manifest, or the rip server - and every other id passes
 * straight through to the wrapped resolver.
 */
class ProfileLocalFileResolver(
    private val audio: ProfileAudioStore,
    private val delegate: LocalFileResolver,
    private val toUri: (File) -> String = { android.net.Uri.fromFile(it).toString() },
) : LocalFileResolver {
    override fun localUrlForPlayback(item: QueueItem): LocalFile? {
        val id = item.resolveId
        if (!ProfileSourceStore.isProfileSongId(id)) return delegate.localUrlForPlayback(item)
        val f = audio.originalFor(id) ?: return null   // absent asset: playback skips forward
        return LocalFile(toUri(f))                      // whole file, no album window
    }
}

/**
 * Fence rung: a `pdj_` row that has no local asset is never streamed or sent to /rip - it is simply not playable here
 * (the sequencer advances). Rung [Rung.STUDIO_LOCAL] sorts after LOCAL_FILE and before MANIFEST.
 */
class ProfileFenceResolver(private val audio: ProfileAudioStore) : RowSourceResolver {
    override val id: String = "profile-audio-fence"
    override val rung: Rung = Rung.STUDIO_LOCAL
    override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? =
        if (ProfileSourceStore.isProfileSongId(item.resolveId) && !audio.hasLocalAsset(item.resolveId))
            UnplayableSource(UnplayableSource.Reason.NOT_ON_DEVICE)
        else null
}

/** Mix deck lookup: a `pdj_` original loads as a whole-file cut (plays from 0:00). */
class ProfileMixTrackResolver(
    private val audio: ProfileAudioStore,
    private val delegate: MixTrackResolver,
) : MixTrackResolver {
    override fun exists(songId: String): Boolean =
        if (ProfileSourceStore.isProfileSongId(songId)) audio.hasLocalAsset(songId) else delegate.exists(songId)

    override fun resolve(songId: String): ResolvedTrack? {
        if (!ProfileSourceStore.isProfileSongId(songId)) return delegate.resolve(songId)
        val f = audio.originalFor(songId) ?: return null
        return ResolvedTrack(file = f, isCut = true)
    }
}

/** Mix stem lookup: the item's 4 on-device stems (all-or-nothing); never streamed or fetched. */
class ProfileStemProvider(
    private val audio: ProfileAudioStore,
    private val delegate: StemProvider,
    private val open: (File) -> PcmSource?,
) : StemProvider {
    override fun local(songId: String): StemParts? {
        if (!ProfileSourceStore.isProfileSongId(songId)) return delegate.local(songId)
        val files = audio.stemFiles(songId) ?: return null
        val opened = ArrayList<PcmSource>()
        for (n in BurnFileNames.STEM_NAMES) {
            val src = files[n]?.let(open)
            if (src == null || src.totalFrames <= 0) {
                runCatching { src?.close() }
                opened.forEach { runCatching { it.close() } }
                return null
            }
            opened += src
        }
        return StemParts(opened, complete = true)
    }

    override fun prewarm(songId: String) { if (!ProfileSourceStore.isProfileSongId(songId)) delegate.prewarm(songId) }
    override fun canStream(songId: String) = !ProfileSourceStore.isProfileSongId(songId) && delegate.canStream(songId)
    override fun openStream(songId: String, owner: String): StemStream? =
        if (ProfileSourceStore.isProfileSongId(songId)) null else delegate.openStream(songId, owner)
    override suspend fun fetchWhole(songId: String): Boolean =
        if (ProfileSourceStore.isProfileSongId(songId)) audio.stemFiles(songId) != null else delegate.fetchWhole(songId)
}
