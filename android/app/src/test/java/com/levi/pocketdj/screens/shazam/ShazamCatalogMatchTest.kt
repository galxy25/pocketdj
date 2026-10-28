package com.levi.pocketdj.screens.shazam

import com.levi.pocketdj.data.catalog.IndexSong
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CompletableDeferred
import org.junit.Test
import org.junit.Assert.assertEquals

import org.junit.Assert.assertTrue

@Suppress("UNCHECKED_CAST")
private inline fun <reified T> assertIs(v: Any?): T {
    org.junit.Assert.assertTrue("expected ${T::class.simpleName} but was $v", v is T)
    return v as T
}

class ShazamCatalogMatchTest {
    private fun song(id: String, name: String, artist: String) = IndexSong(id = id, artist = artist, name = name)
    private fun hit(t: String?, a: String?) = ShazamHitInfo(t, a, null, null)

    @Test fun normFoldsDiacriticsAndCase() {
        assertEquals("cafe", ShazamCatalogMatch.norm("Café"))
        assertEquals(ShazamCatalogMatch.norm("Café"), ShazamCatalogMatch.norm("CAFE"))
    }

    @Test fun normDropsParenAndBracketTails() {
        assertEquals("song", ShazamCatalogMatch.norm("Song (feat. Someone)"))
        assertEquals("song", ShazamCatalogMatch.norm("Song [Remastered 2011]"))
        assertEquals("cafe", ShazamCatalogMatch.norm("Café (Remastered 2011)"))
    }

    @Test fun normDropsDashEditionClauseButNotPlainDash() {
        assertEquals("song", ShazamCatalogMatch.norm("Song - Remastered 2009"))
        assertEquals("song", ShazamCatalogMatch.norm("Song - Live at Wembley"))
        assertEquals("song title", ShazamCatalogMatch.norm("Song - Title"))
    }

    @Test fun normStripsPunctuationAndCollapsesSpaces() {
        assertEquals("rock n roll", ShazamCatalogMatch.norm("  Rock  'n'   Roll!! "))
        assertEquals("", ShazamCatalogMatch.norm("(only paren)"))
    }

    @Test fun resolveMatchesAcrossEditionNoise() {
        val songs = listOf(song("s1", "Cafe", "Artist"))
        val m = ShazamCatalogMatch.resolve(hit("Café (Remastered 2011)", "Artist"), songs)
        assertEquals("s1", assertIs<ShazamMatch.InCatalog>(m).song.id)
    }

    @Test fun artistContainmentEitherDirection() {
        val songs = listOf(song("s1", "Track", "Artist feat. Guest"))
        assertIs<ShazamMatch.InCatalog>(ShazamCatalogMatch.resolve(hit("Track", "Artist"), songs))
        val songs2 = listOf(song("s2", "Track", "Artist"))
        assertIs<ShazamMatch.InCatalog>(ShazamCatalogMatch.resolve(hit("Track", "Artist & Friends"), songs2))
        assertIs<ShazamMatch.NotInCatalog>(ShazamCatalogMatch.resolve(hit("Track", "Other"), songs2))
    }

    @Test fun noArtistMatchesOnTitleAlone() {
        val songs = listOf(song("s1", "Track", "Anyone"))
        assertIs<ShazamMatch.InCatalog>(ShazamCatalogMatch.resolve(hit("Track", null), songs))
        assertIs<ShazamMatch.InCatalog>(ShazamCatalogMatch.resolve(hit("Track", "  "), songs))
    }

    @Test fun firstHitWinsAndBlankTitleNeverMatches() {
        val songs = listOf(song("a", "Track", "X"), song("b", "Track", "X"))
        assertEquals("a", (ShazamCatalogMatch.resolve(hit("Track", "X"), songs) as ShazamMatch.InCatalog).song.id)
        assertIs<ShazamMatch.NotInCatalog>(ShazamCatalogMatch.resolve(hit(null, "X"), songs))
        assertIs<ShazamMatch.NotInCatalog>(ShazamCatalogMatch.resolve(hit("(...)", "X"), songs))
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ShazamRecognizerTest {
    private fun hit() = ShazamHitInfo("Track", "X", null, "123")

    @Test fun matchedPhaseResolvesAgainstCatalog() = runTest {
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val r = ShazamRecognizer(scope, { RecognitionResult.Hit(hit()) }, { true },
            songs = { listOf(IndexSong(id = "s1", artist = "X", name = "Track")) })
        r.start()
        assertIs<ShazamMatch.InCatalog>(assertIs<ShazamPhase.Matched>(r.phase.value).match)
    }

    @Test fun permissionDeniedGoesToDeniedAndTapOpensSettings() = runTest {
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val r = ShazamRecognizer(scope, { RecognitionResult.NoMatch }, { false }, songs = { emptyList() })
        assertEquals(ShazamTap.STARTED, r.tap())
        assertEquals(ShazamPhase.Denied, r.phase.value)
        assertEquals(ShazamTap.OPEN_SETTINGS, r.tap())
    }

    @Test fun secondTapWhileListeningCancels() = runTest {
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val gate = CompletableDeferred<RecognitionResult>()
        val r = ShazamRecognizer(scope, { gate.await() }, { true }, songs = { emptyList() }, recognizingAfterMs = 10_000)
        assertEquals(ShazamTap.STARTED, r.tap())
        assertEquals(ShazamPhase.Listening, r.phase.value)
        assertEquals(ShazamTap.CANCELLED, r.tap())
        assertEquals(ShazamPhase.Idle, r.phase.value)
        gate.complete(RecognitionResult.NoMatch) // a late result must not resurrect a cancelled run
        assertEquals(ShazamPhase.Idle, r.phase.value)
    }

    @Test fun movesToRecognizingThenNoMatch() = runTest {
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val gate = CompletableDeferred<RecognitionResult>()
        val r = ShazamRecognizer(scope, { gate.await() }, { true }, songs = { emptyList() }, recognizingAfterMs = 600)
        r.start()
        scope.testScheduler.advanceTimeBy(601)
        assertEquals(ShazamPhase.Recognizing, r.phase.value)
        gate.complete(RecognitionResult.NoMatch)
        assertEquals(ShazamPhase.NoMatch, r.phase.value)
    }

    @Test fun gatedWhileMixRecording() = runTest {
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        var recording = true
        val r = ShazamRecognizer(scope, { RecognitionResult.NoMatch }, { true }, songs = { emptyList() }, blocked = { recording })
        assertEquals(ShazamTap.BLOCKED, r.tap())
        assertEquals(ShazamPhase.Idle, r.phase.value)
        recording = false
        assertEquals(ShazamTap.STARTED, r.tap())
        assertTrue(r.phase.value is ShazamPhase.NoMatch)
    }

    @Test fun backendErrorFails() = runTest {
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val r = ShazamRecognizer(scope, { RecognitionResult.Error("boom") }, { true }, songs = { emptyList() })
        r.start()
        assertEquals(ShazamPhase.Failed("boom"), r.phase.value)
        r.reset()
        assertEquals(ShazamPhase.Idle, r.phase.value)
    }
}
