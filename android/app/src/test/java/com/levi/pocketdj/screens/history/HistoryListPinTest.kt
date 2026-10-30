package com.levi.pocketdj.screens.history

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HistoryListPinTest {
    @Test fun readerAtTop_followsTheNewLiveRow() {
        assertTrue(HistoryListPin.shouldPinToTop("ev1", "ev2", visibleFirstKey = "ev1", visibleFirstOffset = 0))
    }

    @Test fun readerScrolledDown_keepsTheirPlace() {
        assertFalse(HistoryListPin.shouldPinToTop("ev1", "ev2", visibleFirstKey = "ev7", visibleFirstOffset = 0))
        assertFalse(HistoryListPin.shouldPinToTop("ev1", "ev2", visibleFirstKey = "ev1", visibleFirstOffset = 40))
    }

    @Test fun noChangeOrFirstComposition_isLeftAlone() {
        assertFalse(HistoryListPin.shouldPinToTop("ev1", "ev1", "ev1", 0))
        assertFalse(HistoryListPin.shouldPinToTop(null, "ev1", null, 0))
        assertFalse(HistoryListPin.shouldPinToTop("ev1", null, "ev1", 0))
    }
}
