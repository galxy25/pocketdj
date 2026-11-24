package com.levi.pocketdj.shell

import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.QueueOutcome
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** P2-MIX-1: the "Play in Now Playing" zero-dead-air fallback (iOS `playMixCratesInNowPlaying`). */
@OptIn(ExperimentalCoroutinesApi::class)
class ShellActionsMixFallbackTest {
    @get:Rule val tmp = TemporaryFolder()

    private val merged: MergedCatalog = MergedCatalog.merge(
        listOf(
            IndexJson(
                manifest = IndexManifest(sourceName = "Test"),
                songs = listOf("s1", "s2", "s3", "s4").map { IndexSong(id = it, artist = "Artist", name = "Song $it", length = 60_000) },
            ),
        ),
    )

    private class FakeMix : MixFacade {
        override val autoMixing = false
        override val autoPaused = false
        var released = 0
        /** What the sequencer had started when the Mix was released (ONE audio owner: play first, release on success). */
        var playedAtRelease = -1
        lateinit var played: () -> Int
        override suspend fun startAutoMix(source: MixSource, shuffle: Boolean, allowPendingStart: Boolean) = MixStartResult("m", 1)
        override suspend fun startAutoMix(deckA: MixSource, deckB: MixSource, shuffle: Boolean, allowPendingStart: Boolean) = MixStartResult("m", 1)
        override fun pauseAutoMix() {}
        override fun resumeAutoMix() {}
        override suspend fun releaseForNowPlaying() { released++; playedAtRelease = played() }
    }

    private class Rig(val store: CollectionsStore) {
        var incomplete = false
        var failPlay = false
        val played = mutableListOf<Pair<Setlist, PlayContext>>()
        lateinit var actions: ShellActions
    }

    private fun rig(): Rig {
        val store = CollectionsStore(file = java.io.File(tmp.root, CollectionsStore.FILE_NAME))
        store.catalogProvider = { merged }
        val r = Rig(store)
        r.actions = ShellActions(
            collections = store,
            catalog = object : ShellCatalog {
                override fun song(id: String) = merged.songsById[id]
                override fun album(id: String) = merged.albumsById[id]
            },
            player = ShellPlayer { set, ctx -> if (r.failPlay) QueueOutcome.Failed("boom") else { r.played += set to ctx; QueueOutcome.Started(set.tracks.size, 0, set.tracks.size) } },
            setup = SetupGate { r.incomplete },
            readiness = object : ReadinessPort {
                override fun kickManifestRefresh() {}
                override fun loadCatalog() {}
                override suspend fun awaitCatalogSeeded() {}
            },
            postRoute = {},
        )
        return r
    }

    @Test fun cratesUnionIsPlayedOnceInNowPlayingAndTheMixIsReleased() = runTest {
        val r = rig()
        val mix = FakeMix().also { it.played = { r.played.size } }
        r.actions.mixFacade = mix
        val p1 = r.store.createPocket("Warm", listOf("s1", "s2", "s3"))
        val pl = r.store.createPlaylist("Peak", listOf("s3", "s4"))
        val n = r.actions.playMixCratesInNowPlaying(
            listOf(MixSource.Pocket(p1.id), MixSource.Playlist(pl.id)), listOf("Warm", "Peak"), shuffle = false,
        )
        assertEquals("a song in two crates counts once", 4, n)
        val (set, ctx) = r.played.single()
        assertEquals(listOf("s1", "s2", "s3", "s4"), set.tracks.map { it.songId })
        assertEquals(NOW_PLAYING_SETLIST_ID, set.id)
        assertEquals(PlayContext.SOURCE_MIX, ctx.source)
        assertEquals(1, mix.released)
        assertEquals("the Mix is released only AFTER Now Playing started", 1, mix.playedAtRelease)
    }

    @Test fun failedNowPlayingStartLeavesTheRunningMixAlone() = runTest {
        val r = rig()
        val mix = FakeMix().also { it.played = { r.played.size } }
        r.actions.mixFacade = mix
        r.failPlay = true
        val p = r.store.createPocket("P", listOf("s1"))
        try {
            r.actions.playMixCratesInNowPlaying(listOf(MixSource.Pocket(p.id)), listOf("P"))
            org.junit.Assert.fail("expected the failed start to surface")
        } catch (e: ShellActionException) { /* expected */ }
        assertEquals("a failed start must not silence the Mix", 0, mix.released)
    }

    @Test fun nothingResolvableLeavesTheMixAlone() = runTest {
        val r = rig()
        val mix = FakeMix().also { it.played = { r.played.size } }
        r.actions.mixFacade = mix
        val empty = r.store.createPocket("Empty", emptyList())
        assertEquals(0, r.actions.playMixCratesInNowPlaying(listOf(MixSource.Pocket(empty.id)), listOf("Empty")))
        assertEquals(0, mix.released)
        assertTrue(r.played.isEmpty())
        assertEquals(0, r.actions.playMixCratesInNowPlaying(emptyList(), emptyList()))
    }

    @Test fun setupIncompleteVetoesTheFallback() = runTest {
        val r = rig()
        r.incomplete = true
        try {
            r.actions.playMixCratesInNowPlaying(listOf(MixSource.Pocket("p")), listOf("P"))
            org.junit.Assert.fail("expected veto")
        } catch (e: ShellActionException) {
            assertEquals(ShellActionException.SetupIncomplete, e)
        }
    }

    @Test fun defaultNameWhenNoCrateHasOne() = runTest {
        val r = rig()
        val p = r.store.createPocket("P", listOf("s1"))
        r.actions.playMixCratesInNowPlaying(listOf(MixSource.Pocket(p.id)), emptyList(), shuffle = false)
        assertEquals("Mix crates", r.played.single().first.name)
    }
}
