package com.levi.pocketdj.screens.jukebox

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.navigation.PocketDjDestination
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.remote.InMemoryRemoteTarget
import com.levi.pocketdj.remote.RemoteSessionController
import com.levi.pocketdj.remote.RemoteSessionMode
import com.levi.pocketdj.remote.RemoteShowcaseSeed
import com.levi.pocketdj.remote.RemoteSongResolver
import com.levi.pocketdj.shell.DeepLink
import com.levi.pocketdj.shell.DeepLinkParser
import com.levi.pocketdj.shell.JukeboxPanelMode
import com.levi.pocketdj.shell.JukeboxPanelModeStore
import com.levi.pocketdj.shell.RemotePanelRequests
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class JukeboxHubModeTest {
    @Test fun rawValuesArePinnedToTheIosStrings() {
        assertEquals("Jukebox Hero", JukeboxPanelMode.HERO.raw)
        assertEquals("Remote", JukeboxPanelMode.REMOTE.raw)
        assertEquals("jukeboxPanelMode", JukeboxPanelModeStore.KEY.name)
    }

    @Test fun rawRoundTripsAndUnknownFallsBackToHero() {
        JukeboxPanelMode.entries.forEach { assertEquals(it, JukeboxPanelMode.fromRaw(it.raw)) }
        assertEquals(JukeboxPanelMode.HERO, JukeboxPanelMode.fromRaw(null))
        assertEquals(JukeboxPanelMode.HERO, JukeboxPanelMode.fromRaw(""))
        assertEquals(JukeboxPanelMode.HERO, JukeboxPanelMode.fromRaw("remote"))
    }

    @Test fun remoteIsOnlyEffectiveWhileTheSurfaceIsAvailable() {
        assertEquals(JukeboxPanelMode.REMOTE, JukeboxPanelModeStore.effective(JukeboxPanelMode.REMOTE, true))
        assertEquals(JukeboxPanelMode.HERO, JukeboxPanelModeStore.effective(JukeboxPanelMode.REMOTE, false))
        assertEquals(JukeboxPanelMode.HERO, JukeboxPanelModeStore.effective(JukeboxPanelMode.HERO, true))
    }

    @Test fun aSessionGoingActiveFlipsToRemoteButEndingLeavesTheChoice() {
        assertEquals(JukeboxPanelMode.REMOTE, JukeboxPanelModeStore.afterSessionChange(JukeboxPanelMode.HERO, true))
        assertEquals(JukeboxPanelMode.REMOTE, JukeboxPanelModeStore.afterSessionChange(JukeboxPanelMode.REMOTE, false))
        assertEquals(JukeboxPanelMode.HERO, JukeboxPanelModeStore.afterSessionChange(JukeboxPanelMode.HERO, false))
    }

    @Test fun theRetiredRemoteTokenMapsToTheJukeboxPanel() {
        assertEquals(PocketDjDestination.Jukebox, PocketDjDestination.fromToken("Remote"))
        assertTrue(PocketDjDestination.isRetiredRemoteToken("Remote"))
        assertFalse(PocketDjDestination.isRetiredRemoteToken("Jukebox Hero"))
        assertEquals(PocketDjDestination.Jukebox, PocketDjDestination.fromToken("Jukebox Hero"))
        assertEquals(PocketDjDestination.default, PocketDjDestination.fromToken("nonsense"))
        // the retired token never becomes a destination of its own
        assertTrue(PocketDjDestination.entries.none { it.token == "Remote" })
    }

    @Test fun remoteLinksParse() {
        assertEquals(DeepLink.Remote(null), DeepLinkParser.parse("pocketdj://remote"))
        assertEquals(DeepLink.Remote(null), DeepLinkParser.parse("pocketdj:///remote"))
        assertEquals(DeepLink.Remote("K7QM2X"), DeepLinkParser.parse("pocketdj://remote/join/K7QM2X"))
        assertEquals(DeepLink.Remote("k7qm2x"), DeepLinkParser.parse("pocketdj://REMOTE/JOIN/k7qm2x"))
        assertEquals(DeepLink.Remote(null), DeepLinkParser.parse("pocketdj://remote/join"))
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://remote/join/a!"))
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://remote/elsewhere"))
    }

    @Test fun existingLinksAreUnchanged() {
        assertEquals(DeepLink.JukeboxJoin("exmkrd5a", null), DeepLinkParser.parse("pocketdj://jukebox/exmkrd5a"))
    }

    @Test fun aRequestParksUntilConsumedAndNewerWins() {
        RemotePanelRequests.request(joinCode = "AAAA11")
        val first = RemotePanelRequests.pending.value!!
        assertEquals("AAAA11", first.joinCode)
        RemotePanelRequests.request(joinCode = "BBBB22")
        RemotePanelRequests.consume(first) // stale: the newer request stays
        assertEquals("BBBB22", RemotePanelRequests.pending.value?.joinCode)
        RemotePanelRequests.consume(RemotePanelRequests.pending.value!!)
        assertNull(RemotePanelRequests.pending.value)
    }

    @Test fun showcaseOnlyRunsForTheExactExtraOnADebuggableBuild() {
        assertTrue(RemoteShowcaseSeed.wanted("showcase", true))
        assertFalse(RemoteShowcaseSeed.wanted("showcase", false))
        assertFalse(RemoteShowcaseSeed.wanted("true", true))
        assertFalse(RemoteShowcaseSeed.wanted(null, true))
    }

    @Test fun showcaseModelIsPlayingOneThirtySevenIn() {
        val songs = (1..9).map { IndexSong(id = "s$it", artist = "A$it", name = "N$it", length = 200_000) }
        val m = RemoteShowcaseSeed.model(songs, 5_000.0)
        assertEquals(6, m.rows.size)
        assertEquals("s1", m.currentRow?.songId)
        assertTrue(m.isPlaying)
        assertEquals(97_000L, m.position(5_000.0))
        assertEquals(99_000L, m.position(7_000.0))
        // an empty catalog still yields a presentable set
        assertEquals(6, RemoteShowcaseSeed.rows(emptyList()).size)
    }

    @Test fun theShowcaseRigPutsACarSpeakerOnTheLocalController() = runTest {
        val scope = backgroundScope
        val local = RemoteSessionController(
            target = InMemoryRemoteTarget(), resolver = RemoteSongResolver(catalogItem = { QueueItem(id = it) }),
            deviceName = { "This phone" }, platform = "test", scope = scope,
        )
        val songs = (1..6).map { IndexSong(id = "s$it", artist = "A", name = "N$it", length = 200_000) }
        try {
            val rig = RemoteShowcaseSeed.start(local, songs, scope)
            repeat(6) { runCurrent() }
            assertTrue(RemoteShowcaseSeed.isRunning)
            assertTrue(RemoteShowcaseSeed.running.value)
            assertTrue(local.isActive.value)
            assertEquals(RemoteSessionMode.BACKSEAT, local.mode.value)
            assertTrue(local.peers.any { it.name == "Car" })
            assertTrue(local.positionNow() >= 97_000L)
            assertTrue(rig.car.isActive.value)
        } finally {
            RemoteShowcaseSeed.stop()
        }
        assertFalse(RemoteShowcaseSeed.isRunning)
        assertFalse(RemoteShowcaseSeed.running.value)
    }

    @get:org.junit.Rule val tmp = org.junit.rules.TemporaryFolder()

    private fun store(scope: kotlinx.coroutines.CoroutineScope) = com.levi.pocketdj.data.settings.AppSettingsStore(
        androidx.datastore.preferences.core.PreferenceDataStoreFactory.create(scope = scope) { java.io.File(tmp.root, "s.preferences_pb") },
    )

    @Test fun restoreOfTheRetiredRemoteTokenWritesRemoteMode() = kotlinx.coroutines.runBlocking {
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO + kotlinx.coroutines.Job())
        val settings = store(scope)
        settings.set(com.levi.pocketdj.data.settings.LegacyPrefKeys.LAST_SECTION, "Remote")
        val dest = com.levi.pocketdj.shell.LastSectionStore(settings).restore()
        assertEquals(PocketDjDestination.Jukebox, dest)
        assertEquals("Remote", settings.get(JukeboxPanelModeStore.KEY))
        scope.cancel()
    }

    @Test fun restoreOfAnOrdinaryTokenLeavesTheModeAlone() = kotlinx.coroutines.runBlocking {
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO + kotlinx.coroutines.Job())
        val settings = store(scope)
        settings.set(com.levi.pocketdj.data.settings.LegacyPrefKeys.LAST_SECTION, "Jukebox Hero")
        com.levi.pocketdj.shell.LastSectionStore(settings).restore()
        assertEquals("Jukebox Hero", settings.get(JukeboxPanelModeStore.KEY))
        scope.cancel()
    }

    @Test fun aRemoteLinkRoutesToJukeboxAndParksARequest() = runTest {
        val consumed = RemotePanelRequests.pending.value
        consumed?.let(RemotePanelRequests::consume)
        val routes = mutableListOf<com.levi.pocketdj.shell.ShellRoute>()
        val gate = object : com.levi.pocketdj.shell.OnboardingGate {
            override val isComplete = true
            override suspend fun waitUntilComplete() {}
        }
        val d = com.levi.pocketdj.shell.DeepLinkDispatcher(backgroundScope, gate, postRoute = { routes += it }, postMessage = {})
        assertTrue(d.handle(DeepLink.Remote("ABCD12")))
        assertEquals(listOf<com.levi.pocketdj.shell.ShellRoute>(com.levi.pocketdj.shell.ShellRoute.Tab(PocketDjDestination.Jukebox)), routes)
        assertEquals("ABCD12", RemotePanelRequests.pending.value?.joinCode)
        RemotePanelRequests.consume(RemotePanelRequests.pending.value!!)
    }
}
