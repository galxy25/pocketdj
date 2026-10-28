package com.levi.pocketdj.playback

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * SURF-8 regression: the session callback must grant the LIBRARY command set, else every MediaBrowser
 * (Android Auto) call returns RESULT_ERROR_PERMISSION_DENIED (-4) and the browse tree never renders.
 * (Found on the emulator with a real media3 MediaBrowser; JVM tests can't bind the service.)
 */
class SessionLibraryCommandsGuardTest {
    @Test fun onConnectGrantsLibraryCommands() {
        val f = listOf("src/main/java", "app/src/main/java").map { File(it, "com/levi/pocketdj/playback/PlaybackService.kt") }.first { it.exists() }
        val src = f.readText()
        assertTrue(src.contains("DEFAULT_SESSION_AND_LIBRARY_COMMANDS"))
        assertTrue(!src.contains("ConnectionResult.DEFAULT_SESSION_COMMANDS"))
    }
}
