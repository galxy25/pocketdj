package com.levi.pocketdj.screens.collections

import org.junit.Assert.assertEquals
import org.junit.Test

class AddToSheetParamsTest {
    @Test
    fun defaultAddDismissesAndFiresOnAdded() {
        assertEquals(TapOutcome(remove = false, fireOnAdded = true, dismiss = true), AddToSheetParams.tapOutcome(false, true, false))
    }

    @Test
    fun stayOpenAddFiresButDoesNotDismiss() {
        assertEquals(TapOutcome(remove = false, fireOnAdded = true, dismiss = false), AddToSheetParams.tapOutcome(false, true, true))
    }

    @Test
    fun removeNeverFiresOrDismisses() {
        assertEquals(TapOutcome(remove = true, fireOnAdded = false, dismiss = false), AddToSheetParams.tapOutcome(true, false, false))
        assertEquals(TapOutcome(remove = true, fireOnAdded = false, dismiss = false), AddToSheetParams.tapOutcome(true, true, true))
    }

    @Test
    fun emptyBatchFiresNothingAndStaysOpen() {
        assertEquals(TapOutcome(remove = false, fireOnAdded = false, dismiss = false), AddToSheetParams.tapOutcome(false, false, false))
    }
}
