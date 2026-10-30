package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** STU-7: studio items in counts / runtime / realize / playNow (iOS studioLookup seam). */
class RealizeStudioEntriesTest {
    @get:Rule val tmp = TemporaryFolder()

    private val loopId = "lp_11111111-1111-1111-1111-111111111111"
    private val sampleId = "smp_22222222-2222-2222-2222-222222222222"
    private val patternId = "ptn_33333333-3333-3333-3333-333333333333"

    private val infos = mapOf(
        loopId to StudioItemInfo("Four Bars", 4_000, bpm = 96.0, camelot = "5A", kindLabel = "Loop"),
        sampleId to StudioItemInfo("Snare Hit", 800, kindLabel = "Sample"),
        patternId to StudioItemInfo("Groove", 8_000, bpm = 120.0, kindLabel = "Sequence"),
    )
    private val asked = ArrayList<String>()
    private val lookup = StudioLookup { id -> asked += id; infos[id] }

    private fun song(id: String, ms: Long? = 60_000, bpm: Double? = 120.0, camelot: String? = "8A") =
        IndexSong(id = id, artist = "A", name = "S $id", bpm = bpm, camelot = camelot, length = ms)

    private val songs = listOf(song("sng_1"), song("sng_2", ms = null))

    private fun ctx(lk: StudioLookup? = lookup, pockets: List<Pocket> = emptyList()) = RealizeCtx(
        songsById = songs.associateBy { it.id }, albumsById = emptyMap(),
        pocketsById = pockets.associateBy { it.id },
        candidates = songs.filter { it.bpm != null && it.camelot != null },
        studioLookup = lk,
    )

    private fun songNode(id: String) = PlaylistNode(nodeId = CollectionsFactory.newNodeId(), kind = PlaylistNode.Kind.SONG, songId = id)

    private fun playlist(vararg ids: String) = Playlist(
        id = "pls_t", name = "T",
        sequences = listOf(PlaylistNode(nodeId = "nd_c", kind = PlaylistNode.Kind.SEQUENCE, name = "Default", children = ids.map(::songNode))),
        createdAt = 0.0, updatedAt = 0.0,
    )

    @Test fun realizedLoopKeepsItsRealFourSecondLengthNotTheCatalogDefault() {
        val perf = RealizeEngine.realize(playlist("sng_1", loopId), ctx())
        assertEquals(listOf("sng_1", loopId), perf.tracks.map { it.songId })
        val t = perf.tracks[1]
        assertEquals(4_000L, t.lengthMs)
        assertEquals(96.0, t.bpm!!, 0.0)
        assertEquals("5A", t.camelot)
        assertEquals("Four Bars", t.name)
        assertEquals(TrackSource.EXPLICIT, t.source)
        assertEquals(60_000L + 4_000L, perf.totalMs)   // NOT 60_000 + 210_000
    }

    @Test fun zeroLengthCatalogSongStillUsesDefaultButStudioNeverDoes() {
        val perf = RealizeEngine.realize(playlist("sng_2", sampleId), ctx())
        assertEquals(RealizeEngine.DEFAULT_TRACK_MS + 800L, perf.totalMs)
    }

    @Test fun studioIdsDropWhenTheSeamIsUnwiredOrDoesNotKnowThem() {
        assertEquals(listOf("sng_1"), RealizeEngine.realize(playlist("sng_1", loopId), ctx(lk = null)).tracks.map { it.songId })
        val unknown = "lp_99999999-9999-9999-9999-999999999999"
        assertEquals(listOf("sng_1"), RealizeEngine.realize(playlist("sng_1", unknown), ctx()).tracks.map { it.songId })
    }

    @Test fun lookupIsOnlyConsultedForStudioShapedIds() {
        RealizeEngine.realize(playlist("sng_1", "sng_missing", "amrec_x", loopId), ctx())
        assertEquals(listOf(loopId), asked)
    }

