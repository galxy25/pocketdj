package com.levi.pocketdj.studio.demux

import java.io.File
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private class FakePlayer : StemPlayer {
    val loads = ArrayList<Pair<String, Set<String>>>()
    var stops = 0
    override val version: StateFlow<Int> = MutableStateFlow(0)
    override var isPlaying = false
    override var currentTimeSec = 0.0
    override val durationSec = 0.0
    override val soloed: String? = null
    override fun isAudible(name: String) = true
    var loadResult = true
    var stemLoadResult = true
    override fun load(id: String, files: Map<String, File>): Boolean { loads.add(id to files.keys); return if (id.endsWith("#stems")) stemLoadResult else loadResult }
    override fun togglePlayPause() { isPlaying = !isPlaying }
    override fun seek(sec: Double) { currentTimeSec = sec }
    override fun solo(name: String) {}
    override fun toggleMute(name: String) {}
    override fun stop() { stops++ }
}

private class FakeEnv(val dir: File) : DemuxEnv {
    val songs = HashMap<String, DemuxSongInfo>()
    val local = HashMap<String, DemuxLocalSong>()
    val manifest = HashSet<String>()
    var burnOk = true
    var server = true
    var burnedStems = HashSet<String>()
    var stemmed = HashSet<String>()
    var stemifyOk = true
    var customResult: Map<String, String>? = null
    val carves = AtomicInteger()
    var carveGate: CompletableDeferred<Unit>? = null
    val studio = HashMap<String, File>()
    val peaksCalls = AtomicInteger()

    override fun songInfo(songId: String) = songs[songId]
    override fun localSong(songId: String) = local[songId]
    override fun inManifest(songId: String) = songId in manifest
    override suspend fun burn(songId: String, title: String, artist: String): Boolean {
        if (burnOk) local[songId] = DemuxLocalSong(File(dir, "$songId.mp3").also { it.writeText("a") }, true, 0)
        return burnOk
    }
    override suspend fun carve(src: File, startMs: Int, endMs: Int, dest: File): Boolean {
        carves.incrementAndGet()
        carveGate?.let { g ->   // a carve that outlives its selection: cancellation is swallowed, it finishes whenever the gate opens
            try { g.await() } catch (e: kotlinx.coroutines.CancellationException) { runCatching { withContext(NonCancellable) { g.await() } } }
        }
        dest.parentFile?.mkdirs(); dest.writeText("carved $startMs-$endMs"); return true
    }
    /** SAF-stored Performance media: id -> bytes behind a content:// uri, materialized like the app graph does. */
    val safStudio = HashMap<String, ByteArray>()
    private val materializer by lazy {
        com.levi.pocketdj.studio.store.StudioMaterializer(File(dir, "mat"), { u -> safStudio[u.substringAfterLast('/')]?.let { com.levi.pocketdj.studio.store.SafStat(it.size.toLong(), 1) } }, { u -> safStudio[u.substringAfterLast('/')]?.inputStream() })
    }
    override suspend fun studioFile(id: String): File? {
        studio[id]?.let { return it }
        if (id !in safStudio) return null
        return materializer.lease(com.levi.pocketdj.studio.store.StudioFileRef(null, "content://tree/$id"))?.file
    }
    override suspend fun hasServer() = server
    override fun songStemsBurned(songId: String) = songId in burnedStems
    override fun songIsStemmed(songId: String) = songId in stemmed
    override suspend fun burnSongStems(songId: String): Map<String, File>? {
        if (songId !in stemmed) return null
        burnedStems.add(songId); return DemuxStore.STEM_NAMES.associateWith { File(dir, "$songId-$it.mp3") }
    }
    override fun songStemFiles(songId: String) = if (songId in burnedStems) DemuxStore.STEM_NAMES.associateWith { File(dir, "$songId-$it.mp3") } else null
    override suspend fun stemifySong(songId: String): Boolean { if (stemifyOk) stemmed.add(songId); return stemifyOk }
    override suspend fun stemifyCustom(id: String, file: File) = customResult
    override suspend fun peaks(file: File, durationMs: Int): FloatArray { peaksCalls.incrementAndGet(); return floatArrayOf(0.5f) }
    override fun fileLengthMs(file: File) = 4000
}

