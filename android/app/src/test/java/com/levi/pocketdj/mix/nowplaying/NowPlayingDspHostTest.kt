package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.audio.core.OfflineRenderer
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.mix.engine.MixSourceOpener
import com.levi.pocketdj.mix.engine.ResolvedTrack
import com.levi.pocketdj.mix.engine.VoiceRunner
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

@OptIn(ExperimentalCoroutinesApi::class)
class NowPlayingDspHostTest {
    private val sr = 44_100

    private class Ports : DspHostPorts {
        var song: String? = null
        override val currentSongId get() = song
        override val currentTitle: String? = null
        override val currentArtist: String? = null
        override val currentArtworkUri: String? = null
        override var heldForResume = false
        override var mixSessionActive = false
        override var appleMusicActive = false
        val local = HashSet<String>()
        override fun resolve(songId: String) = if (songId in local) ResolvedTrack(File("$songId.mp3"), isCut = true) else null
        override fun windowLengthMs(songId: String) = 0L
        override suspend fun positionMs() = 1500L
        override var exoPlaying = true
        val ended = ArrayList<String>()
        override fun advanceAfterEnd(songId: String) { ended += songId }
    }

    private class Rig {
        val sr = 44_100
        val scope = TestScope(StandardTestDispatcher())
        val voices = ArrayList<Voice>()
        var sink: OfflineRenderer? = null
        val stemFiles = HashMap<String, Map<String, File>>()
        val remote = HashSet<String>()
        val ports = Ports()
        val lock = StemLockSession()
        var replans = 0
        val engine = NowPlayingDspEngine(
            sinkFactory = { OfflineRenderer(sr, 512).also { sink = it } },
            opener = MixSourceOpener { f -> SyntheticPcmSource.tone(440.0, sr * 10L, sr, if (f.name.startsWith("stem")) 0.125f else 0.5f) },
            runner = VoiceRunner { v -> voices += v; AutoCloseable { voices.remove(v) } },
            stemSource = object : DspStemSource {
                override fun localParts(songId: String) = stemFiles[songId].orEmpty()
                override fun obtainable(songId: String) = songId in remote || songId in stemFiles
                override suspend fun fetch(songId: String, parts: List<String>) = false
            },
            scope = scope,
        )
        val host = NowPlayingDspHost(engine, lock, ports, replan = { replans++ })

        fun give(song: String, withStems: Boolean) {
            ports.local += song
            if (withStems) stemFiles[song] = listOf("vocals", "drums", "bass", "other").associateWith { File("stem-$it.mp3") }
        }

        fun start(song: String) { ports.song = song; runBlocking { host.onTrackStarted(song) } }

        fun render(frames: Int) {
            var done = 0
            while (done < frames) {
                var g = 0
                do { var any = false; for (v in voices.toList()) while (v.pump()) any = true; g++ } while (any && g < 50)
                val n = minOf(512, frames - done)
                sink?.renderFrames(n)
                done += n
                host.heartbeat(); scope.testScheduler.runCurrent()
            }
        }
    }

    @Test fun firstTouchEngagesOnceAtTheExoPosition() {
        val r = Rig(); r.give("a", true)
        r.ports.song = "a"
        assertTrue(r.host.available())
        assertTrue(runBlocking { r.host.engage() })
        assertEquals("a", r.engine.engagedSongId)
        assertEquals(1.5, r.engine.currentTimeSec, 0.02)
        val v = r.voices.toList()
        assertTrue(runBlocking { r.host.engage() })       // idempotent: no second swap
        assertEquals(v, r.voices.toList())
    }

    @Test fun panelIsHiddenForNonLocalRowsAndWhileAMixSessionRuns() {
        val r = Rig(); r.give("local", false)
        r.ports.song = "stream"
        assertFalse("non-local row", r.host.available())
        assertFalse(runBlocking { r.host.engage() })
        r.ports.song = "local"
        assertTrue(r.host.available())
        r.ports.mixSessionActive = true
        assertFalse("mix session active", r.host.available())
        r.ports.mixSessionActive = false; r.ports.appleMusicActive = true
        assertFalse("apple music has no file", r.host.available())
        r.ports.appleMusicActive = false; r.ports.heldForResume = true
        assertFalse("held restore", r.host.available())
        r.ports.song = null
        assertFalse(r.host.available())
    }

    @Test fun anUnreadableFileMarksTheTrackUnavailableUnderTheLock() {
        val r = Rig()
        r.ports.local += "bad"
        // the engine's opener always works here, so refuse via an empty-window resolve: use a missing resolve for the second path
        r.lock.setLock(true, StemSnapshot(true, emptySet(), emptyMap()))
        r.start("bad")      // no stems at all -> unavailable, not a crash
        assertEquals("bad", r.lock.unavailableSongId)
        assertEquals(StemLock.Indicator.UNAVAILABLE, r.host.indicator())
        assertTrue("lock kept", r.lock.current.wantsStems)
    }

