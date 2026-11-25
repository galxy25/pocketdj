package com.levi.pocketdj.assistant

import com.levi.pocketdj.data.collections.NOW_PLAYING_PLAYLIST_ID
import com.levi.pocketdj.shell.PinShortcutSpec
import com.levi.pocketdj.shell.PlayKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AssistContentTest {
    @Test fun jsonLdShape() {
        assertEquals(
            "{\"@context\":\"https://schema.org\",\"@type\":\"MusicRecording\",\"name\":\"Song\"," +
                "\"byArtist\":{\"@type\":\"MusicGroup\",\"name\":\"Drake\"}}",
            AssistContent.musicRecordingJsonLd("Song", "Drake"),
        )
    }

    @Test fun jsonLdOmitsArtistWhenBlankAndNullWithoutTitle() {
        assertEquals(
            "{\"@context\":\"https://schema.org\",\"@type\":\"MusicRecording\",\"name\":\"Song\"}",
            AssistContent.musicRecordingJsonLd(" Song ", "  "),
        )
        assertNull(AssistContent.musicRecordingJsonLd(null, "x"))
        assertNull(AssistContent.musicRecordingJsonLd("  ", "x"))
    }

    @Test fun jsonLdEscapes() {
        val j = AssistContent.musicRecordingJsonLd("say \"hi\" \\ end\nx", "A\tB")!!
        assertTrue(j, j.contains("""say \"hi\" \\ end\nx""""))
        assertTrue(j.contains("A\\tB"))
        assertEquals("\"\\u0001\"", AssistContent.quote("\u0001"))
    }

    @Test fun onlyWhileNowPlayingVisible() {
        assertNull(AssistContent.forNowPlaying(false, "Song", "A"))
        assertTrue(AssistContent.forNowPlaying(true, "Song", "A")!!.contains("MusicRecording"))
    }

    @Test fun searchActionQuery() {
        val ex = mapOf("query" to "  drake ")
        assertEquals("drake", SearchActionQuery.parse(SearchActionQuery.GMS_SEARCH_ACTION) { ex[it] })
        assertEquals("drake", SearchActionQuery.parse(SearchActionQuery.MEDIA_SEARCH) { ex[it] })
        assertNull(SearchActionQuery.parse("android.intent.action.VIEW") { ex[it] })
        assertNull(SearchActionQuery.parse(SearchActionQuery.MEDIA_SEARCH) { "   " })
        assertNull(SearchActionQuery.parse(SearchActionQuery.MEDIA_SEARCH) { null })
    }

    @Test fun pinShortcutRules() {
        assertFalse(PinShortcutSpec.canPin(NOW_PLAYING_PLAYLIST_ID, "Now Playing"))
        assertFalse(PinShortcutSpec.canPin("p1", "  "))
        assertTrue(PinShortcutSpec.canPin("p1", "Warmup"))
        assertEquals("Warmup", PinShortcutSpec.label(" Warmup "))
        val long = PinShortcutSpec.label("A very long collection name indeed")
        assertEquals(25, long.length)
        assertTrue(long.endsWith("…"))
        assertEquals("pin_pocket_p1", PinShortcutSpec.shortcutId(PlayKind.Pocket, "p1"))
        assertEquals("pocketdj://play/pocket/a%20b", PinShortcutSpec.deepLink(PlayKind.Pocket, "a b"))
    }

    @Test
    fun visibilityDerivedFromRoute() {
        assertTrue(AssistContent.isNowPlayingVisible("np", "np"))
        assertTrue(!AssistContent.isNowPlayingVisible("browse", "np"))
        assertTrue(!AssistContent.isNowPlayingVisible(null, "np"))
    }
}
