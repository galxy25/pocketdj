package com.levi.pocketdj.screens.games

import com.levi.pocketdj.data.games.inthepocket.FeedbackDictationAuthorization
import com.levi.pocketdj.data.games.inthepocket.FeedbackDictationController
import com.levi.pocketdj.data.games.inthepocket.FeedbackDictationController.State
import com.levi.pocketdj.data.games.inthepocket.FeedbackSpeechEngine
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class GM8ReviewFixesTest {
    @Test fun consentDisclosesEverythingUploaded() {
        val c = PocketsOptInCopy.CONSENT
        for (k in listOf("last 90 days", "to the minute", "time-zone offset", "finished or skipped",
            "which collection, by id", "CarPlay", "pockets and playlists", "when you added them", "ids only"))
            assertTrue("missing: $k", c.contains(k))
    }

    @Test fun consentMatchesIosCanonicalText() {
        // The iOS source is two levels above android/ in the repo; skip silently if the layout differs.
        val f = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "apple/PocketDJ/State/ListeningPocketsService.swift") }.firstOrNull { it.exists() } ?: return
        val src = f.readText()
        val start = src.indexOf("static let consentText")
        val block = src.substring(start, src.indexOf("\n\n", start))
        val ios = Regex("\"((?:[^\"\\\\]|\\\\.)*)\"").findAll(block.substringAfter("=")).joinToString("") { it.groupValues[1] }
        assertEquals(ios, PocketsOptInCopy.CONSENT)
    }

    @Test fun needsRecsNoteVisibility() {
        assertTrue(PocketsOptInCopy.showNeedsRecs(false))
        assertFalse(PocketsOptInCopy.showNeedsRecs(true))
    }

    @Test fun unavailableCopyMatchesIos() {
        assertEquals("In the Pocket isn't available.", InThePocketScreenLogic.UNAVAILABLE_TEXT)
    }

    @Test fun micDisabledWhileRequesting() {
        assertFalse(InThePocketScreenLogic.micEnabled(denied = false, unavailable = false, requesting = true))
        assertTrue(InThePocketScreenLogic.micEnabled(denied = false, unavailable = false))
    }

    private class Gate : FeedbackSpeechEngine {
        override val isAvailable = true
        val gate = CompletableDeferred<FeedbackDictationAuthorization>()
        var auths = 0
        var onFinish: ((String?) -> Unit)? = null
        override suspend fun requestAuthorization(): FeedbackDictationAuthorization { auths++; return gate.await() }
        override fun start(onTranscript: (String) -> Unit, onFinish: (String?) -> Unit) { this.onFinish = onFinish }
        override fun stop() {}
    }

    @Test fun secondTapWhileRequestingIsIgnored() = runBlocking {
        val e = Gate()
        val c = FeedbackDictationController(e)
        val first = async { c.toggle("") { } }
        while (c.state.value != State.Requesting) kotlinx.coroutines.yield()
        c.toggle("") { }
        assertEquals(1, e.auths)
        e.gate.complete(FeedbackDictationAuthorization.AUTHORIZED)
        first.await()
        assertEquals(State.Listening, c.state.value)
    }

    @Test fun languagePackMissingMapsToUnavailable() = runBlocking {
        val e = Gate().also { it.gate.complete(FeedbackDictationAuthorization.AUTHORIZED) }
        val c = FeedbackDictationController(e)
        c.toggle("") { }
        e.onFinish!!(FeedbackDictationController.UNAVAILABLE_MARKER)
        assertEquals(State.Unavailable, c.state.value)
        assertEquals(FeedbackDictationController.UNAVAILABLE_TEXT, c.explanation)
    }
}
