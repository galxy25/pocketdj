package com.levi.pocketdj.screens.remote

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.playback.durable.SessionRow
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.remote.InMemoryRemoteTarget
import com.levi.pocketdj.remote.LoopbackHub
import com.levi.pocketdj.remote.RemoteCommand
import com.levi.pocketdj.remote.RemoteDeviceRole
import com.levi.pocketdj.remote.RemoteQueueModel
import com.levi.pocketdj.remote.RemoteRow
import com.levi.pocketdj.remote.RemoteSessionController
import com.levi.pocketdj.remote.RemoteSessionMode
import com.levi.pocketdj.remote.RemoteSongResolver
import com.levi.pocketdj.remote.SharedClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RemoteViewModelTest {
    private var t = 1_000_000.0

    private class Dev(val controller: RemoteSessionController, val target: InMemoryRemoteTarget, val link: com.levi.pocketdj.remote.LoopbackTransport)

    private fun dev(id: String, hub: LoopbackHub, scope: CoroutineScope): Dev {
        val link = hub.join(id)
        val target = InMemoryRemoteTarget { t }
        val c = RemoteSessionController(
            target = target, resolver = RemoteSongResolver(catalogItem = { QueueItem(id = it) }),
            deviceName = { "Dev $id" }, platform = "test", clock = SharedClock { t }, scope = scope,
        )
        return Dev(c, target, link)
    }

    private fun row(id: String) = RemoteRow("r-$id", SessionRow(songId = id, title = "T$id", artist = "A$id", lengthMs = 200_000))
    private fun seed(vararg ids: String) = RemoteQueueModel(rows = ids.map(::row), index = 0, isPlaying = true, anchor = t, revision = 1)
    private fun song(id: String, name: String = "N$id", artist: String = "Art") = IndexSong(id = id, artist = artist, name = name, length = 180_000)
    private fun TestScope.settle() { repeat(4) { runCurrent() } }

    private class FakeStarter(var outcome: StartOutcome = StartOutcome.Started(null)) : RemoteSessionStarter {
        override var available = true
        override val invite: StateFlow<RemoteInvite?> = MutableStateFlow(null)
        override val discovered: StateFlow<List<DiscoveredHost>> = MutableStateFlow(emptyList())
        val started = ArrayList<RemoteSessionMode>(); val codes = ArrayList<String>(); val hosts = ArrayList<String>()
        var joinOutcome: JoinOutcome = JoinOutcome.Joined
        var cleared = 0
        override suspend fun start(mode: RemoteSessionMode): StartOutcome { started += mode; return outcome }
        override suspend fun joinWithCode(code: String): JoinOutcome { codes += code; return joinOutcome }
        override suspend fun joinHost(hostId: String): JoinOutcome { hosts += hostId; return joinOutcome }
        override fun startDiscovery() {}
        override fun stopDiscovery() {}
        override fun clearInvite() { cleared++ }
    }

    /** A VM over a (hosting) controller whose commands are captured instead of applied. */
    private fun TestScope.capturing(starter: RemoteSessionStarter = FakeStarter(), songs: List<IndexSong> = emptyList()): Triple<RemoteViewModel, ArrayList<RemoteCommand>, Dev> {
        val d = dev("A", LoopbackHub(), backgroundScope)
        d.controller.attach(d.link, RemoteSessionMode.LISTEN_TOGETHER, asHost = true, seed = seed("s1", "s2", "s3", "s4"), autoTick = false)
        val sent = ArrayList<RemoteCommand>()
        return Triple(RemoteViewModel(d.controller, { starter }, { songs }, backgroundScope, send = { sent += it }), sent, d)
    }

    // ---- every control maps to the right RemoteCommand ----

    @Test fun transportControlsMapToCommands() = runTest {
        val (vm, sent, _) = capturing()
        vm.previous(); vm.playPause(); vm.next(); vm.seek(42_000)
        assertEquals(
            listOf(RemoteCommand.SkipPrevious, RemoteCommand.PlayPause, RemoteCommand.SkipNext, RemoteCommand.Seek(42_000)),
            sent,
        )
    }

    @Test fun repeatCyclesFromTheSessionStateAndShuffleToggles() = runTest {
        val (vm, sent, d) = capturing()
        vm.cycleRepeat()
        vm.toggleShuffle()
        assertEquals(listOf<RemoteCommand>(RemoteCommand.SetRepeat(RepeatMode.ALL), RemoteCommand.SetShuffle(true)), sent)
        // After the host applies repeat=all the next press goes to ONE.
        d.controller.send(RemoteCommand.SetRepeat(RepeatMode.ALL))
        sent.clear(); vm.cycleRepeat()
        assertEquals(listOf<RemoteCommand>(RemoteCommand.SetRepeat(RepeatMode.ONE)), sent)
    }

    @Test fun upNextActionsMapToJumpMoveRemove() = runTest {
        val (vm, sent, _) = capturing()
        vm.playNow("r-s3"); vm.playNext("r-s4"); vm.remove("r-s2")
        assertEquals(
            listOf(RemoteCommand.JumpTo("r-s3"), RemoteCommand.Move("r-s4", 0), RemoteCommand.Remove("r-s2")),
            sent,
        )
    }

    @Test fun dragReorderSendsTheFullUpcomingOrder() = runTest {
        val (vm, sent, _) = capturing()
        vm.reorder(0, 2) // upcoming = s2, s3, s4 -> s3, s4, s2
        assertEquals(listOf<RemoteCommand>(RemoteCommand.Reorder(listOf("r-s3", "r-s4", "r-s2"))), sent)
        sent.clear(); vm.reorder(1, 1); vm.reorder(0, 9); vm.reorder(-1, 0)
        assertTrue("a no-op or out-of-range drag sends nothing", sent.isEmpty())
    }

    @Test fun addPlacementsMapToPlayNowEnqueueNextAppend() = runTest {
        val (vm, sent, _) = capturing()
        vm.add(song("x"), AddPlacement.NOW); vm.add(song("y"), AddPlacement.NEXT); vm.add(song("z"), AddPlacement.END)
        assertTrue(sent[0] is RemoteCommand.PlayNow)
        assertTrue(sent[1] is RemoteCommand.EnqueueNext)
        assertTrue(sent[2] is RemoteCommand.Append)
        val r = (sent[1] as RemoteCommand.EnqueueNext).rows.single()
        assertEquals("y", r.songId); assertEquals("Ny", r.title); assertEquals("Art", r.artist); assertEquals(180_000L, r.row.lengthMs)
    }

    @Test fun addNowOnAnEmptySessionStartsPlayback() = runTest {
        val d = dev("A", LoopbackHub(), backgroundScope)
        d.controller.attach(d.link, RemoteSessionMode.LISTEN_TOGETHER, asHost = true, seed = RemoteQueueModel(), autoTick = false)
        val sent = ArrayList<RemoteCommand>()
        val vm = RemoteViewModel(d.controller, { FakeStarter() }, { emptyList() }, backgroundScope, send = { sent += it })
        vm.add(song("x"), AddPlacement.NOW)
        val c = sent.single() as RemoteCommand.Play
        assertEquals(0, c.startIndex); assertEquals("x", c.rows.single().songId)
    }

    @Test fun roleRejoinAndLeaveGoToTheController() = runTest {
        val starter = FakeStarter()
        val (vm, _, d) = capturing(starter)
        vm.setRole(RemoteDeviceRole.CONTROLLER)
        assertEquals(RemoteDeviceRole.CONTROLLER, d.controller.localRole.value)
        vm.setRole(RemoteDeviceRole.SPEAKER)
        assertEquals(RemoteDeviceRole.SPEAKER, d.controller.localRole.value)
        vm.leave()
        assertFalse(d.controller.isActive.value)
        assertEquals(1, starter.cleared)
    }

    // ---- never the local player; real session round trip ----

    @Test fun aRemoteNextAdvancesTheHostNotTheLocalPlayer() = runTest {
        val hub = LoopbackHub()
        val a = dev("A", hub, backgroundScope); val b = dev("B", hub, backgroundScope)
        a.controller.attach(a.link, RemoteSessionMode.LISTEN_TOGETHER, asHost = true, seed = seed("s1", "s2", "s3"), autoTick = false)
        b.controller.attach(b.link, RemoteSessionMode.LISTEN_TOGETHER, asHost = false, autoTick = false)
        settle()
        // B is a controller; its remote-next goes to the host.
        b.controller.setLocalRole(RemoteDeviceRole.CONTROLLER)
        val vm = RemoteViewModel(b.controller, { FakeStarter() }, { emptyList() }, backgroundScope)
        val playsBefore = b.target.isPlaying
        vm.next(); settle()
        assertEquals("s2", a.controller.state.value?.currentRow?.songId)
        assertEquals("s2", b.controller.state.value?.currentRow?.songId)
        assertEquals("the controller's own player is untouched", playsBefore, b.target.isPlaying)
    }

    // ---- search ----

    @Test fun searchIsDebouncedMinTwoCharsAndCapped() = runTest {
        val songs = (1..40).map { song("s$it", name = "Hello $it") } + song("o", name = "Other")
        val (vm, _, _) = capturing(songs = songs)
        vm.setQuery("h"); advanceTimeBy(1_000)
        assertTrue(vm.results.value.isEmpty())
        vm.setQuery("he"); advanceTimeBy(100)
        assertTrue("still inside the 250 ms debounce", vm.results.value.isEmpty())
        advanceTimeBy(200)
        assertEquals(RemoteSearch.CAP, vm.results.value.size)
        assertEquals("s1", vm.results.value.first().id)
        vm.setQuery("zzz"); advanceTimeBy(300)
        assertTrue(vm.results.value.isEmpty())
        vm.setQuery("he"); vm.setQuery(""); advanceTimeBy(300)
        assertTrue("a cleared field cancels the pending search", vm.results.value.isEmpty())
    }

    @Test fun searchFoldsCaseAndDiacriticsOverTitleAndArtist() {
        val songs = listOf(song("1", "Café del Mar", "Energy 52"), song("2", "Other", "BJÖRK"), song("3", "Nope", "Nobody"))
        assertEquals(listOf("1"), RemoteSearch.search("CAFE", songs).map { it.id })
        assertEquals(listOf("2"), RemoteSearch.search("bjork", songs).map { it.id })
        assertEquals("title + artist are searched together", listOf("1"), RemoteSearch.search("mar energy", songs).map { it.id })
        assertEquals(1, RemoteSearch.search("o", songs, cap = 1).size)
    }

    // ---- start / join ----

    @Test fun beginStartsTheModeAndClearsTheSpinner() = runTest {
        val starter = FakeStarter()
        val (vm, _, d) = capturing(starter)
        d.controller.leave()
        vm.begin(RemoteSessionMode.BACKSEAT)
        assertEquals(RemoteSessionMode.BACKSEAT, vm.starting.value)
        vm.begin(RemoteSessionMode.LISTEN_TOGETHER) // ignored while one is in flight
        runCurrent()
        assertNull(vm.starting.value)
        assertEquals(listOf(RemoteSessionMode.BACKSEAT), starter.started)
    }

    @Test fun aFailedStartSurfacesAStatusMessage() = runTest {
        val starter = FakeStarter(StartOutcome.Failed("no bluetooth"))
        val (vm, _, d) = capturing(starter)
        vm.begin(RemoteSessionMode.LISTEN_TOGETHER); runCurrent()
        assertEquals("Couldn’t start the session: no bluetooth", d.controller.statusMessage.value)
        assertNull(vm.starting.value)
    }

    @Test fun joinParsesCodesAndLinksAndRejectsGarbage() = runTest {
        val starter = FakeStarter()
        val (vm, _, d) = capturing(starter)
        assertTrue(vm.joinWithCode(" ab3k9z ")); runCurrent()
        assertTrue(vm.joinWithCode("pocketdj://remote/join/QWERTY")); runCurrent()
        assertFalse(vm.joinWithCode("no spaces allowed")); runCurrent()
        assertEquals(listOf("AB3K9Z", "QWERTY"), starter.codes)
        vm.joinHost(DiscoveredHost("ep1", "Pixel")); runCurrent()
        assertEquals(listOf("ep1"), starter.hosts)
        starter.joinOutcome = JoinOutcome.Failed("wrong code")
        vm.joinWithCode("ZZZZZZ"); runCurrent()
        assertEquals("Couldn’t join: wrong code", d.controller.statusMessage.value)
        assertFalse(vm.joining.value)
    }

    @Test fun unavailableStarterRefusesWithAMessage() = runTest {
        val (vm, _, d) = capturing(RemoteSessionStarter.None)
        vm.begin(RemoteSessionMode.LISTEN_TOGETHER); runCurrent()
        assertTrue(d.controller.statusMessage.value!!.startsWith("Couldn’t start the session"))
    }

    // ---- pure helpers ----

    @Test fun joinCodeParse() {
        assertEquals("ABC123", RemoteJoinCode.parse("abc123"))
        assertEquals("ABC123", RemoteJoinCode.parse("https://pocketdj.app/remote/join/abc123?x=1"))
        assertEquals("a-very-long-token-0123456789", RemoteJoinCode.parse("pocketdj://remote/join/a-very-long-token-0123456789/"))
        assertNull(RemoteJoinCode.parse("")); assertNull(RemoteJoinCode.parse("ab")); assertNull(RemoteJoinCode.parse("a b c d"))
    }

    @Test fun reorderedAndDragTarget() {
        val l = listOf("a", "b", "c", "d")
        assertEquals(listOf("b", "c", "a", "d"), RemoteQueueUi.reordered(l, 0, 2))
        assertEquals(listOf("a", "d", "b", "c"), RemoteQueueUi.reordered(l, 3, 1))
        assertNull(RemoteQueueUi.reordered(l, 2, 2))
        assertEquals(3, RemoteQueueUi.dragTarget(1, 130f, 60f, 4))
        assertEquals(0, RemoteQueueUi.dragTarget(1, -500f, 60f, 4))
        assertEquals(3, RemoteQueueUi.dragTarget(2, 900f, 60f, 4))
        assertEquals(2, RemoteQueueUi.dragTarget(2, 10f, 0f, 4))
    }

    @Test fun displayStrings() {
        assertEquals("3:07", RemoteQueueUi.clock(187_400))
        assertEquals("0:00", RemoteQueueUi.clock(-5))
        assertEquals("Unavailable on Pixel, iPad", RemoteQueueUi.unavailableText(listOf("Pixel", "iPad")))
        assertNull(RemoteQueueUi.unavailableText(emptyList()))
        assertEquals("1 song can’t play here", RemoteQueueUi.songsCantPlayText(1))
        assertEquals("3 songs can’t play here", RemoteQueueUi.songsCantPlayText(3))
        assertNull(RemoteQueueUi.songsCantPlayText(0))
    }

    @Test fun upcomingRowsAreThoseAfterTheCurrent() = runTest {
        val (_, _, d) = capturing()
        assertEquals(listOf("s2", "s3", "s4"), RemoteQueueUi.upcoming(d.controller.state.value).map { it.songId })
        assertTrue(RemoteQueueUi.upcoming(null).isEmpty())
    }
}