class DemuxSessionTest {
    private lateinit var dir: File
    private lateinit var store: DemuxStore
    private lateinit var env: FakeEnv
    private lateinit var player: FakePlayer
    private lateinit var session: DemuxSession
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val chordCalls = AtomicInteger()

    @Before fun setUp() {
        dir = Files.createTempDirectory("demux-session").toFile()
        store = DemuxStore(File(dir, "cache"), fetch = { _, d -> d.parentFile?.mkdirs(); d.writeText("s"); true }, detectChords = { chordCalls.incrementAndGet(); listOf(DemuxChordSegment(0, false, 0, 1000, 0.9)) })
        env = FakeEnv(dir)
        player = FakePlayer()
        session = DemuxSession(scope, store, env, player)
        env.songs["sng_a"] = DemuxSongInfo("Song A", "Artist", 180_000)
        env.songs["sng_b"] = DemuxSongInfo("Song B", "Artist", 200_000)
    }
    @After fun tearDown() { scope.coroutineContext[kotlinx.coroutines.Job]?.cancel(); dir.deleteRecursively() }

    private fun mp3(name: String) = File(dir, name).also { it.writeText("a") }
    private val songA = DemuxSource.Song("sng_a", "Song A", "Artist")
    private val songB = DemuxSource.Song("sng_b", "Song B", "Artist")

    @Test fun staleResolveFinishingLaterCannotOverwriteTheCurrentSelection() = runBlocking {
        // A is an analog side whose carve is slow AND uncancellable; B is a plain file that resolves at once.
        env.local["sng_a"] = DemuxLocalSong(mp3("side.mp3"), false, 30_000)
        val gate = CompletableDeferred<Unit>().also { env.carveGate = it }
        val jobA = session.select(songA)
        while (env.carves.get() == 0) Thread.sleep(2)             // A is parked inside the carve
        env.local["sng_b"] = DemuxLocalSong(mp3("b.mp3"), true, 0)
        session.select(songB).join()
        assertEquals(DemuxPhase.Ready, session.phase.value)
        assertEquals("sng_b", session.source.value?.key)
        gate.complete(Unit)                                         // A's carve finishes AFTER B is current
        jobA.join()
        assertEquals("sng_b", session.source.value?.key)
        assertEquals(DemuxPhase.Ready, session.phase.value)
        assertEquals("b.mp3", session.audioFile.value?.name)
        assertEquals(200_000, session.durationMs.value)
        assertEquals(listOf("sng_b#mix"), player.loads.map { it.first })
        assertTrue("A never got analyzed or sized", store.document("sng_a")?.let { it.chordStatus == DemuxArtifactStatus.NONE && it.durationMs == 0 } ?: true)
    }

    @Test fun analogSongIsCarvedOnceAndReselectReusesTheCache() = runBlocking {
        env.local["sng_a"] = DemuxLocalSong(mp3("side.mp3"), false, 61_500)
        session.select(songA).join()
        assertEquals(1, env.carves.get())
        val carved = session.audioFile.value!!
        assertEquals("sng_a.m4a", carved.name)
        assertEquals("carved 61500-241500", carved.readText())      // [offset, offset + song length): 0:00 = the song's 0:00
        assertEquals(180_000, session.durationMs.value)
        session.clearSource()
        session.select(songA).join()
        assertEquals("no second carve", 1, env.carves.get())
        assertEquals(carved, session.audioFile.value)
    }

    @Test fun cutOrDigitalFilesPlayAsIsWithoutCarving() = runBlocking {
        val cut = mp3("cut.mp3")
        env.local["sng_a"] = DemuxLocalSong(cut, true, 99_000)      // a per-song cut ignores the album offset
        session.select(songA).join()
        assertEquals(0, env.carves.get()); assertEquals(cut, session.audioFile.value)
    }

