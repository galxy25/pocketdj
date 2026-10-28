package com.levi.pocketdj.data.applemusic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WriteBackMatchKeyUnicodeTest {
    @Test fun supplementaryPlaneLettersSurvive() {
        // U+1D400 MATHEMATICAL BOLD CAPITAL A is a letter outside the BMP.
        assertTrue(WriteBackMatcher.matchKey("𝐀 x!", keepVersion = true).codePointCount(0, 3) >= 2)
    }

    @Test fun combiningSpacingMarksKept() {
        // Devanagari "ki": KA + vowel sign I (Mc) must not collapse to just KA.
        val key = WriteBackMatcher.matchKey("कि", keepVersion = true)
        assertEquals("कि", key)
    }
}
