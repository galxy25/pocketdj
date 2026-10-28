package com.levi.pocketdj.data.recs

import java.io.File
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse

class RecGenreBucketTest {
    @Test fun collapsesWhitespaceIncludingNbsp() {
        assertEquals("hip hop", RecSoundAdmit.genreBucket("Hip   Hop"))
        assertEquals(null as String?, RecSoundAdmit.genreBucket("   "))
    }

    /** Android's ICU regex rejects the JVM-only `(?U)` flag (crashed For You refresh on device). */
    @Test fun noJvmOnlyRegexFlagsInMainSources() {
        val root = File("src/main/java").takeIf { it.exists() } ?: File("app/src/main/java")
        val bad = root.walkTopDown().filter { it.extension == "kt" && it.readText().contains("(?U)") }.toList()
        assertFalse("ICU-incompatible (?U) in: $bad", bad.isNotEmpty())
    }
}
