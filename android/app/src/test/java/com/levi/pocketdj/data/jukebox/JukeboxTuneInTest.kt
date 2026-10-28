package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.playback.isTuneInMediaId
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class JukeboxTuneInTest {
    @Test fun stopButtonStopsTheStream() = runTest {
        val stopped = mutableListOf<String>()
        val m = JukeboxTuneIn(this) { stopped += it }
        m.requestTuneIn(); m.noteStarted("https://s/a.mp3")
        assertTrue(m.tunedIn.value)
        m.stop(); advanceUntilIdle()
        assertFalse(m.tunedIn.value)
        assertEquals(listOf("https://s/a.mp3"), stopped)
    }

    @Test fun stopWithoutAStartedStreamStopsNothing() = runTest {
        val stopped = mutableListOf<String>()
        val m = JukeboxTuneIn(this) { stopped += it }
        m.requestTuneIn(); m.stop(); advanceUntilIdle()
        assertTrue(stopped.isEmpty())
        m.stop(); advanceUntilIdle()
        assertTrue(stopped.isEmpty())
    }

    @Test fun retuneStopsTheLatestStreamOnly() = runTest {
        val stopped = mutableListOf<String>()
        val m = JukeboxTuneIn(this) { stopped += it }
        m.requestTuneIn(); m.noteStarted("https://s/a.mp3"); m.noteStarted("https://s/b.mp3")
        m.stop(); advanceUntilIdle()
        assertEquals(listOf("https://s/b.mp3"), stopped)
    }

    @Test fun poppingTheEntryStopsButRecompositionDoesNot() = runTest {
        val stopped = mutableListOf<String>()
        val m = JukeboxTuneIn(this) { stopped += it }
        m.requestTuneIn(); m.noteStarted("https://s/a.mp3")
        advanceUntilIdle()
        assertTrue(stopped.isEmpty()) // nothing happens on composition dispose: the model owns the stream
        m.onCleared(); advanceUntilIdle()
        assertEquals(listOf("https://s/a.mp3"), stopped)
    }

    @Test fun onlyTheTuneInItemIsStoppable() {
        assertTrue(isTuneInMediaId("url:https://s/a.mp3", "https://s/a.mp3"))
        assertFalse(isTuneInMediaId("song-123", "https://s/a.mp3"))
        assertFalse(isTuneInMediaId("url:https://s/other.mp3", "https://s/a.mp3"))
        assertFalse(isTuneInMediaId(null, "https://s/a.mp3"))
    }
}
