package com.levi.pocketdj.di

import android.content.Intent
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.shell.DeepLinkHandler
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.Flushable
import com.levi.pocketdj.shell.ResetHook
import com.levi.pocketdj.shell.SyncEntry
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioLoop
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.model.StudioPatternRow
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSource
import com.levi.pocketdj.studio.store.DefaultStudioRoots
import com.levi.pocketdj.studio.store.ExecutorStudioScheduler
import com.levi.pocketdj.studio.store.SafStudioDir
import com.levi.pocketdj.studio.store.StudioDir
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.StudioRoots
import com.levi.pocketdj.studio.store.StudioStore
import com.levi.pocketdj.data.burns.BurnSong
import com.levi.pocketdj.studio.audio.LocalAudioCache
import com.levi.pocketdj.studio.audio.LocalSource
import com.levi.pocketdj.studio.audio.NativeStretcher
import com.levi.pocketdj.studio.audio.PrepareOutcome
import com.levi.pocketdj.studio.audio.StudioOutputs
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.engine.AudioFocusPolicy
import com.levi.pocketdj.studio.engine.LoopAudition
import com.levi.pocketdj.studio.engine.LoopFactory
import com.levi.pocketdj.studio.engine.SliceBaker
import com.levi.pocketdj.studio.engine.MicRecorder
import com.levi.pocketdj.studio.engine.SampleFactory
import com.levi.pocketdj.studio.engine.SampleRenderCache
import com.levi.pocketdj.studio.engine.StudioEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.PI
import kotlin.math.sin

/**
 * Sidecar graph for the studio area (decision D3). STU-1 contributes the studio document store
 * (`pocketdj-studio.json`, device-local) with its ON_STOP flush, the "Reset everything" hook, the
 * cue-mirror sync entry (the ONLY Studio data that leaves the device), and the debug
 * `--ez PDJ_SEED_STUDIO true` fixture seed used by the emulator steps.
 */
class StudioGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "studio"

    /**
     * Per-family user-folder SAF tree URI (persisted permission). Wired to the Storage settings by
     * the package that adds the folder pickers (SVC-14 / STU-x); null => app-managed root only.
     */
    @Volatile
    var userFolderTreeUri: (StudioFamily) -> String? = { null }

    /** Studio family roots: app-private `filesDir/studio/<family>/` + optional SAF user roots. */
    val studioRoots: StudioRoots by lazy {
        DefaultStudioRoots(File(app.appContext.filesDir, "studio")) { family ->
            SafStudioDir.open(app.appContext, userFolderTreeUri(family)) as StudioDir?
        }
    }

    private val writerExecutor by lazy { VersionedJsonWriter.backgroundExecutor("pdj-studio-writer") }

    /** The studio document store. Construction reads the doc and reconciles against disk once. */
    private val storeLazy = lazy {
        StudioStore(
            File(app.appContext.filesDir, StudioStore.FILE_NAME), studioRoots, writerExecutor, ExecutorStudioScheduler(),
        ).also { s ->
            // Reconcile lists SAF trees: never on the first caller's (possibly main) thread.
            app.appScope.launch(Dispatchers.IO) { runCatching { s.reconcileOnLaunch() } }
        }
    }
    val studioStore: StudioStore get() = storeLazy.value

    /** STU-6: the cue seam shared by the Mix deck cue-jump row and the Producer Cues tab (one store). */
    val cuePoints: com.levi.pocketdj.screens.mix.StudioCuePoints by lazy {
        com.levi.pocketdj.screens.mix.StudioCuePoints { studioStore }
    }

    // ---- STU-3: render / engine / recorder / source cache (all lazy: a user who never opens Producer pays nothing)

    private val audioManager get() = app.appContext.getSystemService(android.content.Context.AUDIO_SERVICE) as android.media.AudioManager

    val studioRender: StudioRender by lazy { StudioRender(stretcher = NativeStretcher) }

    val sampleRenderCache: SampleRenderCache by lazy { SampleRenderCache(studioRoots, studioStore, studioRender) }

    val sampleFactory: SampleFactory by lazy { SampleFactory(studioRoots, studioStore, studioRender) }

    private val engineLazy = lazy {
        val focus = AudioFocusPolicy.FocusHandle(audioManager) { app.appScope.launch(Dispatchers.Main) { studioEngine.pauseSample() } }
        StudioEngine(
            sinkFactory = { StudioOutputs.create(audioManager) },
            stretcher = NativeStretcher,
            scope = app.appScope,
            focus = {
                // One audible owner: park Now Playing before the Studio sample sounds.
                app.appScope.launch { runCatching { app.playbackController.pause() } }
                focus.requestPlayback()
            },
            focusRelease = { focus.abandon() },
        )
    }
    val studioEngine: StudioEngine get() = engineLazy.value

    // ---- STU-4: loops (render / seamless audition) + slice pads (all lazy)

    /** Loop preview + Save both render through the REAL renderer from the RAW sample file. */
    val loopFactory: LoopFactory by lazy {
        LoopFactory(
            studioRoots, studioStore, studioRender, { sampleRenderCache.sourceFile(it) },
            File(app.appContext.cacheDir, "studio-loop-preview.wav"),
        )
    }

    val sliceBaker: SliceBaker by lazy { SliceBaker(studioRoots, studioStore, studioRender, { sampleRenderCache.sourceFile(it) }) }

    private val loopLazy = lazy {
        val focus = AudioFocusPolicy.FocusHandle(audioManager) { app.appScope.launch(Dispatchers.Main) { loopAudition.stop() } }
        LoopAudition(
            sinkFactory = { StudioOutputs.create(audioManager) },
            decode = { runCatching { studioRender.decodeBuffer(it) }.getOrNull() },
            focus = {
                // One audible owner: park Now Playing and any sample audition before a loop sounds.
                app.appScope.launch { runCatching { app.playbackController.pause() } }
                if (engineLazy.isInitialized()) studioEngine.pauseSample()
                focus.requestPlayback()
            },
            focusRelease = { focus.abandon() },
            diag = { msg -> runCatching { com.levi.pocketdj.audio.core.AudioDiag.emit("studio.loop $msg") } },
        )
    }
    val loopAudition: LoopAudition get() = loopLazy.value.also { ensureLoopStopObserver() }

    private var loopStopObserverAdded = false

    /** Backgrounding (process ON_STOP, main thread) silences the loop; onPause / rotation must NOT (they run the flush funnel). */
    private fun ensureLoopStopObserver() {
        if (loopStopObserverAdded) return
        loopStopObserverAdded = true
        app.appScope.launch(Dispatchers.Main) {
            androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.addObserver(object : androidx.lifecycle.DefaultLifecycleObserver {
                override fun onStop(owner: androidx.lifecycle.LifecycleOwner) { loopAudition.stop() }
            })
        }
    }

    private val micLazy = lazy {
        val captureFocus = AudioFocusPolicy.FocusHandle(audioManager) { /* a competing app took focus: the take keeps going */ }
        MicRecorder(
            studioRoots, studioStore, audioManager,
            onCaptureBegin = {
                // Park Now Playing and take transient focus so nothing bleeds into the take.
                app.appScope.launch { runCatching { app.playbackController.pause() } }
                captureFocus.requestCapture()
            },
            onCaptureEnd = { captureFocus.abandon() },
        ).also { r -> studioStore.activeTakeFileName = { r.activeTake?.first } }
    }
    val micRecorder: MicRecorder get() = micLazy.value

    /** Source ladder for New-sample-from-track: burned file -> burn-on-demand -> 'Rip first'. */
    val localAudioCache: LocalAudioCache by lazy {
        val burns = app.servicesGraph.burnStore
        LocalAudioCache(
            dir = java.io.File(app.appContext.cacheDir, "studio-src"),
            http = app.httpClient,
            backend = object : LocalAudioCache.Backend {
                override fun local(songId: String): LocalSource? =
                    burns.localUrlPreferringCut(songId)?.let { LocalSource(it.file, it.isCut, burns.startMs(songId)?.toInt() ?: 0) }
                override fun inManifest(songId: String) = app.ripsRepository.entry(songId) != null
                override suspend fun burn(songId: String, title: String, artist: String): PrepareOutcome {
                    val r = burns.burn(listOf(BurnSong(songId, title, artist)))
                    return PrepareOutcome(
                        ok = r.burned > 0, notRipped = r.notRipped > 0,
                        folderUnavailable = r.folderUnavailable, outOfSpace = r.outOfSpace,
                    )
                }
                override suspend fun durableUrl(songId: String): String? = app.presignCache.urlFor(songId)
                override fun startMs(songId: String): Int = burns.startMs(songId)?.toInt() ?: 0
            },
        ).also { it.sweepPartials() }
    }

    // A user who never touched Studio must not build/reconcile/rewrite the doc on ON_STOP.
    // A take in flight is filed + the store flushed synchronously (Android blocks background mic capture).
    override val flushables: List<Flushable> = listOf(
        Flushable { if (micLazy.isInitialized()) micRecorder.finalizeForExit() },
        Flushable { if (storeLazy.isInitialized()) studioStore.flush() },
    )

    override val resetHooks: List<ResetHook> = listOf(
        ResetHook {
            val s = studioStore
            StudioFamily.entries.forEach { s.deleteAll(it) }
            s.clearCues()
            s.flush()
        },
    )

    override val syncEntries: List<SyncEntry> = listOf(SyncEntry("studio-cues", "pocketdj-studio.cues.json"))

    override val deepLinkHandlers: List<DeepLinkHandler> = listOf(
        DeepLinkHandler { intent ->
            if (isDebuggable() && intent.getBooleanExtra(SEED_EXTRA, false)) {
                app.appScope.launch(Dispatchers.IO) { runCatching { seedFixture() } }
            }
            false   // never consumes the intent
        },
    )

    private fun isDebuggable(): Boolean =
        (app.appContext.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0

    /**
     * Debug fixture (`--ez PDJ_SEED_STUDIO true`): one 1 s tone sample + one loop (real files in
     * the app roots), a pattern, and two cues. Idempotent by fixed ids. Emulator steps: relaunch
     * -> rows persist; delete a tone file -> relaunch -> record pruned; revoke the SAF root ->
     * relaunch -> nothing pruned.
     */
    fun seedFixture() {
        val store = studioStore
        val smpId = "smp_seed0000-0000-0000-0000-000000000001"
        val lpId = "lp_seed0000-0000-0000-0000-000000000001"
        val sName = StudioFolders.fileName(StudioFamily.SAMPLES, smpId)
        val lName = StudioFolders.fileName(StudioFamily.LOOPS, lpId)
        writeTone(File(File(app.appContext.filesDir, "studio/samples").also { it.mkdirs() }, sName))
        writeTone(File(File(app.appContext.filesDir, "studio/loops").also { it.mkdirs() }, lName))
        val t = System.currentTimeMillis().toDouble()
        store.addSample(
            StudioSample(smpId, "Seed Tone", sName, createdAt = t, durationMs = 1000, source = StudioSource.Mic, grid = StudioGrid(120.0)),
        )
        store.addLoop(StudioLoop(lpId, "Seed Loop", smpId, bpm = 120.0, lengthMs = 1000, frames = 44100, fileName = lName, createdAt = t))
        store.addPattern(
            StudioPattern.of(
                "ptn_seed0000-0000-0000-0000-000000000001", "Seed Pattern",
                rows = listOf(StudioPatternRow.of(smpId, steps = List(16) { it % 4 == 0 })), createdAt = t,
            ),
        )
        store.setCue("sng_1", 0, 1000, "Seed A")
        store.setCue("sng_1", 1, 2000, "Seed B")
        store.flush()
    }

    /** 1 s 440 Hz mono 16-bit PCM WAV (the seed's stand-in audio; content-sniffed by the decoder). */
    private fun writeTone(f: File) {
        val rate = 44100; val n = rate
        RandomAccessFile(f, "rw").use { raf ->
            raf.setLength(0)
            fun le32(v: Int) = byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte())
            fun le16(v: Int) = byteArrayOf(v.toByte(), (v shr 8).toByte())
            raf.writeBytes("RIFF"); raf.write(le32(36 + n * 2)); raf.writeBytes("WAVEfmt ")
            raf.write(le32(16)); raf.write(le16(1)); raf.write(le16(1)); raf.write(le32(rate))
            raf.write(le32(rate * 2)); raf.write(le16(2)); raf.write(le16(16))
            raf.writeBytes("data"); raf.write(le32(n * 2))
            val buf = ByteArray(n * 2)
            for (i in 0 until n) {
                val v = (sin(2 * PI * 440.0 * i / rate) * 0.3 * Short.MAX_VALUE).toInt()
                buf[2 * i] = v.toByte(); buf[2 * i + 1] = (v shr 8).toByte()
            }
            raf.write(buf)
        }
    }

    companion object {
        const val SEED_EXTRA = "PDJ_SEED_STUDIO"
    }
}
