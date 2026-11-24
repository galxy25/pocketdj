package com.levi.pocketdj.shell

import com.levi.pocketdj.assistant.ShortcutCandidate
import com.levi.pocketdj.assistant.ShortcutRanking
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.NOW_PLAYING_PLAYLIST_ID
import com.levi.pocketdj.data.collections.PlaylistNode
import com.levi.pocketdj.playback.QueueOutcome
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class AddToCollectionActionTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun store() = CollectionsStore(java.io.File(tmp.root, CollectionsStore.FILE_NAME), now = { 1_750_000_000_000.0 })

    private fun expectThrows(msg: String, block: () -> Unit) {
        try { block(); fail("expected: $msg") } catch (e: ShellActionException) { assertEquals(msg, e.message) }
    }

    @Test
    fun pocketGetsMembership_andActivityFires() {
        val s = store()
        val hooks = mutableListOf<CollectionsStore.ActivityHook>()
        s.onActivity = { hooks += it }
        val p = s.createPocket("Warmup")
        val r = AddToCollectionAction(s).add("s1", "Song One", "pocket:${p.id}")
        assertEquals(AddToCollectionResult("Song One", "Warmup", alreadyMember = false), r)
        assertEquals("Added Song One to Warmup.", r.dialog)
        assertEquals(listOf("s1"), s.pocket(p.id)!!.songIds)
        assertEquals(1, hooks.size) // History > Activity saw a normal add
        assertEquals(p.id, s.state.value.recentAddTargets.first().id) // the Recent row too
    }

    @Test
    fun playlistLandsInTheFirstChapter_notTheLast() {
        val s = store()
        val pl = s.createPlaylist("Road")
        s.addSequence("Second", pl.id)
        val first = s.playlist(pl.id)!!.sequences.first()
        val second = s.playlist(pl.id)!!.sequences.last()
        assertTrue(first.nodeId != second.nodeId)
        val r = AddToCollectionAction(s).add("s1", "Song One", "playlist:${pl.id}")
        assertEquals(false, r.alreadyMember)
        val after = s.playlist(pl.id)!!.sequences
        assertEquals(listOf("s1"), after.first().children.orEmpty().filter { it.kind == PlaylistNode.Kind.SONG }.map { it.songId })
        assertTrue(after.last().children.orEmpty().isEmpty())
    }

    @Test
    fun existingMemberIsNeverToggledOff() {
        val s = store()
        val p = s.createPocket("Warmup", listOf("s1"))
        val pl = s.createPlaylist("Road", listOf("s1"))
        val action = AddToCollectionAction(s)
        val a = action.add("s1", "Song One", "pocket:${p.id}")
        assertEquals("Song One is already in Warmup.", a.dialog)
        assertEquals(listOf("s1"), s.pocket(p.id)!!.songIds)
        val b = action.add("s1", "Song One", "playlist:${pl.id}")
        assertEquals("Song One is already in Road.", b.dialog)
        assertEquals(1, s.playlist(pl.id)!!.sequences.first().children!!.size)
    }

    @Test
    fun nestedChapterMemberCountsAsAlreadyIn() {
        val s = store()
        val pl = s.createPlaylist("Road")
        s.addSong("s9", AddTarget(AddTarget.Kind.PLAYLIST, pl.id, pl.sequences.first().nodeId))
        assertTrue(AddToCollectionAction(s).add("s9", "Nine", "playlist:${pl.id}").alreadyMember)
    }

    @Test
    fun reservedNowPlayingPlaylistUnknownAndMalformedIdsAreNotTargets() {
        val s = store()
        val notFound = "I couldn't find that pocket or playlist in PocketDJ."
        val action = AddToCollectionAction(s)
        expectThrows(notFound) { action.add("s1", "t", "playlist:$NOW_PLAYING_PLAYLIST_ID") }
        expectThrows(notFound) { action.add("s1", "t", "pocket:gone") }
        expectThrows(notFound) { action.add("s1", "t", "playlist:gone") }
        expectThrows(notFound) { action.add("s1", "t", "setlist:abc") }
        expectThrows(notFound) { action.add("s1", "t", "pocket:") }
        expectThrows(notFound) { action.add("s1", "t", "garbage") }
    }

    @Test
    fun collectionRef_roundTrips() {
        val t = AddTarget(AddTarget.Kind.PLAYLIST, "pls_1")
        assertEquals(t, CollectionRef.target(CollectionRef.encode(t)))
        assertEquals(AddTarget(AddTarget.Kind.POCKET, "a:b"), CollectionRef.target("pocket:a:b"))
        assertNull(CollectionRef.target(""))
    }

    @Test
    fun audibleOwner_mixWinsOnlyWhenItOwnsAudio() {
        // Mix owns the audio, parked Now Playing row loses.
        assertEquals("mix", AudibleOwner.songId(sequencerRunning = false, mixActive = true, mixSongId = "mix", sequencerSongId = "np"))
        assertEquals("mix", AudibleOwner.songId(sequencerRunning = true, mixActive = true, mixSongId = "mix", sequencerSongId = "np"))
        // Now Playing playing or paused, Mix idle.
        assertEquals("np", AudibleOwner.songId(sequencerRunning = true, mixActive = false, mixSongId = null, sequencerSongId = "np"))
        assertEquals("np", AudibleOwner.songId(sequencerRunning = false, mixActive = false, mixSongId = "stale", sequencerSongId = "np"))
        // Mix active but its deck is empty: fall back to the sequencer row; nothing anywhere -> null.
        assertEquals("np", AudibleOwner.songId(sequencerRunning = false, mixActive = true, mixSongId = null, sequencerSongId = "np"))
        assertNull(AudibleOwner.songId(false, false, null, null))
    }

    // ---- ShellActions door ----

    private val merged: MergedCatalog = MergedCatalog.merge(
        listOf(
            IndexJson(
                manifest = IndexManifest(sourceName = "Test"),
                songs = listOf(IndexSong(id = "s1", artist = "A", name = "Song One", length = 60_000)),
            ),
        ),
    )

    private fun actions(s: CollectionsStore, incomplete: Boolean = false, audible: String? = null, fallback: Map<String, String> = emptyMap()) =
        ShellActions(
            collections = s,
            catalog = object : ShellCatalog {
                override fun song(id: String) = merged.songsById[id]
                override fun album(id: String) = merged.albumsById[id]
            },
            player = ShellPlayer { _, _ -> QueueOutcome.Started(1, 0, 1) },
            setup = SetupGate { incomplete },
            readiness = object : ReadinessPort {
                override fun kickManifestRefresh() {}
                override fun loadCatalog() {}
                override suspend fun awaitCatalogSeeded() {}
            },
            postRoute = {},
            audibleSongId = { audible },
            fallbackSongTitle = { fallback[it] },
        )

    @Test
    fun addSongToCollection_usesTheAudibleSong_whenNoSongGiven() = runTest {
        val s = store()
        val p = s.createPocket("Warmup")
        val r = actions(s, audible = "s1").addSongToCollection(null, "pocket:${p.id}")
        assertEquals("Added Song One to Warmup.", r.dialog)
        assertEquals(listOf("s1"), s.pocket(p.id)!!.songIds)
    }

    @Test
    fun addSongToCollection_nothingPlayingUnknownSongAndVeto() = runTest {
        val s = store()
        val p = s.createPocket("Warmup")
        try { actions(s).addSongToCollection(null, "pocket:${p.id}"); fail() } catch (e: ShellActionException) {
            assertEquals("Nothing is playing in PocketDJ right now.", e.message)
        }
        try { actions(s).addSongToCollection("ghost", "pocket:${p.id}"); fail() } catch (e: ShellActionException) {
            assertEquals("I couldn't find that song in your PocketDJ sources.", e.message)
        }
        // A studio / queue-only track resolves through the fallback title.
        val r = actions(s, fallback = mapOf("smp_1" to "My Sample")).addSongToCollection("smp_1", "pocket:${p.id}")
        assertEquals("Added My Sample to Warmup.", r.dialog)
        try { actions(s, incomplete = true).addSongToCollection("s1", "pocket:${p.id}"); fail() } catch (e: ShellActionException) {
            assertEquals("Finish setting up PocketDJ in the app first.", e.message)
        }
        assertEquals(listOf("smp_1"), s.pocket(p.id)!!.songIds) // the vetoed call wrote nothing
    }

    // ---- doors: deep links / shortcuts / result line ----

    @Test
    fun deepLink_add_parsesCollectionAndOptionalSong() {
        assertEquals(
            DeepLink.AddToCollection("pocket:abc", null),
            DeepLinkParser.parse("pocketdj://add?collection=pocket:abc"),
        )
        assertEquals(
            DeepLink.AddToCollection("playlist:pls_1", "sng_9"),
            DeepLinkParser.parse("pocketdj://add?collection=playlist%3Apls_1&song=sng_9"),
        )
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://add"))
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://add?collection=setlist:x"))
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://add?collection=nonsense"))
    }

    @Test
    fun deepLink_automix_parsesKindIdAndShuffle() {
        assertEquals(DeepLink.AutoMix(MixSource.Pocket("p1"), false), DeepLinkParser.parse("pocketdj://automix/pocket/p1"))
        assertEquals(DeepLink.AutoMix(MixSource.Playlist("pls_1"), true), DeepLinkParser.parse("pocketdj://automix/playlist/pls_1?shuffle=1"))
        assertEquals(DeepLink.AutoMix(MixSource.Setlist("st"), false), DeepLinkParser.parse("pocketdj:///automix/setlist/st"))
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://automix/album/x"))
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://automix/pocket"))
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://automix"))
    }

    @Test
    fun autoMixLine_matchesTheIosDialog() {
        assertEquals("Auto-mixing Warmup — 12 burned songs.", autoMixLine("Warmup", 12, false))
        assertEquals("Auto-mixing Warmup, shuffled — 1 burned song.", autoMixLine("Warmup", 1, true))
    }

    @Test
    fun linkSeams_toastTheResult_andTheErrors() = runTest {
        val s = store()
        val p = s.createPocket("Warmup")
        val toasts = mutableListOf<String>()
        val jobs = mutableListOf<kotlinx.coroutines.Job>()
        val a = actions(s, audible = "s1")
        val add = addLinkSeam(a, this, { toasts += it }, { jobs += it })
        add("pocket:${p.id}", null)
        add("pocket:${p.id}", null)
        add("pocket:gone", null)
        jobs.forEach { it.join() }
        assertEquals(
            listOf(
                "Added Song One to Warmup.",
                "Song One is already in Warmup.",
                "I couldn't find that pocket or playlist in PocketDJ.",
            ),
            toasts,
        )
        // No Mix facade assigned: the auto-mix door says so instead of dropping the link.
        toasts.clear(); jobs.clear()
        autoMixLinkSeam(a, this, { toasts += it }, { jobs += it })(MixSource.Pocket(p.id), false)
        jobs.forEach { it.join() }
        assertEquals(listOf("Auto-Mix isn't available yet"), toasts)
    }

    @Test
    fun autoMixLinkSeam_startsTheMix_andReportsBurnedCount() = runTest {
        val s = store()
        val p = s.createPocket("Warmup", listOf("s1"))
        val a = actions(s, audible = "s1")
        val started = mutableListOf<Pair<MixSource, Boolean>>()
        a.mixFacade = object : MixFacade {
            override val autoMixing = false
            override val autoPaused = false
            override suspend fun startAutoMix(source: MixSource, shuffle: Boolean, allowPendingStart: Boolean): MixStartResult {
                started += source to shuffle
                return MixStartResult("Warmup", 3)
            }
            override suspend fun startAutoMix(deckA: MixSource, deckB: MixSource, shuffle: Boolean, allowPendingStart: Boolean) =
                MixStartResult("x", 0)
            override fun pauseAutoMix() {}
            override fun resumeAutoMix() {}
        }
        val toasts = mutableListOf<String>()
        val jobs = mutableListOf<kotlinx.coroutines.Job>()
        autoMixLinkSeam(a, this, { toasts += it }, { jobs += it })(MixSource.Pocket(p.id), true)
        jobs.forEach { it.join() }
        assertEquals(listOf(MixSource.Pocket(p.id) to true), started)
        assertEquals(listOf("Auto-mixing Warmup, shuffled — 3 burned songs."), toasts)
    }

    @Test
    fun dispatcherRoutesTheNewLinks_throughTheSeams() {
        val msgs = mutableListOf<String>()
        val seams = DeepLinkSeams()
        val d = DeepLinkDispatcher(
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined),
            gate = object : OnboardingGate {
                override val isComplete = true
                override suspend fun waitUntilComplete() {}
            },
            seams = seams,
            postRoute = {},
            postMessage = { msgs += it },
        )
        // Seams unwired: honest message, never a silent drop.
        assertTrue(d.handle(DeepLink.AddToCollection("pocket:a", null)))
        assertTrue(d.handle(DeepLink.AutoMix(MixSource.Pocket("a"), false)))
        assertEquals(listOf("Adding from links isn't available yet", "Auto-Mix isn't available yet"), msgs)
        val calls = mutableListOf<String>()
        seams.addToCollection = { c, song -> calls += "add $c $song" }
        seams.autoMix = { src, sh -> calls += "mix $src $sh" }
        d.handle(DeepLink.AddToCollection("pocket:a", "s1"))
        d.handle(DeepLink.AutoMix(MixSource.Setlist("z"), true))
        assertEquals(listOf("add pocket:a s1", "mix Setlist(id=z) true"), calls)
    }

    @Test
    fun autoMixShortcut_takesOneSlot_forTheLastPlayedCrate() {
        val c = listOf(
            ShortcutCandidate(PlayKind.Pocket, "p1", "Warmup", 100.0),
            ShortcutCandidate(PlayKind.Playlist, "pls_2", "A Very Long Playlist Name Indeed", 200.0),
            ShortcutCandidate(PlayKind.Playlist, "pls_3", "Never", null),
        )
        val all = ShortcutRanking.selectWithAutoMix(c, 3)
        assertEquals(3, all.size)
        assertEquals(ShortcutRanking.AUTO_MIX_ID, all[0].id)
        assertEquals("pocketdj://automix/playlist/pls_2", all[0].uri)
        assertEquals(25, all[0].label.length)
        assertEquals(listOf("play_playlist_pls_2", "play_pocket_p1"), all.drop(1).map { it.id })
        assertEquals(listOf(0, 1, 2), all.map { it.rank })
        // Cap 1: only the auto-mix shortcut; nothing played: none at all; cap 0: none.
        assertEquals(listOf(ShortcutRanking.AUTO_MIX_ID), ShortcutRanking.selectWithAutoMix(c, 1).map { it.id })
        assertEquals(emptyList<Any>(), ShortcutRanking.selectWithAutoMix(emptyList(), 3))
        assertEquals(emptyList<Any>(), ShortcutRanking.selectWithAutoMix(c, 0))
        // The generated link round-trips through the parser.
        assertEquals(DeepLink.AutoMix(MixSource.Playlist("pls_2"), false), DeepLinkParser.parse(all[0].uri))
    }
}
