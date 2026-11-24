package com.levi.pocketdj.auto

import com.levi.pocketdj.assistant.MediaCandidate
import com.levi.pocketdj.assistant.MediaFocus
import com.levi.pocketdj.assistant.MediaPlayActions
import com.levi.pocketdj.assistant.MediaSearchHandler
import com.levi.pocketdj.assistant.MediaSearchRequest
import com.levi.pocketdj.assistant.MediaSearchResolver
import com.levi.pocketdj.assistant.MediaSearchResult
import com.levi.pocketdj.assistant.ShortcutManagerSink
import com.levi.pocketdj.assistant.ShortcutRanking
import com.levi.pocketdj.data.pockets.wheel.PocketBestMatch
import com.levi.pocketdj.data.pockets.wheel.PocketMode
import com.levi.pocketdj.data.pockets.wheel.PocketMoment
import com.levi.pocketdj.data.pockets.wheel.PocketMomentKey
import com.levi.pocketdj.data.pockets.wheel.PocketProfile
import com.levi.pocketdj.data.pockets.wheel.PocketWheelSnapshot
import com.levi.pocketdj.shell.DeepLink
import com.levi.pocketdj.shell.DeepLinkParser
import com.levi.pocketdj.shell.ShellActionException
import com.levi.pocketdj.shell.ShellRoute
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class AutoPocketsTest {
    private val names = mapOf("pl1" to "Potential", "pl2" to "Focus")
    private val tue8 = PocketMomentKey(8, 2, PocketMode.CAR_PLAY)
    private val tue9 = PocketMomentKey(9, 2, PocketMode.RUNNING)

    private fun profile(key: PocketMomentKey? = tue8, tier: PocketProfile.Tier = PocketProfile.Tier.RICH, colls: Map<String, Double> = mapOf("pl1" to 1.0)) =
        PocketProfile(tier = tier, key = key, caption = key?.shortLabel ?: "Getting to know you", detail = "d", collections = colls)

    private fun moment(k: PocketMomentKey, plays: Int = 4, dom: String? = "pl1") =
        PocketMoment(key = k, plays = plays.toDouble(), directPlays = plays, collections = mapOf("pl1" to 1.0), dominantCollectionId = dom)

    private class Src(
        var best: PocketBestMatch.Result?,
        var moments: List<PocketMoment>,
        val names: Map<String, String>,
    ) : AutoPocketsSource {
        var refreshes = 0
        override fun best() = best
        override fun momentsNow(count: Int) = moments.take(count)
        override fun collectionNames() = names
        override suspend fun refresh() { refreshes++ }
    }

    private fun result(p: PocketProfile) = PocketBestMatch.Result(p, null, emptyList())
    private fun src(p: PocketProfile? = profile(), moments: List<PocketMoment> = listOf(moment(tue8), moment(tue9, 2))) =
        Src(p?.let(::result), moments, names)

    // Tree nodes

    @Test fun nowRow_isPlayableWithCollectionAndWhenSubtitle() {
        val n = AutoPockets(src()).nowRow()!!
        assertEquals("pocketwheel:now", n.id)
        assertEquals("▶ Pocket for now", n.title)
        assertEquals("Potential · Tue 8 AM", n.subtitle)
        assertTrue(n.playable)
        assertFalse(n.browsable)
    }

    @Test fun nowRow_blendedProfileFallsBackToCaption_andUnnamedCollectionIsOmitted() {
        val blended = profile(key = null, tier = PocketProfile.Tier.HISTORY, colls = mapOf("gone" to 1.0))
        assertEquals("Getting to know you", AutoPockets(src(blended)).nowRow()!!.subtitle)
    }

    @Test fun nowRow_absentWhenNoAnswerOrTrulyEmpty() {
        assertNull(AutoPockets(src(null)).nowRow())
        assertNull(AutoPockets(src(profile(null, PocketProfile.Tier.EMPTY, emptyMap()))).nowRow())
        // An EMPTY-tier fallback that still carries a collection (favorites) is offered.
        assertEquals("pocketwheel:now", AutoPockets(src(profile(null, PocketProfile.Tier.EMPTY, mapOf("pl1" to 1.0)))).nowRow()!!.id)
    }

    @Test fun listRow_isBrowsable_andHiddenWithNoMoments() {
        val row = AutoPockets(src()).listRow()!!
        assertEquals("pocketwheel:list", row.id)
        assertEquals("Pockets right now", row.title)
        assertTrue(row.browsable)
        assertEquals("2 moments", row.subtitle)
        assertNull(AutoPockets(src(moments = emptyList())).listRow())
    }

    @Test fun listChildren_areTopFiveMomentsWithPlayableTokenIds() {
        val keys = (1..7).map { PocketMomentKey(it, 2, PocketMode.CAR_PLAY) }
        val kids = AutoPockets(src(moments = keys.map { moment(it) })).listChildren()
        assertEquals(5, kids.size)
        assertEquals("pocketwheel:m:h01|d2|carPlay", kids[0].id)
        assertEquals("Tue 1 AM · CarPlay", kids[0].title)
        assertEquals("Potential · 4 plays", kids[0].subtitle)
        assertTrue(kids.all { it.playable && !it.browsable })
        assertEquals("1 play", AutoPockets(src(moments = listOf(moment(tue8, 1)))).listChildren()[0].subtitle!!.substringAfter("· "))
    }

    @Test fun emptyListShowsOneNoteRow_neverNothing() {
        val kids = AutoPockets(src(moments = emptyList())).listChildren()
        assertEquals(1, kids.size)
        assertFalse(kids[0].playable)
    }

    @Test fun ids_roundTripThroughTheCodec() {
        assertEquals(AutoId.PocketNow, AutoId.decode("pocketwheel:now"))
        assertEquals(AutoId.PocketList, AutoId.decode("pocketwheel:list"))
        assertEquals(AutoId.PocketMoment(tue8), AutoId.decode(AutoId.PocketMoment(tue8).encoded))
        assertNull(AutoId.decode("pocketwheel:m:garbage"))
        assertNull(AutoId.decode("pocketwheel:m:h99|d2|carPlay"))
        assertNull(AutoId.decode("pocketwheel:other"))
        assertNull(AutoId.decode("pocketwheel"))
    }

    @Test fun plan_resolvesNowAndMomentOnly() {
        val p = AutoPockets(src())
        assertEquals(AutoPocketPlay.ForNow, p.plan(AutoId.PocketNow))
        assertEquals(AutoPocketPlay.Moment(tue9), p.plan(AutoId.PocketMoment(tue9)))
        assertNull(p.plan(AutoId.PocketList))
        assertNull(p.plan(AutoId.Root))
    }

    @Test fun item_resolvesOnlyCurrentMoments() {
        val p = AutoPockets(src())
        assertEquals("▶ Pocket for now", p.item(AutoId.PocketNow)!!.title)
        assertEquals("Tue 8 AM · CarPlay", p.item(AutoId.PocketMoment(tue8))!!.title)
        assertNull(p.item(AutoId.PocketMoment(PocketMomentKey(3, 3, PocketMode.TRIP))))
    }

    // Wiring into the For You tab

    private fun tree(pockets: AutoPockets?) = AutoBrowseTree(FakeAutoData(), pockets = pockets)

    @Test fun forYouTab_putsPocketRowsFirst_inThePhoneSectionOrder() {
        val t = tree(AutoPockets(src()))
        val kids = t.children(AutoId.Tab(AutoId.Tab.Which.FOR_YOU).encoded)!!
        assertEquals(listOf("pocketwheel:now", "pocketwheel:list"), kids.map { it.id })
        assertTrue(t.children("root")!!.any { it.id == "tab:foryou" })
        assertEquals("Tue 8 AM · CarPlay", t.item("pocketwheel:m:h08|d2|carPlay")?.title)
        assertEquals("▶ Pocket for now", t.item("pocketwheel:now")!!.title)
        assertEquals(2, t.children("pocketwheel:list")!!.size)
    }

    @Test fun withoutPockets_theTreeIsUnchanged() {
        val t = tree(null)
        assertFalse(t.children("root")!!.any { it.id == "tab:foryou" })
        assertNull(t.item("pocketwheel:now"))
        assertNull(t.children("pocketwheel:list"))
    }

    // Callback: select, refresh on root, failure

    private class Player : AutoPlayer {
        val calls = mutableListOf<String>()
        var fail: String? = null
        override suspend fun playCollection(ref: AutoCollectionRef, shuffle: Boolean) {}
        override suspend fun playSong(ref: AutoCollectionRef, songId: String) {}
        override suspend fun playSolo(songId: String) {}
        override suspend fun resumeHeld() {}
        override suspend fun playPocketForNow() { fail?.let { throw AutoPlayException(it) }; calls += "now" }
        override suspend fun playPocketMoment(key: PocketMomentKey) { fail?.let { throw AutoPlayException(it) }; calls += "m:${key.token}" }
    }

    private class Rig(val src: Src, val player: Player = Player()) {
        val toasts = mutableListOf<String>()
        val carErrors = mutableListOf<String>()
        val notified = mutableListOf<String>()
        val cb = AutoLibraryCallback(
            tree = AutoBrowseTree(FakeAutoData(), pockets = AutoPockets(src)),
            addTargets = AutoAddTargets(object : AutoAddSink {
                override fun pockets() = emptyList<AutoTarget>()
                override fun playlists() = emptyList<AutoTarget>()
                override fun add(songId: String, kind: AutoTargetKind, targetId: String) = false
            }),
            player = player,
            scope = CoroutineScope(Dispatchers.Unconfined),
            toast = { toasts += it },
            notifyChildrenChanged = { p, _ -> notified += p },
            carError = { carErrors += it },
            refreshPockets = { src.refresh() },
        )
    }

    @Test fun selectingTheRowsPlaysThroughThePlayer() = runBlocking {
        val r = Rig(src())
        r.cb.select("pocketwheel:now")!!.join()
        r.cb.select(AutoId.PocketMoment(tue9).encoded)!!.join()
        assertEquals(listOf("now", "m:h09|d2|running"), r.player.calls)
        assertTrue(r.toasts.isEmpty())
    }

    @Test fun aFailedPlayIsSpokenToTheCar_neverAnEmptyPlayer() = runBlocking {
        val msg = "Not enough playable songs fit your pocket right now. Download some, or connect Apple Music."
        val r = Rig(src(), Player().also { it.fail = msg })
        r.cb.select("pocketwheel:now")!!.join()
        r.cb.select(AutoId.PocketMoment(tue8).encoded)!!.join()
        assertTrue(r.player.calls.isEmpty())
        assertEquals(listOf(msg, msg), r.toasts)
        assertEquals(listOf(msg, msg), r.carErrors)
    }

    @Test fun theFolderRowIsBrowseOnly() = runBlocking {
        val r = Rig(src())
        r.cb.select("pocketwheel:list")!!.join()
        assertTrue(r.player.calls.isEmpty())
        assertTrue(r.toasts.isEmpty())
    }

    @Test fun rootFetchRefreshesTheWheelAndRenotifiesOnlyOnARealChange() = runBlocking {
        val s = src()
        val r = Rig(s)
        r.cb.onCatalogReady()
        r.notified.clear()
        r.cb.onConnect()
        assertEquals(1, s.refreshes)
        assertTrue("first answer re-notifies For You", "tab:foryou" in r.notified)
        r.notified.clear()
        r.cb.onConnect()
        assertEquals(2, s.refreshes)
        assertTrue("unchanged rows are not re-notified", r.notified.isEmpty())
        s.best = result(profile(PocketMomentKey(9, 2, PocketMode.CAR_PLAY)))
        r.cb.onConnect()
        assertTrue(r.notified.isNotEmpty())
    }

    @Test fun aThrowingRefreshKeepsTheOldAnswerAndNeverCrashesTheRoot() = runBlocking {
        val s = src()
        val tree = AutoBrowseTree(FakeAutoData(), pockets = AutoPockets(s))
        val cb = AutoLibraryCallback(
            tree = tree, addTargets = AutoAddTargets(object : AutoAddSink {
                override fun pockets() = emptyList<AutoTarget>()
                override fun playlists() = emptyList<AutoTarget>()
                override fun add(songId: String, kind: AutoTargetKind, targetId: String) = false
            }),
            player = Player(), scope = CoroutineScope(Dispatchers.Unconfined), toast = {}, notifyChildrenChanged = { _, _ -> },
            refreshPockets = { error("boom") },
        )
        assertEquals("root", cb.onConnect().id)
        assertEquals("pocketwheel:now", tree.children("tab:foryou")!!.first().id)
    }

    // Voice phrase door

    private fun resolve(q: String, focus: MediaFocus = MediaFocus.Any, pool: List<MediaCandidate> = emptyList()) =
        MediaSearchResolver.resolve(MediaSearchRequest(q, focus)) { k -> pool.filter { it.kind in k } }

    @Test fun phrases_mapToPocketForNow_ahead_ofACollectionNamedTheSame() {
        val pool = listOf(MediaCandidate(MediaCandidate.Kind.Pocket, "p", "My Pocket"))
        for (q in listOf("my pocket", "play my pocket", "Play my pocket on PocketDJ", "pocket for now", "play the pocket for now please", "something that fits", "My Pocket!")) {
            assertEquals(q, MediaSearchResult.PocketForNow, resolve(q, pool = pool))
        }
        assertEquals(MediaSearchResult.PocketForNow, resolve("my pocket", MediaFocus.Playlist))
    }

    @Test fun otherPocketQueriesAreNotHijacked() {
        assertFalse(resolve("my pocket of sunshine") is MediaSearchResult.PocketForNow)
        assertFalse(resolve("warmup pocket") is MediaSearchResult.PocketForNow)
        assertFalse(resolve("my pocket", MediaFocus.Song) is MediaSearchResult.PocketForNow)
        assertFalse(resolve("my pocket", MediaFocus.Artist) is MediaSearchResult.PocketForNow)
    }

    private class VoiceActions : MediaPlayActions {
        var fail: ShellActionException? = null
        var pocketCalls = 0
        override suspend fun playPlaylist(id: String, shuffle: Boolean) = ""
        override suspend fun playPocket(id: String, shuffle: Boolean) = ""
        override suspend fun playAlbum(id: String, shuffle: Boolean) = ""
        override suspend fun playSong(id: String) = ""
        override suspend fun playPocketForNow(): String { fail?.let { throw it }; pocketCalls++; return "Potential, Tue 8 AM · CarPlay" }
    }

    @Test fun handler_playsThePocket_andSnackbarsTheCaption_orTheFailure() = runBlocking {
        val a = VoiceActions()
        val msgs = mutableListOf<String>()
        val routes = mutableListOf<ShellRoute>()
        val h = MediaSearchHandler(a, { emptyList() }, { routes += it }, { msgs += it })
        assertEquals("Potential, Tue 8 AM · CarPlay", h.handle(MediaSearchRequest("my pocket")))
        assertEquals(listOf("Playing your pocket: Potential, Tue 8 AM · CarPlay."), msgs)
        a.fail = ShellActionException.NoPocketFits
        assertNull(h.handle(MediaSearchRequest("pocket for now")))
        assertTrue(msgs.last().startsWith("Not enough playable songs fit your pocket right now"))
        assertEquals(1, a.pocketCalls)
        assertTrue(routes.isEmpty())
    }

    // Deep link + static shortcut

    @Test fun deepLink_pocketNow_parses_andRealPocketIdsStillNavigate() {
        assertEquals(DeepLink.PocketNow, DeepLinkParser.parse("pocketdj://pocket/now"))
        assertEquals(DeepLink.PocketNow, DeepLinkParser.parse("pocketdj:///pocket/NOW"))
        assertEquals(DeepLink.Navigate(ShellRoute.Pocket("abc")), DeepLinkParser.parse("pocketdj://pocket/abc"))
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://pocket"))
    }

    @Test fun staticShortcutsXml_staysInSyncWithStaticCount_andCarriesThePocketLink() {
        val xml = File("src/main/res/xml/shortcuts.xml").readText()
        val shortcuts = Regex("<shortcut\\b").findAll(xml).count()
        assertEquals("keep ShortcutManagerSink.STATIC_COUNT equal to the XML entries", ShortcutManagerSink.STATIC_COUNT, shortcuts)
        assertTrue(xml.contains("android:shortcutId=\"play_pocket_now\""))
        assertTrue(xml.contains("android:data=\"${ShortcutRanking.POCKET_NOW_LINK}\""))
    }

    @Test fun autoSessionTrackerCountsConnectedControllers() {
        com.levi.pocketdj.auto.AutoSessionTracker.reset()
        val a = Any(); val b = Any()
        assertFalse(com.levi.pocketdj.auto.AutoSessionTracker.isActive)
        com.levi.pocketdj.auto.AutoSessionTracker.connected(a)
        com.levi.pocketdj.auto.AutoSessionTracker.connected(b)
        com.levi.pocketdj.auto.AutoSessionTracker.disconnected(a)
        assertTrue(com.levi.pocketdj.auto.AutoSessionTracker.isActive)
        com.levi.pocketdj.auto.AutoSessionTracker.disconnected(b)
        assertFalse(com.levi.pocketdj.auto.AutoSessionTracker.isActive)
    }
}
