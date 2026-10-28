package com.levi.pocketdj.data.rips

import java.nio.file.Files
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RipsRepositoryGenerationTest {

    private fun repo(scope: kotlinx.coroutines.CoroutineScope) = RipsRepository(
        cacheDir = Files.createTempDirectory("rips").toFile(),
        http = OkHttpClient(),
        scope = scope,
    )

    private val old = """{"a":{"key":"rips/a.mp3"}}"""
    private val new = """{"a":{"key":"rips/a.mp3"},"b":{"key":"rips/b.mp3"}}"""

    @Test
    fun olderResponseCompletingAfterNewerIsDiscarded() = runTest {
        val r = repo(backgroundScope)
        val g1 = r.stampArrival() // older request arrives first...
        val g2 = r.stampArrival() // ...newer arrives second but its decode finishes first
        r.adopt(g2, new)
        assertEquals(setOf("a", "b"), r.manifest.value.keys)
        r.adopt(g1, old) // late older decode must not clobber
        assertEquals(setOf("a", "b"), r.manifest.value.keys)
        assertTrue(r.isPlayable("b"))
    }

    @Test
    fun identicalManifestDoesNotReEmit() = runTest {
        val r = repo(backgroundScope)
        val emissions = mutableListOf<Int>()
        val job = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            r.manifest.collect { emissions += it.size }
        }
        r.adopt(r.stampArrival(), new)
        val same = r.manifest.value
        r.adopt(r.stampArrival(), new)
        assertEquals(listOf(0, 2), emissions)
        assertTrue(same === r.manifest.value)
        job.cancel()
    }

    @Test
    fun adoptedManifestIsPersisted_forTheNextLaunch() = runTest {
        val dir = Files.createTempDirectory("rips").toFile()
        val r = RipsRepository(dir, OkHttpClient(), scope = backgroundScope)
        r.adopt(r.stampArrival(), old)
        assertNotNull(java.io.File(dir, "rips-manifest.json").takeIf { it.isFile })
    }
}
