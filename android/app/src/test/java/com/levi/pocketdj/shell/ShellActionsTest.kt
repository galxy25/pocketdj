package com.levi.pocketdj.shell

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.QueueOutcome
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class ShellActionsTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun song(id: String, name: String = "Song $id") =
        IndexSong(id = id, artist = "Artist", name = name, length = 60_000)

    private val merged: MergedCatalog = MergedCatalog.merge(
        listOf(
            IndexJson(
                manifest = IndexManifest(sourceName = "Test"),
                albums = listOf(
                    IndexAlbum(id = "alb_1", artist = "Artist", name = "The Album", trackList = listOf("s1", "s2", "s3")),
                    IndexAlbum(id = "alb_empty", artist = "Artist", name = "Ghost", trackList = listOf("nope")),
                ),
                songs = listOf(song("s1"), song("s2"), song("s3"), song("s4")),
            ),
        ),
    )

    private class FakeReadiness : ReadinessPort {
        var kicks = 0
        var loads = 0
        var awaits = 0
        val networkRefresh = CompletableDeferred<Unit>() // never completed: ensureReady must not wait on it
        override fun kickManifestRefresh() { kicks++ }
        override fun loadCatalog() { loads++ }
        override suspend fun awaitCatalogSeeded() { awaits++ }
    }

    private class Played(val set: Setlist, val context: PlayContext)

    private class Rig(val store: CollectionsStore, val ready: FakeReadiness) {
        var incomplete = false
        var outcome: QueueOutcome = QueueOutcome.Started(2, 0, 2)
        val played = mutableListOf<Played>()
        val routes = mutableListOf<ShellRoute>()
        lateinit var actions: ShellActions
    }

    private fun rig(): Rig {
        val store = CollectionsStore(file = java.io.File(tmp.root, CollectionsStore.FILE_NAME))
        store.catalogProvider = { merged }
        val r = Rig(store, FakeReadiness())
        r.actions = ShellActions(
            collections = store,
            catalog = object : ShellCatalog {
                override fun song(id: String) = merged.songsById[id]
                override fun album(id: String) = merged.albumsById[id]
            },
            player = ShellPlayer { set, ctx -> r.played += Played(set, ctx); r.outcome },
            setup = SetupGate { r.incomplete },
            readiness = r.ready,
            postRoute = { r.routes += it },
        )
        return r
    }

    private suspend fun expect(msg: String, block: suspend () -> Unit) {
        try {
            block()
            fail("expected ShellActionException: $msg")
        } catch (e: ShellActionException) {
            assertEquals(msg, e.message)
        }
    }

    @Test
    fun vetoBlocksEveryMutatingAction_andTouchesNothing() = runTest {
        val r = rig()
        val pocket = r.store.createPocket("P", listOf("s1"))
        val pl = r.store.createPlaylist("L", listOf("s1"))
        r.incomplete = true
        val setup = "Finish setting up PocketDJ in the app first."
        expect(setup) { r.actions.playPlaylist(pl.id, false) }
        expect(setup) { r.actions.playPocket(pocket.id, false) }
        expect(setup) { r.actions.playSong("s1") }
        expect(setup) { r.actions.playAlbum("alb_1", false) }
        expect(setup) { r.actions.playSongIds(listOf("s1"), "x", source = PlayContext.SOURCE_BROWSER) }
        expect(setup) { r.actions.startAutoMix(MixSource.Pocket(pocket.id), false) }
        expect(setup) { r.actions.pauseAutoMix() }
        expect(setup) { r.actions.resumeAutoMix() }
        assertTrue(r.played.isEmpty())
        assertEquals(0, r.ready.loads)
        assertNull(r.store.nowPlayingSetlist())
        assertNull(r.store.pocket(pocket.id)!!.lastPlayedAt)
    }

    @Test
    fun ensureReady_returnsOnDiskSeed_kicksManifestOnce_neverAwaitsNetwork() = runTest {
        val r = rig()
        r.actions.ensureReady()
        r.actions.ensureReady()
        assertEquals(1, r.ready.kicks)
        assertEquals(2, r.ready.loads)
        assertEquals(2, r.ready.awaits)
        assertFalse(r.ready.networkRefresh.isCompleted)
    }

    @Test
    fun playPocket_resolvesDagOrder_returnsName_tagsPocketContext() = runTest {
        val r = rig()
        val child = r.store.createPocket("Child", listOf("s3"))
        val parent = r.store.createPocket("Warmup", listOf("s1", "s2"))
        assertTrue(r.store.addChildPocket(child.id, parent.id))
        val name = r.actions.playPocket(parent.id, shuffle = false)
        assertEquals("Warmup", name)
        val p = r.played.single()
        assertEquals(r.store.playableIdsForPocket(parent.id), p.set.tracks.map { it.songId })
        assertEquals(listOf("s1", "s2", "s3"), p.set.tracks.map { it.songId })
        assertEquals(NOW_PLAYING_SETLIST_ID, p.set.id)
        assertEquals(PlayContext.SOURCE_POCKET, p.context.source)
        assertEquals(NOW_PLAYING_SETLIST_ID, p.context.contextId)
        assertEquals(parent.id, r.store.state.value.nowPlayingOriginId)
        assertTrue(r.store.pocket(parent.id)!!.lastPlayedAt != null)
    }

    @Test
    fun playPlaylist_tagsPlaylist_andShuffleKeepsTheSameSongs() = runTest {
        val r = rig()
        val ids = listOf("s1", "s2", "s3", "s4")
        val pl = r.store.createPlaylist("Peak", ids)
        assertEquals("Peak", r.actions.playPlaylist(pl.id, shuffle = false))
        assertEquals(ids, r.played.last().set.tracks.map { it.songId })
        assertEquals(PlayContext.SOURCE_PLAYLIST, r.played.last().context.source)
        assertEquals("Peak", r.actions.playPlaylist(pl.id, shuffle = true))
        assertEquals(ids.toSet(), r.played.last().set.tracks.map { it.songId }.toSet())
        assertEquals(PlayContext.SOURCE_PLAYLIST, r.played.last().context.source)
    }

    @Test
    fun playAlbum_usesTrackListOrder_tagsAlbum_andDropsUnknownIds() = runTest {
        val r = rig()
        assertEquals("The Album", r.actions.playAlbum("alb_1"))
        assertEquals(listOf("s1", "s2", "s3"), r.played.single().set.tracks.map { it.songId })
        assertEquals(PlayContext.SOURCE_ALBUM, r.played.single().context.source)
        assertEquals("alb_1", r.store.state.value.nowPlayingOriginId)
        r.actions.playAlbum("alb_1", shuffle = true)
        assertEquals(setOf("s1", "s2", "s3"), r.played.last().set.tracks.map { it.songId }.toSet())
        // An album whose tracks are all unresolvable has nothing to play.
        expect("Ghost has no playable songs yet.") { r.actions.playAlbum("alb_empty") }
    }

    @Test
    fun playSetlist_playsSavedRows_tagsSetlist_shuffleKeepsSongs_unknownIdThrows() = runTest {
        val r = rig()
        val pl = r.store.createPlaylist("Peak", listOf("s1", "s2", "s3"))
        val saved = r.store.realize(pl.id, seed = "x", name = "Friday")!!
        assertEquals("Friday", r.actions.playSetlist(saved.id))
        val p = r.played.single()
        assertEquals(listOf("s1", "s2", "s3"), p.set.tracks.map { it.songId })
        assertEquals(NOW_PLAYING_SETLIST_ID, p.set.id)
        assertEquals(PlayContext.SOURCE_SETLIST, p.context.source)
        assertEquals(saved.id, r.store.state.value.nowPlayingOriginId)
        r.actions.playSetlist(saved.id, shuffle = true)
        assertEquals(setOf("s1", "s2", "s3"), r.played.last().set.tracks.map { it.songId }.toSet())
        expect("I couldn't find that set list in PocketDJ.") { r.actions.playSetlist("set_nope") }
        r.incomplete = true
        expect("Finish setting up PocketDJ in the app first.") { r.actions.playSetlist(saved.id) }
        assertEquals(2, r.played.size)
    }

    @Test
    fun playSetlist_keepsFrozenVariantRepeatsDuplicates_stampsPlaylist_reservedReplayKeepsOrigin() = runTest {
        val r = rig()
        val pl = r.store.createPlaylist("Peak", listOf("s1", "s2"))
        val base = r.store.realize(pl.id, seed = "x", name = "Friday")!!
        val frozen = listOf(
            base.tracks[0].copy(variant = "clean", repeatCount = 1),
            base.tracks[1].copy(repeatCount = 2),
            base.tracks[0].copy(variant = "clean", repeatCount = 3),
            base.tracks[0].copy(songId = "ghost_gone", name = "Ghost"),
        )
        val saved = base.copy(tracks = frozen)
        r.store.mutateSetlist(base.id) { it.copy(tracks = frozen) }
        assertNull(r.store.playlist(pl.id)?.lastPlayedAt)
        r.actions.playSetlist(saved.id)
        val got = r.played.last().set.tracks
        assertEquals(listOf("clean", null, "clean", null), got.map { it.variant })
        assertEquals(listOf(1, 2, 3, null), got.map { it.repeatCount })
        assertEquals(listOf("s1", "s2", "s1", "ghost_gone"), got.map { it.songId })
        assertNotNull(r.store.playlist(pl.id)?.lastPlayedAt)
        // Reserved set replay must not overwrite the real origin.
        r.actions.playSetlist(NOW_PLAYING_SETLIST_ID)
        assertEquals(saved.id, r.store.state.value.nowPlayingOriginId)
        assertEquals(PlayContext.SOURCE_SETLIST, r.store.state.value.nowPlayingSource)
    }

    @Test
    fun playLinkSeam_setlistPlaysThroughActions_andFailuresPostMessage() = runTest {
        val r = rig()
        val pl = r.store.createPlaylist("Peak", listOf("s1", "s2"))
        val saved = r.store.realize(pl.id, seed = "x", name = "Friday")!!
        val msgs = mutableListOf<String>()
        var job: kotlinx.coroutines.Job? = null
        val seam = playLinkSeam(r.actions, this, { job = it }) { msgs += it }
        assertNull(seam(PlayKind.Setlist, saved.id, false))
        job!!.join()
        assertEquals(PlayContext.SOURCE_SETLIST, r.played.single().context.source)
        assertEquals(saved.id, r.store.state.value.nowPlayingOriginId)
        seam(PlayKind.Setlist, "set_nope", false)
        job!!.join()
        assertEquals(listOf("I couldn't find that set list in PocketDJ."), msgs)
        assertEquals(1, r.played.size)
    }

    @Test
    fun playSong_oneTrackBrowserSet_returnsTitle() = runTest {
        val r = rig()
        assertEquals("Song s2", r.actions.playSong("s2"))
        assertEquals(listOf("s2"), r.played.single().set.tracks.map { it.songId })
        assertEquals(PlayContext.SOURCE_BROWSER, r.played.single().context.source)
    }

    @Test
    fun notFoundMessages_areTheIosStrings() = runTest {
        val r = rig()
        expect("I couldn't find that playlist in PocketDJ.") { r.actions.playPlaylist("pls_nope", false) }
        expect("I couldn't find that pocket in PocketDJ.") { r.actions.playPocket("pkt_nope", false) }
        expect("I couldn't find that song in your PocketDJ sources.") { r.actions.playSong("nope") }
        expect("I couldn't find that song in your PocketDJ sources.") { r.actions.playAlbum("nope") }
        assertTrue(r.played.isEmpty())
    }

    @Test
    fun emptyCollection_namesIt_andNothingPlayableSurfaces() = runTest {
        val r = rig()
        val empty = r.store.createPocket("Blank")
        expect("Blank has no playable songs yet.") { r.actions.playPocket(empty.id, false) }
        val pl = r.store.createPlaylist("Empty")
        expect("Empty has no playable songs yet.") { r.actions.playPlaylist(pl.id, false) }
        val pocket = r.store.createPocket("P", listOf("s1"))
        r.outcome = QueueOutcome.NothingPlayable(1)
        expect("None of the songs in P are playable on this device yet.") { r.actions.playPocket(pocket.id, false) }
        r.outcome = QueueOutcome.Failed("boom")
        expect("boom") { r.actions.playPocket(pocket.id, false) }
    }

    @Test
    fun playSongIds_snapshotsAndTagsTheGivenSource() = runTest {
        val r = rig()
        assertEquals("Mine", r.actions.playSongIds(listOf("s1", "ghost", "s2"), "Mine", source = PlayContext.SOURCE_PLAYLIST))
        assertEquals(listOf("s1", "s2"), r.played.single().set.tracks.map { it.songId })
        assertEquals(PlayContext.SOURCE_PLAYLIST, r.played.single().context.source)
    }

    @Test
    fun autoMix_reportsUnavailable_whileFacadeIsNull() = runTest {
        val r = rig()
        val pocket = r.store.createPocket("P", listOf("s1"))
        val msg = "Auto-Mix isn't available yet"
        expect(msg) { r.actions.startAutoMix(MixSource.Pocket(pocket.id), false) }
        expect(msg) { r.actions.startAutoMix(MixSource.Pocket(pocket.id), MixSource.Pocket(pocket.id), false) }
        expect(msg) { r.actions.pauseAutoMix() }
        expect(msg) { r.actions.resumeAutoMix() }
    }

    private class FakeMix : MixFacade {
        override var autoMixing = false
        override var autoPaused = false
        var started = 0
        var paused = 0
        var resumed = 0
        override suspend fun startAutoMix(source: MixSource, shuffle: Boolean, allowPendingStart: Boolean): MixStartResult {
            started++
            autoMixing = true
            return MixStartResult("mix", 3)
        }
        override suspend fun startAutoMix(deckA: MixSource, deckB: MixSource, shuffle: Boolean, allowPendingStart: Boolean): MixStartResult {
            started++
            return MixStartResult("a + b", 6)
        }
        override fun pauseAutoMix() { paused++; autoPaused = true }
        override fun resumeAutoMix() { resumed++; autoPaused = false }
    }

    @Test
    fun autoMix_withFacade_validatesSources_andGuardsPauseResumeState() = runTest {
        val r = rig()
        val mix = FakeMix()
        r.actions.mixFacade = mix
        val pocket = r.store.createPocket("P", listOf("s1"))
        expect("I couldn't find that pocket, playlist, or set list in PocketDJ.") {
            r.actions.startAutoMix(MixSource.Playlist("ghost"), false)
        }
        assertEquals(0, mix.started)
        expect("There's no auto-mix running.") { r.actions.pauseAutoMix() }
        assertEquals(MixStartResult("mix", 3), r.actions.startAutoMix(MixSource.Pocket(pocket.id), true))
        expect("The auto-mix isn't paused.") { r.actions.resumeAutoMix() }
        r.actions.pauseAutoMix()
        r.actions.resumeAutoMix()
        assertEquals(1, mix.paused)
        assertEquals(1, mix.resumed)
    }

    @Test
    fun searchAndOpen_postRoutes_withoutTheVeto() {
        val r = rig()
        r.incomplete = true
        r.actions.search("  warm up ")
        r.actions.open(ShellRoute.Pocket("p1"))
        assertEquals(listOf(ShellRoute.BrowseSearch("warm up"), ShellRoute.Pocket("p1")), r.routes)
    }
}
