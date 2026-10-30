package com.levi.pocketdj.specs

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guards the ANS-VERIFY-1 classification table against stale CODE-gap claims. */
class AnswersProgressLedgerTest {
    private fun root(): File =
        listOf(File("."), File("..")).first { File(it, "specs/answers/PROGRESS.md").exists() || File(it, "app/src/main").exists() }

    private val progress get() = File(root(), "specs/answers/PROGRESS.md").readText()
    private fun src(rel: String) = File(root(), "app/src/main/java/com/levi/pocketdj/$rel").readText()

    @Test fun closedGapsAreNotClaimedAsCode() {
        listOf("no catalogAdd producer", "noteSkip per-song count unwired", "storage prune measure-only",
            "backup/profile-sync registration and remapSongIds caller").forEach {
            assertFalse("stale claim: $it", progress.contains(it))
        }
    }

    @Test fun closedGapsStillExistInCode() {
        assertTrue(src("di/PlaybackGraph.kt").contains("playStats.noteSkipped"))
        assertTrue(src("di/MixGraph.kt").contains("playStats.noteSkipped"))
        assertTrue(src("di/CollectionsGraph.kt").contains("SyncEntry(\"favorites\""))
        assertTrue(src("di/BrowseGraph.kt").contains("ActivityKind.CATALOG_ADD"))
        assertTrue(src("work/WorkScheduler.kt").contains("pruneIfDue"))
    }

    @Test fun everyPartialRowIsClassified() {
        listOf("BRW-7", "SVC-8").forEach { assertTrue("missing $it", progress.contains("| $it |")) }
    }
}
