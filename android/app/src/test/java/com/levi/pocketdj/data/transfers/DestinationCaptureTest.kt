package com.levi.pocketdj.data.transfers

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.burns.BurnDestinationResolver
import com.levi.pocketdj.data.burns.FakeTree
import java.io.File
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DestinationCaptureTest {
    private val server = MockWebServer().apply { start() }
    private val base = tmpTransferDir()
    private val app = File(base, "burns")
    private val stage = File(base, "burns-user")
    private val tree = FakeTree()
    private val openCalls = ArrayList<String>()
    private val resolver = BurnDestinationResolver(app, stage) { uri -> openCalls += uri; if (uri == "content://tree/sd") tree else null }

    @After fun tearDown() = server.shutdown()

    private fun userRec(id: String, uri: String? = "content://tree/sd") =
        rec(id).copy(wasAppStorage = false, burnFolderTreeUri = uri)

    private suspend fun run(r: TransferRecord): Pair<TransferCoordinator, List<TransferRecord>> {
        server.enqueue(MockResponse().setBody(Buffer().write(ByteArray(6_000) { 9 })))
        val c = TransferCoordinator(File(base, "t.json"), FakeTransferWork())
        c.enqueue(server.url("/a").toString(), r)
        val done = ArrayList<TransferRecord>()
        c.onBurnFinalized = { rec, _ -> done += rec }
        val runner = BurnDownloadRunner(c, OkHttpClient(), { app }, resolver = resolver)
        assertEquals(BurnDownloadRunner.Result.SUCCESS, runner.run(r.songId, server.url("/a").toString(), false, 0))
        return c to done
    }

    @Test fun appStorageRecordNeverTouchesTree() = runTest {
        val (_, done) = run(rec("s1"))
        assertTrue(File(app, "s1.mp3").isFile)
        assertTrue(tree.files.isEmpty())
        assertTrue(done.single().wasAppStorage)
        assertTrue(openCalls.isEmpty())
    }

    @Test fun userFolderRecordLandsInTreeAndStaysUserFolder() = runTest {
        val (_, done) = run(userRec("s1"))
        assertEquals(setOf("s1.mp3", "s1.txt"), tree.files.keys)
        assertEquals(6_000, tree.files.getValue("s1.mp3").size)
        assertTrue(File(stage, "s1.mp3").isFile) // local playback copy
        assertFalse(File(app, "s1.mp3").exists())
        assertFalse(done.single().wasAppStorage)
    }

    @Test fun unavailableTreeFallsBackToAppStorageAndRecordsIt() = runTest {
        tree.reachable = false
        val (_, done) = run(userRec("s1"))
        assertTrue(File(app, "s1.mp3").isFile)
        assertTrue(File(app, "s1.txt").isFile)
        assertTrue(tree.files.isEmpty())
        assertTrue("item must record wasAppStorage=true", done.single().wasAppStorage)
    }

    @Test fun unknownTreeUriAndMissingUriFallBack() = runTest {
        val (_, d1) = run(userRec("s1", "content://tree/gone"))
        assertTrue(d1.single().wasAppStorage)
        val (_, d2) = run(userRec("s2", null))
        assertTrue(d2.single().wasAppStorage)
        assertTrue(File(app, "s2.mp3").isFile)
    }

    @Test fun copyFailureKeepsStagedFilesAndUserFolderFlag() = runTest {
        tree.failCopies = true
        val (_, done) = run(userRec("s1"))
        // Staged files are local + playable (and possibly shared with analog siblings): never moved.
        assertFalse(done.single().wasAppStorage)
        assertTrue(File(stage, "s1.mp3").isFile)
        assertFalse(File(app, "s1.mp3").exists())
    }

    @Test fun destinationComesFromRecordNotLiveSettings() {
        // The resolver has no settings handle at all: the same record resolves identically
        // regardless of what the user picks afterwards.
        val a = resolver.resolve(userRec("s1"))
        val b = resolver.resolve(userRec("s1"))
        assertEquals(stage, a.dir); assertEquals(stage, b.dir)
        assertFalse(a.fellBack)
        assertNull(resolver.resolve(rec("s2")).tree)
    }

    @Test fun treeUriRoundTripsAndOldDocsDecode() {
        val r = userRec("s1")
        val back = PdjJson.lenient.decodeFromString(TransferRecord.serializer(), PdjJson.lenient.encodeToString(TransferRecord.serializer(), r))
        assertEquals("content://tree/sd", back.burnFolderTreeUri)
        assertFalse(back.wasAppStorage)
        val old = PdjJson.lenient.decodeFromString(
            TransferRecord.serializer(), """{"songId":"x","audioFileName":"x.mp3","wasAppStorage":true}""",
        )
        assertNull(old.burnFolderTreeUri)
    }
}