    @Test fun stemLockCarriesTheStemSetToTheNextTrack() {
        val r = Rig(); r.give("a", true); r.give("b", true)
        r.start("a")
        runBlocking { r.host.withEngaged { it.setStemMuted("bass", true); it.setStemMode(true) } }
        r.render(sr)
        assertTrue(r.engine.stemsOnAir)
        r.host.setStemLock(true)               // ON captures the playing track's stem set
        assertTrue(r.lock.current.wantsStems)
        assertEquals(listOf("bass"), r.lock.current.muted)
        assertEquals(StemLock.Indicator.ACTIVE, r.host.indicator())
        // next track
        r.start("b")
        assertEquals("b", r.engine.engagedSongId)
        assertEquals("starts on the full mix", StemLock.Indicator.LOADING, r.host.indicator())
        assertEquals(setOf("bass"), r.engine.mutedStems)
        r.render(sr)
        assertTrue("handed over to the carried stems", r.engine.stemsOnAir)
        assertEquals(StemLock.Indicator.ACTIVE, r.host.indicator())
        assertEquals("applying the carry is not a user change", listOf("bass"), r.lock.current.muted)
    }

    @Test fun aTrackWithoutStemsPlaysTheFullMixAndTheLockSurvivesIt() {
        val r = Rig(); r.give("a", true); r.give("plain", false); r.give("c", true)
        r.start("a")
        runBlocking { r.host.withEngaged { it.setStemMode(true) } }
        r.render(sr); r.host.setStemLock(true)
        r.start("plain")
        assertEquals(StemLock.Indicator.UNAVAILABLE, r.host.indicator())
        assertFalse(r.engine.stemMode)
        assertTrue("carry untouched by the stemless track", r.lock.current.wantsStems)
        r.start("c")
        r.render(sr)
        assertTrue(r.engine.stemsOnAir)
        assertNull(r.lock.unavailableSongId)
    }

    @Test fun nonLocalTrackUnderTheLockIsUnavailableAndDisengagesTheEngine() {
        val r = Rig(); r.give("a", true)
        r.start("a")
        runBlocking { r.host.withEngaged { it.setStemMode(true) } }
        r.render(sr); r.host.setStemLock(true)
        r.start("stream")                       // not resolvable
        assertFalse(r.engine.isEngaged)
        assertEquals(StemLock.Indicator.UNAVAILABLE, r.host.indicator())
    }

    @Test fun withoutTheLockStemsResetOnEveryTrackChange() {
        val r = Rig(); r.give("a", true); r.give("b", true)
        r.start("a")
        runBlocking { r.host.withEngaged { it.setRate(1.5); it.setStemMode(true) } }
        r.render(sr)
        r.start("b")
        assertFalse(r.engine.isEngaged)
        assertEquals(1.0, r.engine.rate, 0.0); assertFalse(r.engine.stemMode)
        assertEquals(StemLock.Indicator.OFF, r.host.indicator())
    }

    @Test fun userStemChangesUpdateTheCarryAndReplanTheDownloads() {
        val r = Rig(); r.give("a", true)
        r.start("a")
        runBlocking { r.host.withEngaged { it.setStemMode(true) } }
        r.render(sr); r.host.setStemLock(true)
        val before = r.replans
        runBlocking { r.host.withEngaged { it.setStemMuted("vocals", true) } }
        assertEquals(listOf("vocals"), r.lock.current.muted)
        assertTrue(r.replans > before)
        assertEquals(listOf("vocals"), r.host.ui.value.lock.muted)
    }

    @Test fun lockToggleWithoutATrackIsIgnoredAndSessionEndClears() {
        val r = Rig()
        r.host.setStemLock(true)
        assertFalse(r.lock.current.enabled)
        r.give("a", true); r.start("a")
        r.host.setStemLock(true)
        assertTrue(r.lock.current.enabled)
        assertFalse("captured with nothing engaged: stems off", r.lock.current.stemsOn)
        r.host.sessionEnded()
        assertEquals(StemLockState(), r.lock.current)
    }

    @Test fun reachingTheEndAdvancesTheSequencer() {
        val r = Rig(); r.give("a", false)
        r.ports.song = "a"
        r.engine.onReachedEnd = { r.ports.advanceAfterEnd("a") }
        assertTrue(runBlocking { r.host.engage() })
        r.engine.disengage()
        r.engine.engage(File("a.mp3"), 0, 300, 0.1, true); r.engine.bindSong("a")
        r.render(sr)
        assertEquals(listOf("a"), r.ports.ended)
    }
}
