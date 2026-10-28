package com.levi.pocketdj.auto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AutoArtworkTest {
    @Test fun httpsKept_httpUpgraded_othersDropped() {
        assertEquals("https://a/b.jpg", AutoArtwork.httpsOrNull(" https://a/b.jpg "))
        assertEquals("https://a/b.jpg", AutoArtwork.httpsOrNull("http://a/b.jpg"))
        assertNull(AutoArtwork.httpsOrNull("file:///x.jpg"))
        assertNull(AutoArtwork.httpsOrNull("/relative.jpg"))
        assertNull(AutoArtwork.httpsOrNull(null))
        assertNull(AutoArtwork.httpsOrNull(""))
    }

    @Test fun pick_firstUsableCandidate() {
        assertEquals("https://cdn/1.jpg", AutoArtwork.pick(listOf("data:xyz", "https://cdn/1.jpg", "https://cdn/2.jpg")))
        assertNull(AutoArtwork.pick(listOf("data:xyz")))
    }
}
