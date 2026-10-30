package com.levi.pocketdj.auto

import com.levi.pocketdj.shell.MixFacade
import com.levi.pocketdj.shell.MixSource
import com.levi.pocketdj.shell.MixStartResult
import com.levi.pocketdj.shell.ShellActionException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoMixTabTest {
    private class FakeFacade : MixFacade {
        override var autoMixing = false
        override var autoPaused = false
        val calls = mutableListOf<String>()
        var startCount = 5
        var failure: Exception? = null
        override suspend fun startAutoMix(source: MixSource, shuffle: Boolean, allowPendingStart: Boolean): MixStartResult {
            calls += "one:${AutoMixTab.keyOf(source)}:$shuffle:$allowPendingStart"
            failure?.let { throw it }
            autoMixing = true
            return MixStartResult("X", startCount)
        }
        override suspend fun startAutoMix(deckA: MixSource, deckB: MixSource, shuffle: Boolean, allowPendingStart: Boolean): MixStartResult {
            calls += "two:${AutoMixTab.keyOf(deckA)}+${AutoMixTab.keyOf(deckB)}:$shuffle:$allowPendingStart"
            failure?.let { throw it }
            autoMixing = true
            return MixStartResult("X", startCount)
        }
        override fun pauseAutoMix() { calls += "pause"; autoPaused = true }
        override fun resumeAutoMix() { calls += "resume"; autoPaused = false }
    }

    private class FakeExtras : AutoMixExtras {
        var crates = listOf(
            AutoCrate(MixSource.Pocket("p1"), "Warmup", AutoCrateGroup.POCKETS),
            AutoCrate(MixSource.Playlist("l2"), "Brunch", AutoCrateGroup.PLAYLISTS),
            AutoCrate(MixSource.Playlist("l1"), "Gym", AutoCrateGroup.PLAYLISTS),
            AutoCrate(MixSource.Setlist("s1"), "Friday Set", AutoCrateGroup.SETLISTS),
        )
        var live: AutoMixLive? = null
        var dl: Pair<Int, Int>? = null
        var parked: AutoParkedMix? = null
        override fun parkedMix() = parked
        override fun resumeParkedMix() { calls += "resumeParked" }
        override fun materializePendingRestoreIfNeeded(trigger: String) { calls += "materialize:$trigger" }
        override var slowSkipSeconds = 15.0
        val calls = mutableListOf<String>()
        var sessions: List<AutoJukeSession>? = emptyList()
        var sessionCalls = 0
        val flow = MutableSharedFlow<String>(extraBufferCapacity = 8)
        override fun crates() = crates
        override fun live() = live
        override fun downloadState() = dl
        override fun skipFast() { calls += "fast" }
        override fun skipSlow() { calls += "slow" }
        override fun stop() { calls += "stop" }
        override val changes get() = flow
        override suspend fun jukeboxSessions(): List<AutoJukeSession>? { sessionCalls++; return sessions }
    }

    private class Rig {
        val facade = FakeFacade()
        val extras = FakeExtras()
        var now = 1_000L
        val tab = AutoMixTab(facade, extras) { now }
        val notified = mutableListOf<Pair<String, Int>>()
        init { tab.bind(CoroutineScope(Dispatchers.Unconfined)) { p, n -> notified += p to n } }
        fun kids(id: AutoId.Mix = AutoMixTab.ROOT) = tab.children(id)!!
        fun mixId(k: AutoMixKind, a: String = "", b: String = "") = AutoId.Mix(k, a, b)
        fun sel(k: AutoMixKind, a: String = "", b: String = "") = runBlocking { tab.select(mixId(k, a, b)) }
    }

    private fun tree(rig: Rig?) = AutoBrowseTree(FakeAutoData(), mix = rig?.tab)

    @Test fun setup_showsDownloadingRowWhileZeroStartPulls() {
        val r = Rig()
        assertTrue(r.kids().none { it.id.startsWith("mix:dl") })
        r.extras.dl = 1 to 7
        val row = r.kids().first { it.id.startsWith("mix:dl") }
        assertEquals("Downloading 1 of 7", row.title)
    }

    @Test fun root_describesTheParkedMixWithoutMaterializingIt() {
        val r = Rig()
        r.extras.parked = AutoParkedMix("Song", "Band", "Gym")
        val row = r.kids().first { it.id == r.mixId(AutoMixKind.PARKED).encoded }
        assertEquals("Song — Band", row.title)
        assertTrue(row.subtitle!!.startsWith("Paused · Gym"))
        assertTrue(row.playable)
        assertTrue("browsing the Mix root (car connect) must never touch the decks", r.extras.calls.none { it.startsWith("materialize") || it == "resumeParked" })
    }

    @Test fun parkedRowTap_materializesAndResumes_andNothingParkedShowsNoRow() {
        val r = Rig()
        assertTrue(r.kids().none { it.id.startsWith("mix:parked") })
        r.extras.parked = AutoParkedMix("Song", null, null)
        r.sel(AutoMixKind.PARKED)
        assertEquals(listOf("resumeParked"), r.extras.calls)
    }

    @Test fun crateSelect_renotifiesOldAndNewGroups() {
        val r = Rig()
        r.sel(AutoMixKind.CRATE, "a", "playlist:l1")
        r.notified.clear()
        r.sel(AutoMixKind.CRATE, "a", "pocket:p1")
        val ids = r.notified.map { it.first }
        assertTrue(ids.contains(r.mixId(AutoMixKind.GROUP, "a", "playlists").encoded))
        assertTrue(ids.contains(r.mixId(AutoMixKind.GROUP, "a", "pockets").encoded))
    }

    @Test fun groupKeepsExtrasOrder_andStatusRowIsPlayable() {
        val r = Rig()
        r.extras.crates = listOf(
            AutoCrate(MixSource.Playlist("1"), "Mix 2", AutoCrateGroup.PLAYLISTS),
            AutoCrate(MixSource.Playlist("2"), "Mix 10", AutoCrateGroup.PLAYLISTS),
            AutoCrate(MixSource.Playlist("3"), "alpha", AutoCrateGroup.PLAYLISTS),
        )
        assertEquals(listOf("Mix 2", "Mix 10", "alpha"), r.kids(r.mixId(AutoMixKind.GROUP, "a", "playlists")).map { it.title })
        r.facade.autoMixing = true
        assertTrue(r.kids().first { it.id.startsWith("mix:status") }.playable)
        assertNull(r.sel(AutoMixKind.STATUS))
    }

    @Test fun hiddenWithoutFacade() {
        val ids = tree(null).children(AutoId.Root.encoded)!!.map { it.id }
        assertFalse(ids.any { it.startsWith("mix:") })
        assertNull(tree(null).children(AutoMixTab.ROOT.encoded))
    }

    @Test fun shownAsRootTabWhenWired() {
        val rig = Rig()
        val root = tree(rig).children(AutoId.Root.encoded)!!
        assertEquals(listOf("Playlists", "Pockets", "Mix"), root.map { it.title })
        assertTrue(root.last().browsable)
    }

    @Test fun setupSection_blankDecksAndDisabledStart() {
        val rig = Rig()
        val k = rig.kids()
        assertEquals(listOf("Deck A", "Deck B", "▶ Start Mix", "Jukebox"), k.map { it.title })
        assertEquals("Choose a crate…", k[0].subtitle)
        assertEquals("Same as Deck A", k[1].subtitle)
        assertEquals("Pick Deck A first", k[2].subtitle)
        assertEquals("Pick Deck A first", rig.sel(AutoMixKind.START))
        assertTrue(rig.facade.calls.isEmpty())
    }

    @Test fun crateListGroupsPocketsPlaylistsSetlists() {
        val rig = Rig()
        val groups = rig.kids(rig.mixId(AutoMixKind.DECK, "a"))
        assertEquals(listOf("Pockets", "Playlists", "Set lists"), groups.map { it.title })
        assertEquals("2 crates", groups[1].subtitle)
        val playlists = rig.kids(rig.mixId(AutoMixKind.GROUP, "a", "playlists"))
        assertEquals(listOf("Brunch", "Gym"), playlists.map { it.title })
        assertTrue(playlists.all { it.playable })
    }

    @Test fun deckB_offersSameAsDeckA_andEmptyGroupsAreHidden() {
        val rig = Rig()
        rig.extras.crates = rig.extras.crates.filter { it.group == AutoCrateGroup.POCKETS }
        val b = rig.kids(rig.mixId(AutoMixKind.DECK, "b"))
        assertEquals(listOf("Same as Deck A", "Pockets"), b.map { it.title })
        assertEquals("Selected", b[0].subtitle)
    }

    @Test fun pickingCrates_updatesSubtitles_andStartUsesBoth() {
        val rig = Rig()
        rig.sel(AutoMixKind.CRATE, "a", "pocket:p1")
        assertEquals("Warmup", rig.kids()[0].subtitle)
        assertEquals("Shuffled auto-mix", rig.kids()[2].subtitle)
        assertEquals("Deck B: Gym", rig.sel(AutoMixKind.CRATE, "b", "playlist:l1"))
        assertEquals("Selected · Playlists", rig.kids(rig.mixId(AutoMixKind.GROUP, "b", "playlists")).first { it.title == "Gym" }.subtitle)
        assertNull(rig.sel(AutoMixKind.START))
        assertEquals(listOf("two:pocket:p1+playlist:l1:true:true"), rig.facade.calls)
    }

    @Test fun deckBBlank_startsSingleCrate_andZeroStartExplains() {
        val rig = Rig()
        rig.facade.startCount = 0
        rig.sel(AutoMixKind.CRATE, "a", "setlist:s1")
        assertEquals("Downloading — the mix starts when the first track lands", rig.sel(AutoMixKind.START))
        assertEquals(listOf("one:setlist:s1:true:true"), rig.facade.calls)
        rig.facade.autoMixing = false
        // choosing "Same as Deck A" clears a previously chosen Deck B
        rig.sel(AutoMixKind.CRATE, "b", "playlist:l1")
        rig.sel(AutoMixKind.CRATE, "b", "")
        assertEquals("Same as Deck A", rig.kids()[1].subtitle)
    }

    @Test fun startFailureSurfacesTheShellMessage() {
        val rig = Rig()
        rig.facade.failure = ShellActionException.NoBurnedSongs("Warmup")
        rig.sel(AutoMixKind.CRATE, "a", "pocket:p1")
        val e = runCatching { rig.sel(AutoMixKind.START) }.exceptionOrNull()
        assertTrue(e is AutoPlayException)
        assertTrue(e!!.message!!.contains("Burn it first"))
    }

    @Test fun liveSection_statusRowAndControls() {
        val rig = Rig()
        rig.facade.autoMixing = true
        rig.extras.live = AutoMixLive("Song", "Artist", 3, 12, "Deck A")
        val k = rig.kids()
        assertEquals(
            listOf("Song — Artist", "🔀 New Mix", "⏸ Pause Mix", "⏭ Skip — quick", "⏭ Skip — long blend", "⏹ Stop Mix", "Jukebox"),
            k.map { it.title },
        )
        assertEquals("3 / 12 · Deck A", k[0].subtitle)
        assertTrue(k[0].playable)
        assertEquals("5 second sweep", k[3].subtitle)
        assertEquals("15 second crossfade", k[4].subtitle)
        rig.facade.autoPaused = true
        assertEquals("▶ Resume Mix", rig.kids()[2].title)
        assertEquals("Paused · 3 / 12 · Deck A", rig.kids()[0].subtitle)
    }

    @Test fun statusText_variants() {
        assertEquals("Playing", AutoMixTab.statusText(null, false))
        assertEquals("Buffering… · 1 / 4", AutoMixTab.statusText(AutoMixLive(position = 1, count = 4, buffering = true), false))
        assertEquals("Paused", AutoMixTab.statusText(null, true))
        assertEquals("Auto DJ", AutoMixTab.statusTitle(AutoMixLive()))
        assertEquals("T", AutoMixTab.statusTitle(AutoMixLive(title = "T")))
    }

    @Test fun liveActions_decideAtTapTime() {
        val rig = Rig()
        rig.facade.autoMixing = true
        rig.facade.autoPaused = false
        rig.sel(AutoMixKind.TOGGLE)
        rig.sel(AutoMixKind.TOGGLE)
        rig.sel(AutoMixKind.SKIP_FAST)
        rig.sel(AutoMixKind.SKIP_SLOW)
        rig.sel(AutoMixKind.STOP)
        rig.sel(AutoMixKind.NEW_MIX)
        assertEquals(listOf("pause", "resume"), rig.facade.calls)
        assertEquals(listOf("fast", "slow", "stop", "stop"), rig.extras.calls)
        // nothing running: toggle/skip are inert
        rig.facade.autoMixing = false
        rig.sel(AutoMixKind.TOGGLE); rig.sel(AutoMixKind.SKIP_FAST)
        assertEquals(2, rig.facade.calls.size)
        assertEquals(4, rig.extras.calls.size)
    }

    @Test fun facadeChanges_notifyTheMixRootWithRealCount() {
        val rig = Rig()
        rig.extras.flow.tryEmit("a")
        assertEquals("mix:root::" , rig.notified.last().first)
        assertEquals(4, rig.notified.last().second)
        rig.facade.autoMixing = true
        rig.extras.live = AutoMixLive("S", "A")
        rig.extras.flow.tryEmit("b")
        assertEquals(7, rig.notified.last().second)
        val n = rig.notified.size
        rig.extras.flow.tryEmit("b") // duplicate signature filtered
        assertEquals(n, rig.notified.size)
    }

    @Test fun jukebox_listsSessionsWithUrlChild() {
        val rig = Rig()
        rig.extras.sessions = listOf(
            AutoJukeSession("abc", "Pool Party", false, "https://jukebox.pocket-dj.com/abc/"),
            AutoJukeSession("def", "Forever", true, "https://jukebox.pocket-dj.com/def/"),
        )
        val juke = rig.mixId(AutoMixKind.JUKEBOX)
        // Unconfined scope: the fetch completes inside the first call, which then notifies.
        val rows = rig.kids(juke)
        assertEquals("mix:juke::", rig.notified.last().first)
        assertEquals(2, rig.notified.last().second)
        assertEquals(listOf("Pool Party", "Forever"), rows.map { it.title })
        assertEquals(listOf("Live", "Timeless"), rows.map { it.subtitle })
        assertTrue(rows.all { it.browsable })
        val url = rig.kids(rig.mixId(AutoMixKind.SESSION, "abc"))
        assertEquals("https://jukebox.pocket-dj.com/abc/", url.single().title)
        assertFalse(url.single().playable)
    }

    @Test fun jukebox_showsLoadingRowWhileTheFetchIsInFlight() {
        val rig = Rig()
        val gate = kotlinx.coroutines.CompletableDeferred<List<AutoJukeSession>?>()
        val slow = object : AutoMixExtras by rig.extras {
            override suspend fun jukeboxSessions() = gate.await()
        }
        val tab = AutoMixTab(rig.facade, slow) { rig.now }
        val seen = mutableListOf<Pair<String, Int>>()
        tab.bind(CoroutineScope(Dispatchers.Unconfined)) { p, n -> seen += p to n }
        val juke = AutoId.Mix(AutoMixKind.JUKEBOX)
        assertEquals(listOf("Loading…"), tab.children(juke)!!.map { it.title })
        assertEquals(listOf("Loading…"), tab.children(juke)!!.map { it.title })
        gate.complete(listOf(AutoJukeSession("x", "Room", false, "https://j/x/")))
        assertEquals(listOf("Room"), tab.children(juke)!!.map { it.title })
        assertEquals("mix:juke::", seen.last().first)
    }

    @Test fun jukebox_unreachableAndEmptyMessages_andThrottle() {
        val rig = Rig()
        val juke = rig.mixId(AutoMixKind.JUKEBOX)
        rig.extras.sessions = null
        rig.kids(juke)
        assertEquals(AutoMixTab.JUKE_UNREACHABLE, rig.kids(juke).single().title)
        assertEquals(1, rig.extras.sessionCalls) // second open inside the throttle window did not refetch
        rig.now += AutoMixTab.JUKE_REFRESH_MS + 1
        rig.extras.sessions = emptyList()
        rig.kids(juke) // triggers refresh
        assertEquals(2, rig.extras.sessionCalls)
        assertEquals(AutoMixTab.JUKE_NONE, rig.kids(juke).single().title)
    }

    @Test fun idCodec_roundTripsAwkwardPayloads() {
        val id = AutoId.Mix(AutoMixKind.CRATE, "a", "pocket:we ird/id%")
        assertEquals(id, AutoId.decode(id.encoded))
        assertNull(AutoId.decode("mix:bogus::"))
        assertNull(AutoId.decode("mix:crate:a"))
    }

    @Test fun callbackSelect_routesMixRows_andToastsOutcome() {
        val rig = Rig()
        val toasts = mutableListOf<String>()
        val cb = AutoLibraryCallback(
            tree = tree(rig), addTargets = AutoAddTargets(object : AutoAddSink {
                override fun pockets() = emptyList<AutoTarget>()
                override fun playlists() = emptyList<AutoTarget>()
                override fun add(songId: String, kind: AutoTargetKind, targetId: String) = false
            }),
            player = object : AutoPlayer {
                override suspend fun playCollection(ref: AutoCollectionRef, shuffle: Boolean) {}
                override suspend fun playSong(ref: AutoCollectionRef, songId: String) {}
                override suspend fun playSolo(songId: String) {}
                override suspend fun resumeHeld() {}
            },
            scope = CoroutineScope(Dispatchers.Unconfined), toast = { toasts += it }, notifyChildrenChanged = { _, _ -> },
        )
        assertTrue(cb.isOurs(AutoId.Mix(AutoMixKind.START).encoded))
        cb.select(AutoId.Mix(AutoMixKind.START).encoded)
        assertEquals(listOf("Pick Deck A first"), toasts)
        cb.select(AutoId.Mix(AutoMixKind.CRATE, "a", "pocket:p1").encoded)
        assertEquals("Deck A: Warmup", toasts.last())
        assertEquals(1, rig.tab.let { if (it.deckA != null) 1 else 0 })
    }
}
