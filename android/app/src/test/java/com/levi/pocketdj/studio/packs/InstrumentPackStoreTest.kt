package com.levi.pocketdj.studio.packs

import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.store.DefaultStudioRoots
import com.levi.pocketdj.studio.store.StudioFamily
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class InstrumentPackStoreTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer
    private lateinit var roots: DefaultStudioRoots
    private lateinit var cache: File
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val bytes = ByteArray(300_000) { (it * 31).toByte() }
    private val sha = java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun indexJson(sha256: String = sha) = """
        {"version":1,"attribution":"GeneralUser GS (c) S. Christian Collins",
         "sharedBanks":[{"key":"banks/GeneralUser GS 2.0.3.sf2","bytes":${bytes.size},"sha256":"$sha256"},{"bytes":5}],
         "packs":[
          {"id":"piano","name":"Piano","instrument":"piano","program":0,"bankKey":"banks/GeneralUser GS 2.0.3.sf2","bytes":${bytes.size}},
          {"id":"violin","instrument":"violin","bankKey":"banks/GeneralUser GS 2.0.3.sf2"},
          {"id":"theremin","name":"Theremin","instrument":"theremin","bankKey":"banks/x.sf2"},
          {"name":"no id","instrument":"harp"}
         ]}""".trimIndent()

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
        roots = DefaultStudioRoots(tmp.newFolder("studio"))
        cache = File(tmp.newFolder("cache"), "instruments-index.json")
    }

    @After fun tearDown() { server.shutdown() }

    private fun store(cacheFile: File = cache) = InstrumentPackStore(
        roots, cacheFile, scope,
        indexUrl = { server.url("/rips/instruments/index.json").toString() },
        bankUrl = { server.url("/rips/instruments/$it").toString() },
    )

    @Test fun decodeIsLossyPerPackAndPerBank() {
        val idx = InstrumentPackIndex.decode(indexJson())!!
        assertEquals(1, idx.version)
        assertEquals(1, idx.sharedBanks.size)                         // bank without key dropped
        assertEquals(listOf("piano", "violin"), idx.packs.map { it.id }) // unknown instrument + id-less dropped
        assertEquals("Violin", idx.packs[1].name)                      // name defaults to instrument display name
        assertEquals(40, idx.packs[1].program)                         // program defaults to GM program
        assertEquals("GeneralUser GS (c) S. Christian Collins", idx.attribution)
    }

    @Test fun decodeGarbageAndWrongShapes() {
        assertTrue(InstrumentPackIndex.decode("<html>403</html>")?.packs.orEmpty().isEmpty()); assertNull(InstrumentPackIndex.decode("{\"packs\": ["))
        assertTrue(InstrumentPackIndex.decode("[1,2]")!!.packs.isEmpty())
        val idx = InstrumentPackIndex.decode("""{"version":"x","packs":"nope","sharedBanks":[1,{"key":"k"}]}""")!!
        assertEquals(0, idx.version); assertTrue(idx.packs.isEmpty()); assertEquals("k", idx.sharedBanks.single().key)
    }

    @Test fun slugAndLocalNameAreStrictParserSafe() {
        assertEquals("generaluser-gs-2.0.3", InstrumentBankNaming.slug("banks/GeneralUser GS 2.0.3.sf2"))
        assertEquals("a-b", InstrumentBankNaming.slug("x/a   b.SF2"))
        assertEquals("bank", InstrumentBankNaming.slug("banks/???.sf2"))
        assertEquals("instrument-generaluser-gs-2.0.3.sf2", InstrumentBankNaming.localFileName("banks/GeneralUser GS 2.0.3.sf2"))
    }

    @Test fun refreshIndexUsesBankKeyRelativeAndCachesValidatedBody() = runBlocking {
        server.enqueue(MockResponse().setBody(indexJson()))
        val s = store()
        s.refreshIndex()
        assertEquals(2, s.state.value.packs.size)
        assertTrue(cache.isFile)
        // Offline: a fresh store lists packs from the disk cache with no network.
        server.shutdown()
        val offline = store()
        assertEquals(2, offline.state.value.packs.size)
        assertEquals("GeneralUser GS (c) S. Christian Collins", offline.state.value.attribution)
    }

    @Test fun badIndexNeverReplacesGoodCache() = runBlocking {
        server.enqueue(MockResponse().setBody(indexJson()))
        val s = store(); s.refreshIndex()
        server.enqueue(MockResponse().setResponseCode(403).setBody("denied"))
        s.refreshIndex()
        assertEquals(2, s.state.value.packs.size)
        server.enqueue(MockResponse().setBody("""{"version":2,"packs":[]}"""))   // gutted future doc
        s.refreshIndex()
        assertEquals(2, s.state.value.packs.size)
        assertEquals(1, InstrumentPackIndex.decode(cache.readText())!!.version)
        assertFalse(s.state.value.isRefreshing)
    }

    @Test fun downloadRequestsRelativeKeyVerifiesAndInstallsAtomically() = runBlocking {
        server.enqueue(MockResponse().setBody(indexJson()))
        server.enqueue(MockResponse().setBody(Buffer().write(bytes)))
        val s = store(); s.refreshIndex()
        server.takeRequest()
        val piano = s.state.value.packs.first { it.instrument == InstrumentKey.PIANO }
        withTimeout(10_000) { s.download(piano)!!.join() }
        val req = server.takeRequest()
        assertEquals("/rips/instruments/banks/GeneralUser%20GS%202.0.3.sf2", req.path)   // key appended to the base, relative
        assertTrue(s.state.value.isDownloaded(piano))
        val f = s.localBankFile(piano)!!
        assertEquals("instrument-generaluser-gs-2.0.3.sf2", f.name)
        assertEquals(bytes.size.toLong(), f.length())
        // no staging debris
        assertEquals(listOf(f.name), roots.appDir(StudioFamily.INSTRUMENTS).list())
        assertEquals(bytes.size.toLong(), s.usageBytes())
        assertNull(s.state.value.error(piano))
        assertNull(s.state.value.progress(piano))
    }

    @Test fun secondPackSharingABankIsInstantNoSecondRequest() = runBlocking {
        server.enqueue(MockResponse().setBody(indexJson()))
        server.enqueue(MockResponse().setBody(Buffer().write(bytes)))
        val s = store(); s.refreshIndex()
        val (piano, violin) = s.state.value.packs
        withTimeout(10_000) { s.download(piano)!!.join() }
        assertTrue(s.state.value.isDownloaded(violin))        // same bank => already downloaded
        assertNull(s.download(violin))                         // no job, no request
        assertEquals(2, server.requestCount)                   // index + one bank
        assertNotNull(s.localBankFile(InstrumentKey.VIOLIN))
    }

    @Test fun shaMismatchRejectsInstallAndLeavesNothing() = runBlocking {
        server.enqueue(MockResponse().setBody(indexJson("0".repeat(64))))
        server.enqueue(MockResponse().setBody(Buffer().write(bytes)))
        val s = store(); s.refreshIndex()
        val piano = s.state.value.packs.first()
        withTimeout(10_000) { s.download(piano)!!.join() }
        assertFalse(s.state.value.isDownloaded(piano))
        assertEquals("Downloaded file failed verification", s.state.value.error(piano))
        assertTrue(roots.appDir(StudioFamily.INSTRUMENTS).list().isEmpty())
    }

    @Test fun cancelStopsTheDownloadAndNeverInstalls() = runBlocking {
        server.enqueue(MockResponse().setBody(indexJson()))
        server.enqueue(MockResponse().setBody(Buffer().write(bytes)).throttleBody(30_000, 100, java.util.concurrent.TimeUnit.MILLISECONDS))
        val s = store(); s.refreshIndex()
        val piano = s.state.value.packs.first()
        val job = s.download(piano)!!
        withTimeout(10_000) { while ((s.state.value.progress(piano) ?: 0.0) <= 0.0) kotlinx.coroutines.delay(10) }
        s.cancelDownload(piano)
        assertNull(s.state.value.progress(piano))                      // progress clears at once
        withTimeout(10_000) { job.join() }
        assertFalse(s.state.value.isDownloaded(piano))
        assertNull(s.state.value.error(piano))                         // a user cancel is not an error
        assertTrue(roots.appDir(StudioFamily.INSTRUMENTS).list().isEmpty())
    }

    @Test fun httpErrorSurfacesAndRetryClearsIt() = runBlocking {
        server.enqueue(MockResponse().setBody(indexJson()))
        server.enqueue(MockResponse().setResponseCode(403))
        server.enqueue(MockResponse().setBody(Buffer().write(bytes)))
        val s = store(); s.refreshIndex()
        val piano = s.state.value.packs.first()
        withTimeout(10_000) { s.download(piano)!!.join() }
        assertEquals("Download failed", s.state.value.error(piano))
        withTimeout(10_000) { s.download(piano)!!.join() }
        assertNull(s.state.value.error(piano))
        assertTrue(s.state.value.isDownloaded(piano))
    }

    @Test fun missingShaInstallsUnverified() = runBlocking {
        server.enqueue(MockResponse().setBody(indexJson("")))
        server.enqueue(MockResponse().setBody(Buffer().write(bytes)))
        val s = store(); s.refreshIndex()
        withTimeout(10_000) { s.download(s.state.value.packs.first())!!.join() }
        assertTrue(s.state.value.isDownloaded(s.state.value.packs.first()))
    }

    @Test fun deleteBankFlipsEveryPackBackToDownloadable() = runBlocking {
        server.enqueue(MockResponse().setBody(indexJson()))
        server.enqueue(MockResponse().setBody(Buffer().write(bytes)))
        val s = store(); s.refreshIndex()
        val (piano, violin) = s.state.value.packs
        withTimeout(10_000) { s.download(piano)!!.join() }
        s.deleteBank(piano.bankKey)
        assertFalse(s.state.value.isDownloaded(piano)); assertFalse(s.state.value.isDownloaded(violin))
        assertNull(s.localBankFile(piano))
    }

    @Test fun rescanPicksUpExternalChangesAndIgnoresForeignFiles() {
        val dir = tmp.root.resolve("studio/instruments").also { it.mkdirs() }
        File(dir, "instrument-foo.sf2").writeBytes(byteArrayOf(1))
        File(dir, "notes.txt").writeBytes(byteArrayOf(1, 2))
        File(dir, ".pack-staging-1.tmp").writeBytes(byteArrayOf(1))
        val s = store()
        assertEquals(setOf("foo"), s.state.value.downloadedSlugs)
        File(dir, "instrument-foo.sf2").delete()
        s.rescanDownloads()
        assertTrue(s.state.value.downloadedSlugs.isEmpty())
    }

    @Test fun packWithoutBankKeyIsNotDownloadable() {
        val s = store()
        val p = InstrumentPack("x", "X", InstrumentKey.HARP, 46, "")
        assertNull(s.download(p))
        assertEquals("This pack can't be downloaded by this version", s.state.value.errorByBank[""])
    }

    @Test fun installBankIsDuplicateTolerantAndConsumesStaging() {
        val dir = tmp.newFolder("d")
        val dest = File(dir, "instrument-a.sf2").also { it.writeBytes(byteArrayOf(9)) }
        val staged = File(dir, ".s.tmp").also { it.writeBytes(bytes) }
        InstrumentPackStore.installBank(staged, dest, sha)   // winner already there => success, ours dropped
        assertFalse(staged.exists()); assertEquals(1L, dest.length())
    }
}