    @Test fun ladderStatesForSongs() = runBlocking {
        session.select(songA).join()
        assertEquals("not local, not in manifest", DemuxPhase.RipFirst, session.phase.value)
        env.manifest.add("sng_a")
        session.select(songA).join()
        assertEquals(DemuxPhase.NeedsBurn, session.phase.value)
        session.burnThenReady()!!.join()
        assertEquals(DemuxPhase.Ready, session.phase.value)
        session.select(DemuxSource.Song("ghost", "g", "a")).join()
        assertTrue((session.phase.value as DemuxPhase.Failed).message.contains("catalog"))
        env.manifest.add("sng_b"); env.burnOk = false
        session.select(songB).join(); session.burnThenReady()!!.join()
        assertTrue((session.phase.value as DemuxPhase.Failed).message.contains("burn"))
    }

    @Test fun importedAndStudioSourcesResolveOrFailWithGuidance() = runBlocking {
        val imp = store.importStream("riff.wav", "RIFF".byteInputStream())!!
        session.select(imp).join()
        assertEquals(DemuxPhase.Ready, session.phase.value); assertEquals(4000, session.durationMs.value)
        session.select(DemuxSource.Studio("smp_1", "s")).join()
        assertTrue((session.phase.value as DemuxPhase.Failed).message.contains("no playable audio"))
        env.studio["smp_1"] = mp3("smp.wav")
        session.select(DemuxSource.Studio("smp_1", "s")).join()
        assertEquals(DemuxPhase.Ready, session.phase.value)
        session.select(DemuxSource.ImportedFile("dmx_gone", "x")).join()
        assertTrue((session.phase.value as DemuxPhase.Failed).message.contains("gone"))
    }

    @Test fun safStoredStudioMediaAppearsViaTheMaterializer() = runBlocking {
        env.safStudio["tk_saf"] = ByteArray(64) { 3 }
        session.select(DemuxSource.Studio("tk_saf", "t")).join()
        assertEquals(DemuxPhase.Ready, session.phase.value)
    }

    @Test fun readyKicksOffChordsAndPeaksAndLoadsTheMixPlayer() = runBlocking {
        env.local["sng_a"] = DemuxLocalSong(mp3("a.mp3"), true, 0)
        session.select(songA).join()
        while (store.document("sng_a")?.chordStatus != DemuxArtifactStatus.DONE) Thread.sleep(5)
        assertEquals(1, store.document("sng_a")!!.chords.size)
        while (session.peaks.value.isEmpty()) Thread.sleep(5)
        assertEquals(listOf("sng_a#mix" to setOf("vocals")), player.loads)
    }

    @Test fun clearSourceStopsThePlayerAndResetsState() = runBlocking {
        env.local["sng_a"] = DemuxLocalSong(mp3("a.mp3"), true, 0)
        session.select(songA).join()
        val stopsBefore = player.stops
        session.clearSource()
        assertNull(session.source.value); assertEquals(DemuxPhase.Idle, session.phase.value); assertNull(session.audioFile.value)
        assertTrue(player.stops > stopsBefore)
    }

    @Test fun catalogStemStatesFollowTheManifestAndBurnStore() = runBlocking {
        env.local["sng_a"] = DemuxLocalSong(mp3("a.mp3"), true, 0)
        env.server = false
        session.select(songA).join()
        assertEquals(DemuxStemState.None, session.stemState.value)
        env.server = true; env.manifest.add("sng_a")
        session.select(songA).join()
        assertEquals(DemuxStemState.Creatable, session.stemState.value)
        session.createStems()!!.join()
        assertEquals("stemify then pull", DemuxStemState.Burned, session.stemState.value)
        env.burnedStems.clear()
        env.stemmed.add("sng_a")
        session.select(songA).join()
        assertEquals(DemuxStemState.Downloadable, session.stemState.value)
        session.downloadStems()!!.join()
        assertEquals(DemuxStemState.Burned, session.stemState.value)
        session.select(songA).join()
        assertEquals(DemuxStemState.Burned, session.stemState.value)
    }

    @Test fun stemifyFailureSurfacesAFailedStateAndRetryCanSucceed() = runBlocking {
        env.local["sng_a"] = DemuxLocalSong(mp3("a.mp3"), true, 0); env.manifest.add("sng_a"); env.stemifyOk = false
        session.select(songA).join()
        session.createStems()!!.join()
        assertTrue(session.stemState.value is DemuxStemState.Failed)
        env.stemifyOk = true
        session.createStems()!!.join()
        assertEquals(DemuxStemState.Burned, session.stemState.value)
    }