    @Test fun studioItemsAreNeverAutofillCandidates() {
        val c = ctx()
        assertTrue(c.candidates.none { PlayResolverShape.isStudio(it.id) })
        // Even after a realize that placed a studio entry the candidate pool is untouched.
        RealizeEngine.realize(playlist(loopId), c)
        assertEquals(songs.filter { it.bpm != null }.map { it.id }, c.candidates.map { it.id })
        assertTrue(RealizeEngine.realize(playlist(loopId), c).stats.autofilled == 0)
    }

    @Test fun pocketMembersResolveStudioInOrderAndDedupe() {
        val pocket = Pocket(id = "pkt_a", name = "P", songIds = listOf("sng_1", loopId, loopId, sampleId))
        val songsIn = RealizeEngine.resolvePocketSongs("pkt_a", ctx(pockets = listOf(pocket)), HashSet())
        assertEquals(listOf("sng_1", loopId, sampleId), songsIn.map { it.id })
        assertEquals(4_000L, songsIn[1].length)
    }

    @Test fun syntheticSongCarriesMandatoryLengthArtistAndMixFields() {
        val s = studioSyntheticSong(loopId, infos.getValue(loopId))
        assertEquals(4_000L, s.length); assertEquals(STUDIO_ARTIST, s.artist); assertEquals("Four Bars", s.name)
        assertEquals(96.0, s.bpm!!, 0.0); assertEquals("5A", s.camelot)
        assertEquals("PocketDJ Me", studioSyntheticSong(sampleId, infos.getValue(sampleId), artist = "PocketDJ Me").artist)
    }

    @Test fun catalogStatsIncludeStudioWithRealRuntime() {
        val pocket = Pocket(id = "pkt_a", name = "P", songIds = listOf("sng_1", loopId, sampleId, "sng_missing"))
        val cat = CollectionCatalog(songs.associateBy { it.id }, emptyMap(), mapOf(pocket.id to pocket), lookup)
        val st = cat.statsForPocket("pkt_a")
        assertEquals(3, st.count)
        assertEquals(60_000L + 4_000L + 800L, st.runtimeMs)
        val pl = playlist("sng_1", patternId, loopId)
        val ps = cat.statsForPlaylist(pl)
        assertEquals(3, ps.count); assertEquals(60_000L + 8_000L + 4_000L, ps.runtimeMs)
        assertEquals(3, cat.statsForChapter(pl.sequences[0]).count)
    }

    @Test fun catalogStatsWithoutSeamDropStudioExactlyAsBefore() {
        val pocket = Pocket(id = "pkt_a", name = "P", songIds = listOf("sng_1", loopId))
        val st = CollectionCatalog(songs.associateBy { it.id }, emptyMap(), mapOf(pocket.id to pocket)).statsForPocket("pkt_a")
        assertEquals(1, st.count); assertEquals(60_000L, st.runtimeMs)
    }

    // ---- store level: songIds* stay studio-stripped, playableIds* / playNow keep studio

    @Test fun studioArtistComesFromProfileNameWithPocketDjFallback() {
        assertEquals("DJ Levi", studioArtistFor("  DJ Levi "))
        assertEquals("Pocket DJ", studioArtistFor(""))
        assertEquals("Pocket DJ", studioArtistFor("   "))
        assertEquals("Pocket DJ", studioArtistFor(null))
        val s = store()
        s.studioArtist = { studioArtistFor("Levi") }
        assertEquals("Levi", s.playNow(listOf(loopId))!!.tracks[0].artist)
        s.studioArtist = { studioArtistFor("") }
        assertEquals("Pocket DJ", s.playNow(listOf(loopId))!!.tracks[0].artist)
    }

