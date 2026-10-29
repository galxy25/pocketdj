package com.levi.pocketdj.screens.nowplaying

import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.SequencerState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NowPlayingViewModelTest {
    private val a = QueueItem(id = "a", title = "Alpha", artist = "Art", lengthMs = 200_000)
    private val b = QueueItem(id = "b", title = "Beta", artist = "Bee")

    private fun seq(
        running: Boolean = true, held: Boolean = false, index: Int = 0,
        notice: String? = null, repeat: RepeatMode = RepeatMode.OFF, shuffle: Boolean = false,
    ) = SequencerState(
        queue = listOf(a, b), index = index, isRunning = running, isHeldForResume = held,
        playbackNotice = notice, repeatMode = repeat, shuffleEnabled = shuffle,
    )

    private fun audible(id: String, playing: Boolean = true, dur: Long? = 190_000) =
        AudibleTrack(id, "x", "y", null, playing, dur)

    private fun build(
        s: SequencerState, au: AudibleTrack?, facts: SongFacts? = null,
        pending: Boolean = false, am: Boolean = false, neverSounded: Boolean = false,
    ) = NowPlayingModel.build(s, au, facts, pending, am, neverSounded)

    // ---- deck state ----------------------------------------------------------------------

    @Test fun deckShowsCurrentRowTitleAndArtist() {
        val st = build(seq(), audible("a"))
        assertEquals("Alpha", st.title)
        assertEquals("Art", st.artist)
        assertTrue(st.spinning)
    }

    @Test fun recordDoesNotSpinForABrowseSingleOverAPausedSet() {
        // The set's current row is "a"; the audible track is a foreign single "zzz".
        val st = build(seq(), audible("zzz"))
        assertFalse(st.audibleIsCurrent)
        assertFalse(st.spinning)
    }

    @Test fun recordStopsWhenPausedButStillCurrent() {
        val st = build(seq(), audible("a", playing = false))
        assertTrue(st.audibleIsCurrent)
        assertFalse(st.spinning)
    }

    @Test fun bpmPrefersManifestAndLengthPrefersCatalog() {
        val st = build(
            seq(), audible("a"),
            SongFacts(catalogBpm = 100.0, manifestBeatGridBpm = 128.0, catalogLengthMs = 210_000),
        )
        assertEquals(128.0, st.bpm!!, 0.0)
        assertEquals(210_000L, st.lengthMs)
        // No catalog length: falls to the row length, then the player's duration.
        assertEquals(200_000L, build(seq(), audible("a")).lengthMs)
        assertEquals(190_000L, build(seq(index = 1), audible("b")).lengthMs)
    }

    @Test fun modeRowOnlyWhileASetRunsAndHelpTextFollowsRepeat() {
        assertFalse(build(SequencerState(), null).showModeRow)
        // A Browse single (no run) gets the same mode row.
        assertTrue(build(SequencerState(), audible("a")).showModeRow)
        val st = build(seq(repeat = RepeatMode.ALL, shuffle = true), audible("a"))
        assertTrue(st.showModeRow)
        assertTrue(st.shuffleEnabled)
        assertEquals("Repeat session", st.repeatHelp)
        assertEquals("Repeat song", repeatHelpText(RepeatMode.ONE))
        assertEquals("Repeat off", repeatHelpText(RepeatMode.OFF))
    }

    @Test fun repeatCyclesOffAllOne() {
        assertEquals(RepeatMode.ALL, RepeatMode.OFF.next)
        assertEquals(RepeatMode.ONE, RepeatMode.ALL.next)
        assertEquals(RepeatMode.OFF, RepeatMode.ONE.next)
    }

    @Test fun noticeSurfacesAndBlankIsDropped() {
        assertEquals("Can't play", build(seq(notice = "Can't play"), null).notice)
        assertNull(build(seq(notice = "  "), null).notice)
    }

    @Test fun idleDeckHasNoTrack() {
        val st = build(SequencerState(), null)
        assertFalse(st.hasTrack)
        assertEquals("Nothing playing", st.title)
    }

    // ---- transport inputs ----------------------------------------------------------------

    @Test fun heldRunMapsToHeldInput() {
        assertTrue(build(seq(held = true), null).transport.held)
        assertFalse(build(seq(held = false), audible("a")).transport.held)
    }

    @Test fun neverSoundedDeckIsCascadePausedUnlessStartPending() {
        assertTrue(build(seq(), null, neverSounded = true).transport.pausedByCascade)
        assertFalse(build(seq(), null, pending = true, neverSounded = true).transport.pausedByCascade)
        assertFalse(build(seq(), audible("a")).transport.pausedByCascade)
        // Merely idle (no signal) is NOT a cascade halt; the idle rung handles it.
        assertFalse(build(seq(), null).transport.pausedByCascade)
    }

    @Test fun realCascadeHaltWithStaleAudibleStillRetriesTheRow() {
        // The ended previous item is still loaded in the player (audible != null).
        val halted = seq().copy(pausedByCascade = true)
        val t = build(halted, audible("a", playing = false)).transport
        assertTrue(t.pausedByCascade)
        assertEquals(TransportVerdict.START_CURRENT, NowPlayingTransport.decide(t))
    }

    @Test fun staleItemFromAnotherRowCountsAsEngineIdle() {
        assertTrue(build(seq(index = 1), audible("a", playing = false)).transport.engineIdle)
        assertFalse(build(seq(index = 1), audible("b")).transport.engineIdle)
    }

    @Test fun browseSingleWithNoSetSpinsTheRecord() {
        val st = build(SequencerState(), audible("zzz"))
        assertTrue(st.spinning)
    }

    @Test fun appleMusicIdAndCatalogFlagRideOnTheState() {
        val st = build(seq(), audible("a"), facts = SongFacts(inCatalog = true, appleMusicId = "123"))
        assertEquals("123", st.appleMusicId)
        assertTrue(st.inCatalog)
        assertFalse(build(seq(), audible("a")).inCatalog)
    }

    // ---- ladder --------------------------------------------------------------------------

    private class FakePort : TransportPort {
        val calls = mutableListOf<String>()
        override fun resumeFromHold() { calls += "resumeFromHold" }
        override fun startCurrent() { calls += "startCurrent" }
        override fun toggleAppleMusic() { calls += "am" }
        override fun togglePlayPauseEngine() { calls += "toggle" }
        override fun log(line: String) { calls += "log:$line" }
    }

    private fun run(i: TransportInputs): Pair<TransportVerdict, List<String>> {
        val p = FakePort()
        return NowPlayingTransport.togglePlayPause(i, p) to p.calls
    }

    private val base = TransportInputs(
        held = false, pausedByCascade = false, appleMusicActive = false, engineIdle = false, startPending = false,
    )

    @Test fun heldResumesFromHoldEvenIfEngineIdle() {
        val (v, calls) = run(base.copy(held = true, engineIdle = true, startPending = true))
        assertEquals(TransportVerdict.RESUME_FROM_HOLD, v)
        assertEquals(listOf("resumeFromHold"), calls)
    }

    @Test fun cascadeHaltedStartsCurrent() {
        val (v, calls) = run(base.copy(pausedByCascade = true, engineIdle = true))
        assertEquals(TransportVerdict.START_CURRENT, v)
        assertEquals(listOf("startCurrent"), calls)
    }

    @Test fun appleMusicBackendUsesAmToggle() {
        val (v, calls) = run(base.copy(appleMusicActive = true))
        assertEquals(TransportVerdict.APPLE_MUSIC_TOGGLE, v)
        assertEquals(listOf("am"), calls)
    }

    @Test fun idleEngineWithStartPendingIsIgnoredAndLogged() {
        val (v, calls) = run(base.copy(engineIdle = true, startPending = true))
        assertEquals(TransportVerdict.IGNORED_START_IN_FLIGHT, v)
        assertEquals(listOf("log:[playback] ▶ ignored: start in flight"), calls)
    }

    @Test fun idleEngineStartsCurrent() {
        val (v, calls) = run(base.copy(engineIdle = true))
        assertEquals(TransportVerdict.START_CURRENT, v)
        assertEquals(listOf("startCurrent"), calls)
    }

    @Test fun loadedEngineTogglesPlayPause() {
        val (v, calls) = run(base)
        assertEquals(TransportVerdict.TOGGLE, v)
        assertEquals(listOf("toggle"), calls)
    }

    @Test fun startPendingWithLoadedEngineStillToggles() {
        assertEquals(TransportVerdict.TOGGLE, NowPlayingTransport.decide(base.copy(startPending = true)))
    }
}