    @Test fun customAudioStemsUploadDownloadAllOrNothing() = runBlocking {
        val imp = store.importStream("riff.wav", "RIFF".byteInputStream())!!
        session.select(imp).join()
        assertEquals(DemuxStemState.Creatable, session.stemState.value)
        session.createStems()!!.join()
        assertTrue("server returned nothing", session.stemState.value is DemuxStemState.Failed)
        assertNull(store.localStemFiles(imp.id))
        env.customResult = DemuxStore.STEM_NAMES.associateWith { "https://x/$it.mp3" }
        session.createStems()!!.join()
        assertEquals(DemuxStemState.Burned, session.stemState.value)
        assertEquals(4, store.localStemFiles(imp.id)!!.size)
        session.select(imp).join()
        assertEquals("cached stems are Burned on re-select", DemuxStemState.Burned, session.stemState.value)
    }

    @Test fun stemModeReloadsPlayerWithFourFilesAndBackToMixKeepingPosition() = runBlocking {
        env.local["sng_a"] = DemuxLocalSong(mp3("a.mp3"), true, 0); env.burnedStems.add("sng_a")
        session.select(songA).join()
        player.currentTimeSec = 42.0; player.isPlaying = true
        session.setStemMode(true)
        assertTrue(session.stemMode.value)
        assertEquals("sng_a#stems" to DemuxStore.STEM_NAMES.toSet(), player.loads.last().let { it.first to it.second })
        assertEquals(42.0, player.currentTimeSec, 0.0)
        session.setStemMode(false)
        assertFalse(session.stemMode.value)
        assertEquals("sng_a#mix", player.loads.last().first)
    }

    @Test fun unplayableAudioFailsTheSessionInsteadOfCrashing() = runBlocking {
        env.local["sng_a"] = DemuxLocalSong(mp3("a.mp3"), true, 0)
        player.loadResult = false
        session.select(songA).join()
        assertEquals(DemuxPhase.Failed("Couldn’t play this audio"), session.phase.value)
        assertEquals(0, chordCalls.get())
    }

    @Test fun throwingPlayerLoadIsContainedAsFailed() = runBlocking {
        env.local["sng_a"] = DemuxLocalSong(mp3("a.mp3"), true, 0)
        val boom = object : StemPlayer by FakePlayer() {
            override fun load(id: String, files: Map<String, File>): Boolean = throw java.io.IOException("Prepare failed")
        }
        val s = DemuxSession(scope, store, env, boom)
        s.select(songA).join()
        assertTrue(s.phase.value is DemuxPhase.Failed)
    }

    @Test fun staleBlockingLoadNeverLeavesAPlayerLoadedAfterReselect() {
        // A's load blocks (MediaPlayer.prepare) on the single player thread; the user taps Change/other source meanwhile.
        val ctx = java.util.concurrent.Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        val gate = java.util.concurrent.CountDownLatch(1)
        val entered = java.util.concurrent.CountDownLatch(1)
        val loaded = java.util.concurrent.atomic.AtomicReference<String?>(null)
        val p = object : StemPlayer by FakePlayer() {
            override fun load(id: String, files: Map<String, File>): Boolean { entered.countDown(); gate.await(); loaded.set(id); return true }
            override fun stop() { loaded.set(null) }
        }
        val s = DemuxSession(scope, store, env, p, ctx)
        env.local["sng_a"] = DemuxLocalSong(mp3("a.mp3"), true, 0)
        s.select(songA)
        assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
        s.clearSource()                      // stop is ordered AFTER the in-flight load on the player thread
        gate.countDown()
        runBlocking { withContext(ctx) {} } // drain the player thread
        assertNull("stale load must be stopped, not left loaded", loaded.get())
        assertNull(s.source.value)
        ctx.close()
    }

    @Test fun stemModeFallsBackToMixWhenStemsDontLoad() = runBlocking {
        env.local["sng_a"] = DemuxLocalSong(mp3("a.mp3"), true, 0)
        env.stemmed.add("sng_a"); env.burnedStems.add("sng_a")
        session.select(songA).join()
        player.stemLoadResult = false
        session.setStemMode(true)?.join()
        assertFalse(session.stemMode.value)
        assertEquals("sng_a#mix", player.loads.last().first)
    }
}
