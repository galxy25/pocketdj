package com.levi.pocketdj.screens.history

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Test

class WheelPauseWiringTest {
    @Test fun pauseActionRunsPause() {
        var n = 0
        wheelPauseAction(CoroutineScope(Dispatchers.Unconfined)) { n++ }.invoke()
        assertEquals(1, n)
    }

    @Test fun pauseFailureIsSwallowed() {
        wheelPauseAction(CoroutineScope(Dispatchers.Unconfined)) { error("boom") }.invoke()
    }
}
