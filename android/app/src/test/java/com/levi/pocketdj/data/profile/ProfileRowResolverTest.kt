package com.levi.pocketdj.data.profile

import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.mix.engine.MixTrackResolver
import com.levi.pocketdj.mix.engine.ResolvedTrack
import com.levi.pocketdj.mix.engine.StemParts
import com.levi.pocketdj.mix.engine.StemProvider
import com.levi.pocketdj.mix.engine.StemStream
import com.levi.pocketdj.playback.PlaybackMode
import com.levi.pocketdj.playback.sequencer.LocalFile
import com.levi.pocketdj.playback.sequencer.LocalFileResolver
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.ResolveContext
import com.levi.pocketdj.playback.sequencer.UnplayableSource
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ProfileRowResolverTest {
    @get:Rule val tmp = TemporaryFolder()

    private val store by lazy { ProfileSourceStore(File(tmp.root, "p.json"), File(tmp.root, "profile-audio")) }
    private val audio by lazy { ProfileAudioStore(store) }
    private val ctx = ResolveContext(PlaybackMode.DEVICE, ripServerConfigured = false, ripStartsNow = false)

    private fun src(n: String) = File(tmp.root, "src-$n").also { it.writeText(n) }
    private fun ingest(withStems: Boolean = false): String = runBlocking {
        val stems = if (withStems) listOf("vocals", "drums", "bass", "other").associateWith { src(it) } else null
        audio.ingest(ProfileSourceStore.Kind.DEMUX, "t", src("o.mp3"), stems = stems)!!.songId
    }

    private val burned = LocalFileResolver { item -> LocalFile("file:///burned/${item.resolveId}") }

    @Test fun profileIdPlaysTheLocalOriginalWholeFileNeverTheBurnLedger() {
        val id = ingest()
        val r = ProfileLocalFileResolver(audio, burned) { "file://" + it.path }
        val lf = r.localUrlForPlayback(QueueItem(id = id))!!
        assertTrue(lf.url.endsWith("$id.mp3"))
        assertNull(lf.startMs); assertNull(lf.endMs)
    }

    @Test fun otherIdsPassThroughAndAbsentProfileAssetIsNull() {
        val r = ProfileLocalFileResolver(audio, burned) { "file://" + it.path }
        assertEquals("file:///burned/sng_1", r.localUrlForPlayback(QueueItem(id = "sng_1"))!!.url)
        assertNull(r.localUrlForPlayback(QueueItem(id = "pdj_gone")))   // does NOT fall through to burned
    }

    @Test fun fenceBlocksAnAbsentProfileRowOnlyAndLetsAPresentOneThrough() = runBlocking {
        val id = ingest(); val fence = ProfileFenceResolver(audio)
        assertNull(fence.resolve(QueueItem(id = id), ctx))
        assertNull(fence.resolve(QueueItem(id = "sng_1"), ctx))
        val gone = fence.resolve(QueueItem(id = "pdj_gone"), ctx) as UnplayableSource
        assertEquals(UnplayableSource.Reason.NOT_ON_DEVICE, gone.reason)
    }

    private val inner = object : MixTrackResolver {
        override fun resolve(songId: String) = ResolvedTrack(File("/burn/$songId"), isCut = false, startMs = 5)
    }

    @Test fun mixResolvesProfileAsWholeFileCutAndDelegatesTheRest() {
        val id = ingest(); val r = ProfileMixTrackResolver(audio, inner)
        assertTrue(r.exists(id))
        val t = r.resolve(id)!!
        assertTrue(t.isCut); assertNull(t.startMs); assertEquals("$id.mp3", t.file.name)
        assertEquals("/burn/sng_1", r.resolve("sng_1")!!.file.path)
        assertFalse(r.exists("pdj_gone")); assertNull(r.resolve("pdj_gone"))
    }

    @Test fun mixRefusesNonMp3ProfileOriginals() = runBlocking {
        val src = File(tmp.root, "x.m4a").also { it.writeBytes(byteArrayOf(1, 2, 3)) }
        val e = audio.ingest(ProfileSourceStore.Kind.DEMUX, "T", src, 1000)!!
        val r = ProfileMixTrackResolver(audio, inner)
        assertFalse(r.exists(e.songId)); assertNull(r.resolve(e.songId))
    }

    private class FakeSrc(override val totalFrames: Long) : PcmSource {
        override val sampleRate = 44100
        override val channels = 2
        override val isComplete = true
        override val availableFrames: Long get() = totalFrames
        override fun seek(frame: Long) {}
        override fun read(dst: FloatArray, frames: Int) = -1
        var closed = false
        override fun close() { closed = true }
    }

    private val innerStems = object : StemProvider {
        override fun local(songId: String) = StemParts(emptyList(), complete = true)
        override fun canStream(songId: String) = true
        override fun openStream(songId: String, owner: String): StemStream? = null
        override suspend fun fetchWhole(songId: String) = true
    }

    @Test fun stemProviderOpensTheFourProfileStemsAndNeverStreamsThem() = runBlocking {
        val id = ingest(withStems = true); val opened = ArrayList<String>()
        val p = ProfileStemProvider(audio, innerStems) { f -> opened += f.nameWithoutExtension; FakeSrc(10) }
        assertEquals(4, p.local(id)!!.sources.size)
        assertEquals(listOf("vocals", "drums", "bass", "other"), opened)
        assertFalse(p.canStream(id)); assertNull(p.openStream(id, "o")); assertTrue(p.fetchWhole(id))
        assertTrue(p.canStream("sng_1"))       // delegated
        assertNotNull(p.local("sng_1"))
    }

    @Test fun stemProviderIsAllOrNothingAndClosesWhatItOpened() {
        val id = ingest(withStems = true); val made = ArrayList<FakeSrc>()
        val p = ProfileStemProvider(audio, innerStems) { f -> FakeSrc(if (f.nameWithoutExtension == "bass") 0 else 10).also { made += it } }
        assertNull(p.local(id))
        assertTrue(made.all { it.closed })
    }

    @Test fun noStemsMeansNullAndNoFetch() = runBlocking {
        val id = ingest(withStems = false)
        val p = ProfileStemProvider(audio, innerStems) { FakeSrc(10) }
        assertNull(p.local(id)); assertFalse(p.fetchWhole(id))
    }
}

