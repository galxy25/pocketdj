package com.levi.pocketdj.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeepLinkRemoteJoinTest {
    @Test fun remoteJoinLinkParsesTheToken() {
        assertEquals(DeepLink.RemoteJoin("ABCD2345"), DeepLinkParser.parse("pocketdj://remote/join/ABCD2345"))
        assertEquals(DeepLink.RemoteJoin("ABCD2345"), DeepLinkParser.parse("pocketdj://remote/join/abcd2345"))
        assertEquals(DeepLink.RemoteJoin("ABCD2345"), DeepLinkParser.parse("pocketdj:///remote/join/ABCD2345"))
    }

    @Test fun brokerInviteLinkIsMarkedInternet() {
        assertEquals(DeepLink.RemoteJoin("ABCD2345", internet = true), DeepLinkParser.parse("pocketdj://remote/join-net/abcd2345"))
        assertEquals(false, (DeepLinkParser.parse("pocketdj://remote/join/ABCD2345") as DeepLink.RemoteJoin).internet)
        assertEquals("ABCD2345", com.levi.pocketdj.screens.remote.RemoteJoinCode.parse("pocketdj://remote/join-net/ABCD2345"))
    }

    @Test fun malformedRemoteLinksAreNone() {
        assertEquals(DeepLink.Remote(null), DeepLinkParser.parse("pocketdj://remote/join/")) // no code: just open the Remote half
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://remote/join/a!b"))
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://remote/leave/ABCD2345"))
        assertEquals(DeepLink.Remote(null), DeepLinkParser.parse("pocketdj://remote"))
    }

    @Test fun remoteJoinParksInItsOwnSlot() {
        val store = PendingOpenStore()
        store.park(DeepLink.RemoteJoin("AAAA1111"))
        store.park(DeepLink.Navigate(ShellRoute.Album("x")))
        store.park(DeepLink.RemoteJoin("BBBB2222"))
        assertEquals(listOf<DeepLink>(DeepLink.Navigate(ShellRoute.Album("x")), DeepLink.RemoteJoin("BBBB2222")), store.drain())
    }

    private fun dispatcher(routes: MutableList<ShellRoute>, seams: DeepLinkSeams, clock: () -> Long, scope: kotlinx.coroutines.CoroutineScope) =
        DeepLinkDispatcher(
            scope, object : OnboardingGate { override val isComplete = true; override suspend fun waitUntilComplete() {} },
            seams, postRoute = { routes += it }, postMessage = {}, clock = clock,
        )

    @Test fun theInviteLinkParksTheTokenRoutesToJukeboxAndFlipsToTheRemoteHalf() = kotlinx.coroutines.test.runTest {
        val routes = mutableListOf<ShellRoute>()
        val seams = DeepLinkSeams()
        var shown = 0
        seams.showRemote = { shown++ }
        val d = dispatcher(routes, seams, { 0L }, backgroundScope)
        assertTrue(d.handle(DeepLinkParser.parse("pocketdj://remote/join/ABCD2345")))
        assertEquals("ABCD2345", d.pendingRemoteJoin.value)
        assertEquals(1, shown)
        assertEquals(listOf<ShellRoute>(ShellRoute.Tab(com.levi.pocketdj.navigation.PocketDjDestination.Jukebox)), routes)
        assertEquals("ABCD2345", d.takePendingRemoteJoin())
        assertNull(d.takePendingRemoteJoin())
    }

    @Test fun theParkedTargetCarriesWhichTransportTheInviterUsed() = kotlinx.coroutines.test.runTest {
        val d = dispatcher(mutableListOf(), DeepLinkSeams(), { 0L }, backgroundScope)
        d.handle(DeepLinkParser.parse("pocketdj://remote/join-net/ABCD2345"))
        assertEquals("ABCD2345" to true, d.takePendingRemoteJoinTarget())
        d.handle(DeepLinkParser.parse("pocketdj://remote/join/WXYZ2345"))
        assertEquals("WXYZ2345" to false, d.takePendingRemoteJoinTarget())
    }

    @Test fun aStaleParkedInviteIsNotJoined() = kotlinx.coroutines.test.runTest {
        var now = 1_000L
        val d = dispatcher(mutableListOf(), DeepLinkSeams(), { now }, backgroundScope)
        d.handle(DeepLinkParser.parse("pocketdj://remote/join/ABCD2345"))
        now += DeepLinkDispatcher.REMOTE_JOIN_TTL_MS + 1
        assertNull(d.takePendingRemoteJoin())
        d.handle(DeepLinkParser.parse("pocketdj://remote/join/WXYZ2345"))
        assertEquals("WXYZ2345", d.takePendingRemoteJoin())
    }
}
