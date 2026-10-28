package com.levi.pocketdj.screens.history

import org.junit.Assert.assertEquals
import org.junit.Test

class CatalogAddHeadlineTest {
    @Test
    fun nilAndConfirmedClaimLibrary() {
        assertEquals("Added X to your library", catalogAddHeadline("X", null))
        assertEquals("Added X to your library", catalogAddHeadline("X", "confirmed"))
        assertEquals("Added X to your library", catalogAddHeadline("X", "confirmed (web)"))
    }

    @Test
    fun failureAnnotationIsShown() {
        assertEquals(
            "Added X to PocketDJ (Apple Music write failed: nope)",
            catalogAddHeadline("X", "Apple Music write failed: nope"),
        )
    }
}
