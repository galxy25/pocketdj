package com.levi.pocketdj.studio.engine

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The process ON_STOP observer that silences Studio voices is installed lazily by the player getters. A player the
 * observer stops must install it itself: otherwise opening only that player (e.g. the stem-carve sheet's audition on a
 * fresh launch) leaves it playing in the background with no notification.
 */
class StudioBackgroundStopGuardTest {
    private fun graph(): String {
        val rel = "app/src/main/java/com/levi/pocketdj/di/StudioGraph.kt"
        return listOf(File(rel), File("android/$rel"), File("../$rel")).first { it.exists() }.readText()
    }

    @Test fun everyPlayerStoppedOnBackgroundInstallsTheObserver() {
        val src = graph()
        val observer = src.substringAfter("private fun ensureLoopStopObserver()").substringBefore("\n    }\n")
        val stopped = Regex("""if \((\w+)Lazy\.isInitialized\(\)\) (\w+)""").findAll(observer).map { it.groupValues[1] to it.groupValues[2] }.toList()
        assertTrue("observer parsed", stopped.size >= 5)
        for ((lazy, getter) in stopped) {
            val decl = Regex("""val $getter:[^\n]*get\(\) = ${lazy}Lazy\.value([^\n]*)""").find(src)
            assertTrue("$getter getter not found", decl != null)
            assertTrue("$getter is stopped on background but its getter never installs the observer", decl!!.groupValues[1].contains("ensureLoopStopObserver()"))
        }
    }
}