class InstrumentPackGroupsTest {
    private fun pack(id: String, inst: InstrumentKey, bank: String, bytes: Long = 0) = InstrumentPack(id, inst.displayName, inst, inst.gmProgram, bank, bytes)

    @Test fun packsSharingABankCollapseIntoOneRowWithTheBankSize() {
        val g = InstrumentPackGroups.group(
            listOf(pack("a", InstrumentKey.PIANO, "banks/gu.sf2", 5), pack("b", InstrumentKey.VIOLIN, "banks/gu.sf2"), pack("c", InstrumentKey.HARP, "banks/harp.sf2", 900_000)),
            listOf(InstrumentBank("banks/gu.sf2", 32_000_000)),
        )
        assertEquals(2, g.size)
        assertEquals("Piano, Violin", g[0].title); assertEquals(32_000_000L, g[0].bytes)
        assertEquals("Harp", g[1].title); assertEquals(900_000L, g[1].bytes)   // no bank entry => pack size
    }

    @Test fun packWithoutABankKeyIsItsOwnNonDownloadableRowListedLast() {
        val g = InstrumentPackGroups.group(listOf(pack("x", InstrumentKey.CLARINET, ""), pack("a", InstrumentKey.PIANO, "k")), emptyList())
        assertEquals(listOf("k", ""), g.map { it.bankKey })
        assertFalse(g[1].downloadable); assertTrue(g[0].downloadable)
    }

    @Test fun sizeLabels() {
        assertEquals("32 MB", InstrumentPackGroups.sizeLabel(32_400_000)); assertEquals("820 KB", InstrumentPackGroups.sizeLabel(820_000))
        assertEquals("1 KB", InstrumentPackGroups.sizeLabel(10)); assertEquals("", InstrumentPackGroups.sizeLabel(0))
    }
}