    @Test fun wireStudioArtistFollowsTheRealProfileStore() {
        val profile = com.levi.pocketdj.data.sync.ProfileStore(File(tmp.root, "pocketdj-profile.json"))
        val s = store()
        wireStudioArtist(s) { profile.name }
        assertEquals("Pocket DJ", s.playNow(listOf(loopId))!!.tracks[0].artist)
        profile.setName("DJ Levi")
        assertEquals("DJ Levi", s.playNow(listOf(loopId))!!.tracks[0].artist)
        wireStudioArtist(s) { error("boom") }
        assertEquals("Pocket DJ", s.playNow(listOf(loopId))!!.tracks[0].artist)
    }

    @Test fun playNowHonorsRepeatCountForASingleStudioRow() {
        val set = store().playNow(listOf(loopId), repeats = mapOf(loopId to 4))!!
        assertEquals(4, set.tracks[0].repeatCount)
    }

    @Test fun realizeUsesTheProfileArtistForStudioEntries() {
        val c = ctx().copy(studioArtist = studioArtistFor("Levi"))
        assertEquals("Levi", RealizeEngine.realize(playlist(loopId), c).tracks[0].artist)
    }

    @Test fun cleanOnlyDimsOnlyExplicitRowsWithoutACleanCut() {
        val explicit = IndexSong(id = "e", artist = "A", name = "E", explicit = true)
        val clean = IndexSong(id = "c", artist = "A", name = "C", explicit = false)
        assertTrue(isCleanOnlyDimmed(true, explicit))
        assertFalse(isCleanOnlyDimmed(true, clean))
        assertFalse(isCleanOnlyDimmed(false, explicit))
        assertFalse(isCleanOnlyDimmed(null, explicit))
        assertFalse(isCleanOnlyDimmed(true, null))
    }

    private fun store(): CollectionsStore {
        val merged = MergedCatalog.merge(listOf(IndexJson(manifest = IndexManifest(sourceName = "V"), albums = emptyList(), songs = songs)))
        return CollectionsStore(file = File(tmp.root, CollectionsStore.FILE_NAME), now = { 1_750_000_000_000.0 }).also {
            it.catalogProvider = { merged }
            it.studioLookup = lookup
        }
    }

    @Test fun playableIdsKeepStudioWhileRipFacingSongIdsStripIt() {
        val s = store()
        val p = s.createPocket("Crate")
        s.addSongToPocket("sng_1", p.id); s.addSongToPocket(loopId, p.id)
        assertEquals(listOf("sng_1", loopId), s.playableIdsForPocket(p.id))
        assertEquals(listOf("sng_1"), s.songIdsForPocket(p.id))
        val st = s.statsForPocket(p.id)
        assertEquals(2, st.count); assertEquals(64_000L, st.runtimeMs)
    }

    @Test fun playNowBuildsStudioRowsWithRealLengthAndDropsUnknown() {
        val s = store()
        val set = s.playNow(listOf("sng_1", loopId, "lp_nope", "sng_zzz"))!!
        assertEquals(listOf("sng_1", loopId), set.tracks.map { it.songId })
        assertEquals(4_000L, set.tracks[1].lengthMs)
        assertEquals(64_000L, set.totalMs)
        s.studioArtist = { "DJ Levi" }
        assertEquals("DJ Levi", s.playNow(listOf(loopId))!!.tracks[0].artist)
    }

    @Test fun makeCtxCandidatesExcludeStudioAndRealizeThroughStoreKeepsLength() {
        val s = store()
        val pl = s.createPlaylist("L")
        val seq = pl.sequences[0]
        s.addSongToPlaylist(loopId, pl.id, seq.nodeId)
        val ctx = s.makeCtx()!!
        assertTrue(ctx.candidates.none { it.id == loopId })
        val set = s.realize(pl.id)!!
        assertEquals(4_000L, set.tracks.single { it.songId == loopId }.lengthMs)
        assertFalse(set.tracks.any { it.source == TrackSource.AUTOFILL })
        assertNull(s.studioInfo("sng_1"))
        assertEquals("Four Bars", s.studioInfo(loopId)?.title)
    }

    private object PlayResolverShape {
        fun isStudio(id: String) = com.levi.pocketdj.data.rips.PlayResolver.isStudioId(id)
    }
}
