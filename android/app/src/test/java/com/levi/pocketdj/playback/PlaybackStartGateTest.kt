package com.levi.pocketdj.playback

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackStartGateTest {
    @Test fun systemUiBootResumptionBindDoesNotStartTheGraph() {
        assertFalse(PlaybackStartGate.startsGraph("com.android.systemui"))
    }

    @Test fun realControllersStartTheGraph() {
        for (pkg in listOf(
            "com.levi.pocketdj",                        // in-app MediaController / widget
            "com.google.android.projection.gearhead", // Android Auto
            "android.media.session.MediaController",  // Media3 legacy controller (media-button cold start)
            "com.google.android.googlequicksearchbox", // Assistant
        )) assertTrue(pkg, PlaybackStartGate.startsGraph(pkg))
    }

    @Test fun unknownPackageStartsTheGraph() {
        assertTrue(PlaybackStartGate.startsGraph(null))
        assertTrue(PlaybackStartGate.startsGraph(""))
    }
}
