package com.levi.pocketdj.screens.games

import com.levi.pocketdj.data.games.InThePocketStats
import com.levi.pocketdj.data.games.inthepocket.FeedbackDictationAuthorization
import com.levi.pocketdj.data.games.inthepocket.FeedbackDictationController
import com.levi.pocketdj.data.games.inthepocket.FeedbackDictationController.State
import com.levi.pocketdj.data.games.inthepocket.FeedbackSpeechEngine
import com.levi.pocketdj.data.games.inthepocket.InThePocketContext
import com.levi.pocketdj.data.games.inthepocket.InThePocketMode
import com.levi.pocketdj.data.games.inthepocket.InThePocketOutcome
import com.levi.pocketdj.data.games.inthepocket.InThePocketRound
import com.levi.pocketdj.data.games.inthepocket.InThePocketSong
import com.levi.pocketdj.data.games.inthepocket.InThePocketSongState
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InThePocketScreenLogicTest {
    private val L = InThePocketScreenLogic

    private fun song(state: InThePocketSongState, why: List<String> = emptyList()) =
        InThePocketSong(id = "s", title = "t", artist = "a", score = 1.0, why = why, state = state)

    private fun round(songs: List<InThePocketSong>, feedback: String? = null, rating: Int? = null) =
        InThePocketRound(
            id = UUID.randomUUID(), createdAtMs = 0.0, updatedAtMs = 0.0, tzOffsetMin = 0,
            context = InThePocketContext("evening", "weekday", 5), mode = InThePocketMode.COLD, seed = "1",
            targets = emptyList(), songs = songs, feedback = feedback, rating = rating,
        )

    @Test fun modeNotes() {
        assertEquals("Built from your listening pockets for this moment.", L.modeNote(InThePocketMode.CLOUD))
        assertTrue(L.modeNote(InThePocketMode.HISTORY).contains("at this time of day"))
        assertTrue(L.modeNote(InThePocketMode.COLD).endsWith("Play more and the bets get sharper."))
    }

    @Test fun outcomeText() {
        assertEquals("In the pocket!", L.outcomeText(InThePocketOutcome.Pocket))
        assertEquals("Broke at song 3", L.outcomeText(InThePocketOutcome.Broke(3)))
        assertEquals("Round ended early", L.outcomeText(InThePocketOutcome.Abandoned))
    }

    @Test fun progressLabelCountsOnlyCompleted() {
        val r = round(listOf(
            song(InThePocketSongState.COMPLETED), song(InThePocketSongState.PLAYING),
            song(InThePocketSongState.SKIPPED), song(InThePocketSongState.COMPLETED)))
        assertEquals("2 of 4 songs played through", L.progressLabel(r))
    }

    @Test fun summaryAndStatCells() {
        val s = InThePocketStats(rounds = 12, pockets = 7, pocketRate = 0.58, bestStreak = 3, currentStreak = 1)
        assertEquals("12 rounds · 58% in the pocket · best streak 3", L.inThePocketSummary(s))
        assertEquals(listOf("12" to "rounds", "58%" to "in the pocket", "3" to "best streak"), L.statCells(s))
        val none = InThePocketStats(0, 0, null, 0, 0)
        assertEquals("No rounds yet", L.inThePocketSummary(none))
        assertEquals("–", L.statCells(none)[1].first)
    }

    @Test fun whyLineCapsAtThree() {
        assertNull(L.whyLine(song(InThePocketSongState.PENDING)))
        assertEquals("a · b · c",
            L.whyLine(song(InThePocketSongState.PENDING, listOf("a", "b", "c", "d"))))
    }

    @Test fun buildLabelAndChips() {
        assertEquals("Finding your pocket…", L.buildButtonLabel(true))
        assertEquals("Build a round", L.buildButtonLabel(false))
        assertEquals("Friday evening · 120 BPM", L.chipsLine(listOf("Friday evening", "120 BPM")))
    }

    @Test fun clampDraftCapsUtf16WithoutSplittingSurrogate() {
        val ok = "x".repeat(2000)
        assertEquals(ok, L.clampDraft(ok))
        assertEquals("2000/2000", L.counterText(ok))
        val over = "x".repeat(1999) + "🎵" // emoji straddles the cap
        val c = L.clampDraft(over)
        assertEquals(1999, c.length)
        assertFalse(Character.isHighSurrogate(c.last()))
        assertEquals(2000, L.clampDraft("y".repeat(5000)).length)
    }

    @Test fun feedbackSavedAndRatingToggle() {
        val r = round(emptyList(), feedback = "nice", rating = 4)
        assertTrue(L.feedbackSaved(r, "  nice ", 4))
        assertFalse(L.feedbackSaved(r, "nice!", 4))
        assertFalse(L.feedbackSaved(r, "nice", 5))
        assertTrue(L.feedbackSaved(round(emptyList()), "   ", null))
        assertNull(L.toggledRating(3, 3))
        assertEquals(5, L.toggledRating(3, 5))
        assertEquals(1, L.toggledRating(null, 1))
    }

    // ---- FeedbackDictationTests port (fake engine) ----

    private class FakeEngine : FeedbackSpeechEngine {
        override var isAvailable = true
        var auth = FeedbackDictationAuthorization.AUTHORIZED
        var startThrows = false
        var starts = 0
        var stops = 0
        private var onTranscript: ((String) -> Unit)? = null
        private var onFinish: ((String?) -> Unit)? = null
        override suspend fun requestAuthorization() = auth
        override fun start(onTranscript: (String) -> Unit, onFinish: (String?) -> Unit) {
            if (startThrows) throw IllegalStateException("fake")
            starts++
            this.onTranscript = onTranscript
            this.onFinish = onFinish
        }
        override fun stop() { stops++ }
        fun say(t: String) = onTranscript?.invoke(t)
        fun finish(e: String?) = onFinish?.invoke(e)
    }

    @Test fun toggleStartsAndAppends() = runBlocking {
        val engine = FakeEngine()
        val c = FeedbackDictationController(engine)
        var field = "Good groove."
        assertTrue(c.isAvailable)
        c.toggle(field) { field = it }
        assertEquals(State.Listening, c.state.value)
        assertEquals(1, engine.starts)
        engine.say("the second")
        assertEquals("Good groove. the second", field)
        engine.say("the second song dragged") // partials carry the WHOLE transcript
        assertEquals("Good groove. the second song dragged", field)
        c.toggle(field) { field = it }
        assertEquals(State.Idle, c.state.value)
        assertEquals(1, engine.stops)
        engine.say("late partial after stop")
        assertEquals("Good groove. the second song dragged", field)
        assertNull(c.explanation)
    }

    @Test fun deniedShowsExplanation() = runBlocking {
        val engine = FakeEngine().also { it.auth = FeedbackDictationAuthorization.DENIED }
        val c = FeedbackDictationController(engine)
        var field = "typed"
        c.toggle(field) { field = it }
        assertEquals(State.Denied, c.state.value)
        assertEquals(0, engine.starts)
        assertEquals("typed", field)
        assertTrue(c.explanation!!.contains("type"))
        assertFalse(L.micEnabled(denied = true, unavailable = false))
    }

    @Test fun unavailableHidesMic() = runBlocking {
        val none = FeedbackDictationController(null)
        assertFalse(none.isAvailable)
        none.toggle("") { throw AssertionError("no text without an engine") }
        assertEquals(State.Unavailable, none.state.value)
        assertFalse(L.micVisible(none.isAvailable))
        val engine = FakeEngine().also { it.isAvailable = false }
        assertFalse(FeedbackDictationController(engine).isAvailable)
        engine.isAvailable = true
        engine.auth = FeedbackDictationAuthorization.UNAVAILABLE
        val c = FeedbackDictationController(engine)
        c.toggle("") { }
        assertEquals(State.Unavailable, c.state.value)
        assertNotNull(c.explanation)
        assertEquals(0, engine.starts)
    }

    @Test fun stopFromListening() = runBlocking {
        val engine = FakeEngine()
        val c = FeedbackDictationController(engine)
        var field = ""
        c.toggle(field) { field = it }
        engine.say("hello")
        c.stop() // e.g. leaving the screen
        assertEquals(State.Idle, c.state.value)
        assertEquals(1, engine.stops)
        engine.say("ignored")
        assertEquals("hello", field)
        c.stop() // idempotent
        assertEquals(1, engine.stops)
    }

    @Test fun failureMessage() = runBlocking {
        val engine = FakeEngine()
        val c = FeedbackDictationController(engine)
        var field = ""
        c.toggle(field) { field = it }
        engine.say("hello")
        engine.finish(null)
        assertEquals(State.Idle, c.state.value)
        assertEquals("hello", field)
        c.toggle(field) { field = it }
        engine.finish("Dictation stopped — try again.")
        assertEquals(State.Failed("Dictation stopped — try again."), c.state.value)
        assertEquals("Dictation stopped — try again.", c.explanation)
        engine.startThrows = true
        c.toggle(field) { field = it }
        assertEquals(State.Failed("Couldn't start dictation."), c.state.value)
    }

    @Test fun joinRule() {
        val j = FeedbackDictationController.Companion::join
        assertEquals("hi", j("", "hi"))
        assertEquals("typed ", j("typed ", ""))
        assertEquals("a b", j("a ", "b"))
        assertEquals("line\nb", j("line\n", "b"))
    }
}
