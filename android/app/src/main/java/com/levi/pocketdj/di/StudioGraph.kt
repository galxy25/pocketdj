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
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.data.collections.StudioLookup
import com.levi.pocketdj.data.storage.StorageService
import com.levi.pocketdj.screens.settings.sections.studioStorageSection
import com.levi.pocketdj.studio.StudioAnalyzer
import com.levi.pocketdj.studio.StudioFiles
import com.levi.pocketdj.studio.StudioPlayback
import com.levi.pocketdj.studio.StudioPrepareBackend
import com.levi.pocketdj.studio.BouncedFile
import com.levi.pocketdj.studio.StudioRowResolver
import com.levi.pocketdj.studio.store.FileStudioDir
import com.levi.pocketdj.studio.engine.PatternBouncer
import com.levi.pocketdj.studio.engine.StudioStretchKey
import com.levi.pocketdj.studio.engine.AudioFocusPolicy
import com.levi.pocketdj.studio.engine.StudioDiag
import com.levi.pocketdj.studio.engine.LoopAudition
import com.levi.pocketdj.studio.engine.LoopFactory
import com.levi.pocketdj.studio.engine.SliceBaker
import com.levi.pocketdj.studio.engine.MicRecorder
import com.levi.pocketdj.studio.engine.PatternEngine
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
    var userFolderTreeUri: (StudioFamily) -> String? = { f -> folderPrefs.getString(f.rawValue, null) }

    /** Persisted per-family SAF tree uri (STU-7 folder choosers); tiny, so SharedPreferences. */
    private val folderPrefs by lazy { app.appContext.getSharedPreferences("pocketdj-studio-folders", android.content.Context.MODE_PRIVATE) }

    /** Choose (or clear with null) the user folder for [family]; only user-relocatable families. */
    fun setUserFolder(family: StudioFamily, treeUri: String?) {
        if (!family.supportsUserFolder) return
        folderPrefs.edit().also { if (treeUri.isNullOrEmpty()) it.remove(family.rawValue) else it.putString(family.rawValue, treeUri) }.apply()
    }

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
            s.onFamilyDeleted = { f -> if (f == StudioFamily.INSTRUMENTS) instrumentPacks.rescanDownloads() }
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

    /** Transient-loss park / gain resume pairing (iOS interruptionParked). Sample + pattern park-and-resume; the rest stop. */
    val interruptions = com.levi.pocketdj.studio.engine.InterruptionCoordinator()

    private val engineLazy: Lazy<StudioEngine> = lazy {
        val focus = AudioFocusPolicy.FocusHandle(
            audioManager,
            onTransientLoss = { app.appScope.launch(Dispatchers.Main) { interruptions.onTransientLoss() } },
            onGain = { app.appScope.launch(Dispatchers.Main) { interruptions.onGain() } },
            onLoss = { app.appScope.launch(Dispatchers.Main) { interruptions.forget("sample"); studioEngine.pauseSample("focus-loss") } },
        )
        StudioEngine(
            sinkFactory = { StudioOutputs.create(audioManager) },
            stretcher = NativeStretcher,
            scope = app.appScope,
            focus = {
                // One audible owner: park Now Playing (and a running pattern) before the Studio sample sounds.
                app.appScope.launch { runCatching { app.playbackController.pause() } }
                if (patternLazy.isInitialized()) patternEngine.stopPattern("superseded")
                focus.requestPlayback()
            },
            focusRelease = { focus.abandon() },
        ).also { e ->
            e.onUserTransport = { interruptions.forget("sample") }
            interruptions.register("sample", { e.isPlayingSample.value }, { e.pauseSample("focus-transient") }, { e.playSample() })
        }
    }
    val studioEngine: StudioEngine get() = engineLazy.value

    /** STU-12: the Tracks arranger player (one render callback; clip decode/bake via the shared StudioRender). */
    private val multitrackLazy: Lazy<com.levi.pocketdj.studio.engine.MultitrackPlayer> = lazy {
        val focus = AudioFocusPolicy.FocusHandle(audioManager) { app.appScope.launch(Dispatchers.Main) { multitrackPlayer.stop("focus-loss") } }
        com.levi.pocketdj.studio.engine.MultitrackPlayer(
            loader = com.levi.pocketdj.studio.engine.StudioClipLoader(studioStore, studioRender),
            sinkFactory = { StudioOutputs.create(audioManager) },
            scope = app.appScope,
            onFocus = {
                // One audible owner: park Now Playing (and a running pattern / sample) before the arranger sounds.
                app.appScope.launch { runCatching { app.playbackController.pause() } }
                if (patternLazy.isInitialized()) patternEngine.stopPattern("superseded")
                if (engineLazy.isInitialized()) studioEngine.pauseSample("superseded")
                focus.requestPlayback()
            },
            onFocusRelease = { focus.abandon() },
            recorder = com.levi.pocketdj.studio.engine.MasterRecorder(tempDir = { File(app.appContext.cacheDir, "master-rec") }),
        )
    }
    val multitrackPlayer: com.levi.pocketdj.studio.engine.MultitrackPlayer get() = multitrackLazy.value.also { ensureLoopStopObserver() }

    /** STU-13: artifact-only Bounce (same clip planner + render context as the live player). */
    val arrangerBouncer: com.levi.pocketdj.studio.engine.ArrangerBouncer by lazy {
        com.levi.pocketdj.studio.engine.ArrangerBouncer(com.levi.pocketdj.studio.engine.StudioClipLoader(studioStore, studioRender))
    }

    /** STU-13: bakes a finished record-to-master capture into a Recording artifact. */
    val masterRecordingBaker: com.levi.pocketdj.studio.engine.MasterRecordingBaker by lazy { com.levi.pocketdj.studio.engine.MasterRecordingBaker() }

    /** STU-13: background beat-grid analysis for Beat Match (idempotent; fire from the open arrangement). */
    val arrangerGridAnalyzer: com.levi.pocketdj.studio.engine.ArrangerGridAnalyzer by lazy {
        val loader = com.levi.pocketdj.studio.engine.StudioClipLoader(studioStore, studioRender)
        com.levi.pocketdj.studio.engine.ArrangerGridAnalyzer(
            arrangement = { studioStore.arrangement(it) },
            setGrid = { a, t, c, g -> studioStore.setClipGrid(a, t, c, g) },
            decode = { loader.decode(it) },
        )
    }

    // ---- STU-4: loops (render / seamless audition) + slice pads (all lazy)

    /** Loop preview + Save both render through the REAL renderer from the RAW sample file. */
    val loopFactory: LoopFactory by lazy {
        LoopFactory(
            studioRoots, studioStore, studioRender, { sampleRenderCache.sourceFile(it) },
            File(app.appContext.cacheDir, "studio-loop-preview.wav"),
        )
    }

    val sliceBaker: SliceBaker by lazy { SliceBaker(studioRoots, studioStore, studioRender, { sampleRenderCache.sourceFile(it) }) }

    private val loopLazy: Lazy<LoopAudition> = lazy {
        val focus = AudioFocusPolicy.FocusHandle(audioManager) { app.appScope.launch(Dispatchers.Main) { loopAudition.stop("focus-loss") } }
        LoopAudition(
            sinkFactory = { StudioOutputs.create(audioManager) },
            decode = { runCatching { studioRender.decodeBuffer(it) }.getOrNull() },
            focus = {
                // One audible owner: park Now Playing and any sample audition before a loop sounds.
                app.appScope.launch { runCatching { app.playbackController.pause() } }
                if (engineLazy.isInitialized()) studioEngine.pauseSample("superseded")
                if (patternLazy.isInitialized()) patternEngine.stopPattern("superseded")
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
                override fun onStop(owner: androidx.lifecycle.LifecycleOwner) {
                    // Final review: a take ends when the APP backgrounds, not on every activity pause (rotation, Recents, split-screen).
                    if (micLazy.isInitialized()) micRecorder.finalizeForExit()
                    if (loopLazy.isInitialized()) loopAudition.stop("superseded")
                    if (patternLazy.isInitialized()) patternEngine.stopPattern("superseded")
                    // Final review: the same "stops when backgrounded" default for the other Studio voices (no notification
                    // or lock-screen control exists for them, and the frozen-app freezer makes them stutter).
                    if (multitrackLazy.isInitialized()) multitrackPlayer.stop("superseded")
                    if (instrumentLazy.isInitialized()) instrumentEngine.let {
                        it.stopReplay("superseded")
                        it.setClickEnabled(false)
                        it.arp.stop()
                    }
                    if (demuxPlayerLazy.isInitialized()) demuxPlayer.stop()
                }
            })
        }
    }

    // ---- STU-5: sequencer pattern playback (lazy; one audible owner with Now Playing / sample / loop auditions)

    private val patternLazy: Lazy<PatternEngine> = lazy {
        val focus = AudioFocusPolicy.FocusHandle(
            audioManager,
            onLoss = { app.appScope.launch(Dispatchers.Main) { patternEngine.stopPattern("focus-loss") } },
            onTransientLoss = { app.appScope.launch(Dispatchers.Main) { patternEngine.parkForInterruption() } },
            onGain = { app.appScope.launch(Dispatchers.Main) { patternEngine.resumeFromInterruption() } },
        )
        PatternEngine(
            sinkFactory = { StudioOutputs.create(audioManager) },
            focus = {
                app.appScope.launch { runCatching { app.playbackController.pause() } }
                if (engineLazy.isInitialized()) studioEngine.pauseSample("superseded")
                if (loopLazy.isInitialized()) loopAudition.stop("superseded")
                focus.requestPlayback()
            },
            focusRelease = { focus.abandon() },
            diag = { msg -> runCatching { com.levi.pocketdj.audio.core.AudioDiag.emit("studio.pattern $msg") } },
        )
    }
    val patternEngine: PatternEngine get() = patternLazy.value.also { ensureLoopStopObserver() }

    // ---- STU-8: instrument packs + SF2 engine + takes (all lazy)

    /** Instrument-pack index + bank downloads (`studio/instruments/`); the index cache lives in app files. */
    val instrumentPacks: com.levi.pocketdj.studio.packs.InstrumentPackStore by lazy {
        com.levi.pocketdj.studio.packs.InstrumentPackStore(
            studioRoots, File(app.appContext.filesDir, "instruments-index-cache.json"), app.appScope,
            log = { msg -> runCatching { com.levi.pocketdj.audio.core.AudioDiag.emit("studio.packs $msg") } },
        )
    }

    val takeRenderer: com.levi.pocketdj.studio.engine.TakeRenderer by lazy {
        com.levi.pocketdj.studio.engine.TakeRenderer(studioRoots, studioStore)
    }

    /** Copies SAF-stored (content://) studio media to a cache file for File-only consumers (LRU-capped). */
    val studioMaterializer: com.levi.pocketdj.studio.store.StudioMaterializer by lazy {
        com.levi.pocketdj.studio.store.StudioMaterializer.forContext(app.appContext)
    }

    val takeFiler: com.levi.pocketdj.studio.engine.TakeFiler by lazy {
        com.levi.pocketdj.studio.engine.TakeFiler(studioRoots, studioStore, takeRenderer, studioRender, materializer = studioMaterializer)
    }

    private val instrumentLazy: Lazy<com.levi.pocketdj.studio.engine.InstrumentEngine> = lazy {
        val focus = AudioFocusPolicy.FocusHandle(audioManager) { app.appScope.launch(Dispatchers.Main) { instrumentEngine.stopReplay("focus-loss"); instrumentEngine.allNotesOff() } }
        com.levi.pocketdj.studio.engine.InstrumentEngine(
            sinkFactory = { StudioOutputs.create(audioManager) },
            scope = app.appScope,
            focus = {
                // One audible owner: park Now Playing and every other Studio voice before the keys sound.
                app.appScope.launch { runCatching { app.playbackController.pause() } }
                if (engineLazy.isInitialized()) studioEngine.pauseSample("superseded")
                if (loopLazy.isInitialized()) loopAudition.stop("superseded")
                if (patternLazy.isInitialized()) patternEngine.stopPattern("superseded")
                focus.requestPlayback()
            },
            focusRelease = { focus.abandon() },
            log = { msg -> runCatching { com.levi.pocketdj.audio.core.AudioDiag.emit("studio.instr $msg") } },
        ).also { eng ->
            // An engine-ended take (length cap) is filed, never silently dropped.
            eng.setOnTakeAutoStopped { r ->
                app.appScope.launch(Dispatchers.IO) {
                    runCatching { takeFiler.file(r, "Take ${studioStore.takes(null).size + 1}", instrumentPacks.localBankFile(r.instrument)) }
                }
            }
        }
    }
    val instrumentEngine: com.levi.pocketdj.studio.engine.InstrumentEngine get() = instrumentLazy.value.also { ensureLoopStopObserver() }

    // MIDI input is app-scoped (iOS keeps BLEMIDIManager + the CoreMIDI client alive): connections survive tab switches / rotation.
    private val midiManager: android.media.midi.MidiManager? by lazy { app.appContext.getSystemService(android.media.midi.MidiManager::class.java) }
    val midiInput: com.levi.pocketdj.studio.midi.MidiInput by lazy {
        com.levi.pocketdj.studio.midi.MidiInput(midiManager, com.levi.pocketdj.studio.midi.EngineMidiSink(instrumentEngine))
    }
    val bleMidiScanner: com.levi.pocketdj.studio.midi.BleMidiScanner by lazy {
        com.levi.pocketdj.studio.midi.BleMidiScanner(app.appContext, midiManager, midiInput)
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
    val micRecorder: MicRecorder get() = micLazy.value.also { ensureLoopStopObserver() }

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

    // ---- STU-7: Collections integration (play studio ids as local files, counts, prepare-on-demand, key analysis)

    private val prepareBackend by lazy {
        object : StudioPrepareBackend {
            override suspend fun ensureSampleRendered(sampleId: String): Boolean = sampleRenderCache.playableFile(sampleId) != null

            // STU-8: a stale instrumental renders through the native SF2 synth from its pack's bank.
            override suspend fun renderTake(takeId: String): Boolean {
                val take = studioStore.take(takeId) ?: return false
                return runCatching { takeRenderer.render(take) { instrumentPacks.localBankFile(it) } }.getOrNull() != null
            }

            override suspend fun targetBuffer(targetId: String): PcmBuffer? {
                val file: File? = when {
                    targetId.startsWith("smp_") -> sampleRenderCache.playableFile(targetId)
                    else -> studioStore.localUrlForPlayback(targetId)?.ref?.file
                }
                val decoded = file?.let { runCatching { studioRender.decodeBuffer(it.path) }.getOrNull() } ?: return null
                val loop = if (targetId.startsWith("lp_")) studioStore.loop(targetId) else null
                return if (loop != null) StudioPlayback.exactLoopBuffer(decoded, loop.frames) else decoded
            }

            override suspend fun stretchSpans(pattern: StudioPattern, natural: Map<String, PcmBuffer>) =
                PatternBouncer.stretchSpanBuffers(pattern, natural) { b, f -> studioRender.stretchBuffer(b, f) }

            override suspend fun bouncePattern(
                pattern: StudioPattern, buffers: Map<String, PcmBuffer>, spans: Map<StudioStretchKey, PcmBuffer>,
            ): BouncedFile? {
                val name = StudioPlayback.patternFileName(pattern.id)
                // iOS ensureBounced: the ACTIVE sequences folder (user root when configured + writable, else app root).
                val (dir, isUser) = StudioFolders.writeFolder(studioRoots, StudioFamily.SEQUENCES)
                val direct = (dir as? FileStudioDir)?.dir?.let { File(it, name) }
                if (direct != null) {
                    PatternBouncer.bounce(pattern, buffers, spans, direct)
                } else {
                    // SAF tree: bounce to an app-private temp file, then stream it into the chosen folder.
                    val tmp = StudioFiles.appFile(studioRoots, StudioFamily.SEQUENCES, ".tmp-$name") ?: return null
                    try {
                        PatternBouncer.bounce(pattern, buffers, spans, tmp)
                        val out = dir.openOutput(name) ?: return null
                        out.use { o -> tmp.inputStream().use { it.copyTo(o) } }
                    } finally { tmp.delete() }
                }
                return BouncedFile(name, isUser)
            }
        }
    }

    /** Resolve + prepare-on-demand for studio ids; also the Collections `studioLookup` source. */
    val studioPlayback: StudioPlayback by lazy { StudioPlayback(studioStore, prepareBackend) }

    /** Key detection when an item enters a collection (idempotent). */
    val studioAnalyzer: StudioAnalyzer by lazy {
        StudioAnalyzer(studioStore, studioPlayback, studioMaterializer) { path -> runCatching { studioRender.decodeBuffer(path) }.getOrNull() }
    }

    /** Wired into AppGraph's collections init: lazy, so a user who never has a studio id never builds the store. */
    val collectionsLookup: StudioLookup = StudioLookup { id -> studioPlayback.infoFor(id) }

    /** Settings > Storage per-family usage + STRICT delete-all (unreachable roots keep records; active take skipped). */
    val storageOps: StorageService.StudioStorageOps = object : StorageService.StudioStorageOps {
        override fun usageBytes(family: StudioFamily): Long = studioStore.usageBytes(family)
        override fun deleteAll(family: StudioFamily) { studioStore.deleteAll(family); studioStore.flush() }
        override fun recordCount(family: StudioFamily): Int = studioStore.state.value.let {
            when (family) {
                StudioFamily.SAMPLES -> it.samples.size
                StudioFamily.LOOPS -> it.loops.size
                StudioFamily.SEQUENCES -> it.patterns.size
                StudioFamily.TAKES -> it.takes.size
                StudioFamily.INSTRUMENTS -> 0
            }
        }
    }

    /**
     * Register the STUDIO_LOCAL row rung and make the device-mode "is this row on the device" probe
     * studio-aware. Cheap (nothing lazy is forced); called once from AppGraph init.
     */
    fun wire() {
        val ctl = app.playbackController
        ctl.rowResolvers.register(StudioRowResolver(prepare = { id -> studioPlayback.prepare(id) }))
        val prevOnDevice = ctl.sequencer.rowOnDevice
        ctl.sequencer.rowOnDevice = { item ->
            prevOnDevice(item) || StudioRowResolver.studioIdOf(item)?.let { studioPlayback.isOnDeviceNow(it) } == true
        }
    }

    // ---- STU-14: Demuxer core (lazy; a user who never opens the Demuxer pays nothing)

    /** `filesDir/demux-cache/<key>.json` + `audio/` + `stems/<key>/` (same layout as the iOS Application Support folder). */
    val demuxStore: com.levi.pocketdj.studio.demux.DemuxStore by lazy {
        val http = app.httpClient
        com.levi.pocketdj.studio.demux.DemuxStore(
            cacheDir = File(app.appContext.filesDir, "demux-cache").also { it.mkdirs() },
            fetch = { url, dest ->
                kotlinx.coroutines.withContext(Dispatchers.IO) {
                    runCatching {
                        http.newCall(okhttp3.Request.Builder().url(url).build()).execute().use { r ->
                            if (!r.isSuccessful) return@use false
                            r.body?.byteStream()?.use { input -> dest.outputStream().use { input.copyTo(it) } }
                            dest.length() > 0
                        }
                    }.getOrDefault(false)
                }
            },
        )
    }

    val demuxStemClient: com.levi.pocketdj.studio.demux.DemuxStemClient by lazy {
        com.levi.pocketdj.studio.demux.DemuxStemClient(
            http = app.httpClient,
            configProvider = {
                val cur = app.settings.current()
                com.levi.pocketdj.data.rips.RipServerClient.Config(cur.ripServerUrl, cur.ripToken, app.settings.ensureInstallId())
            },
            ripsBase = { com.levi.pocketdj.data.config.Endpoints.RIPS_BASE },
        )
    }

    private val demuxPlayerLazy: Lazy<com.levi.pocketdj.studio.demux.StemPlayer> = lazy {
        val focus = AudioFocusPolicy.FocusHandle(audioManager) {
            app.appScope.launch(Dispatchers.Main) { if (demuxPlayer.isPlaying) { StudioDiag.stop("demux", "focus-loss"); demuxPlayer.togglePlayPause() } }
        }
        val request = {
            // One audible owner: park Now Playing and every Studio voice before the Demuxer sounds.
            app.appScope.launch { runCatching { app.playbackController.pause() } }
            if (engineLazy.isInitialized()) studioEngine.pauseSample("superseded")
            if (loopLazy.isInitialized()) loopAudition.stop("superseded")
            if (patternLazy.isInitialized()) patternEngine.stopPattern("superseded")
            focus.requestPlayback()
            Unit
        }
        com.levi.pocketdj.studio.demux.RoutingStemPlayer(
            single = com.levi.pocketdj.studio.demux.SingleFileStemPlayer(request) { focus.abandon() },
            multi = com.levi.pocketdj.studio.demux.VoiceGroupStemPlayer(
                sinkFactory = { StudioOutputs.create(audioManager) },
                openSource = { f -> runCatching { com.levi.pocketdj.audio.core.Mp3Decoder(f) as com.levi.pocketdj.audio.core.PcmSource }.getOrNull() },
                scope = app.appScope, focus = request, focusRelease = { focus.abandon() },
            ),
            scope = app.appScope,
        )
    }
    private val demuxPlayer: com.levi.pocketdj.studio.demux.StemPlayer get() = demuxPlayerLazy.value.also { ensureLoopStopObserver() }

    /** The Demuxer's selection/resolve/stems state machine (one per app; the screen is a pure renderer of it). */
    /** STU-15: drum-pattern / melody analyzers + cloud lyrics (one run per source key). */
    val demuxAnalyzers: com.levi.pocketdj.studio.demux.DemuxAnalyzers by lazy {
        com.levi.pocketdj.studio.demux.DemuxAnalyzers(app.appScope, demuxStore)
    }

    /** STU-15: the Demuxer's hand-offs into Studio (sequencer pattern, instrumental take, cut sample, stems -> arrangement). */
    val demuxExporter: com.levi.pocketdj.studio.demux.DemuxExporter by lazy {
        com.levi.pocketdj.studio.demux.DemuxExporter(studioRoots, studioStore, studioRender, takeRenderer, { instrumentPacks.localBankFile(it) })
    }

    val demuxSession: com.levi.pocketdj.studio.demux.DemuxSession by lazy {
        com.levi.pocketdj.studio.demux.DemuxSession(
            app.appScope, demuxStore, DemuxAppEnv(), demuxPlayer,
            @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class) Dispatchers.Default.limitedParallelism(1),
        )
    }

    private inner class DemuxAppEnv : com.levi.pocketdj.studio.demux.DemuxEnv {
        private val burns get() = app.servicesGraph.burnStore

        override fun songInfo(songId: String): com.levi.pocketdj.studio.demux.DemuxSongInfo? {
            val song = app.catalogRepository.state.value.catalog?.songsById?.get(songId) ?: return null
            val len = song.length?.takeIf { it > 0 }?.toInt() ?: app.ripsRepository.entry(songId)?.durationMs?.takeIf { it > 0 }?.toInt() ?: 1
            return com.levi.pocketdj.studio.demux.DemuxSongInfo(song.name, song.artist, len)
        }

        override fun localSong(songId: String): com.levi.pocketdj.studio.demux.DemuxLocalSong? =
            burns.localUrlPreferringCut(songId)?.let {
                com.levi.pocketdj.studio.demux.DemuxLocalSong(it.file, it.isCut, burns.startMs(songId)?.toInt() ?: 0)
            }

        override fun inManifest(songId: String) = app.ripsRepository.entry(songId) != null

        override suspend fun burn(songId: String, title: String, artist: String): Boolean =
            runCatching { burns.burn(listOf(BurnSong(songId, title, artist))).burned > 0 }.getOrDefault(false)

        override suspend fun carve(src: File, startMs: Int, endMs: Int, dest: File): Boolean =
            runCatching { studioRender.carveTrackRegion(src.path, startMs, endMs, dest); dest.isFile }.getOrDefault(false)

        private val studioFiles = com.levi.pocketdj.studio.store.SingleLeaseFiles(
            { id -> studioStore.localUrlForPlayback(id)?.ref }, studioMaterializer,
        )

        override suspend fun studioFile(id: String): File? = studioFiles.file(id)

        override suspend fun hasServer() = app.ripServerClient.isConfigured()
        override fun songStemsBurned(songId: String) = burns.stemsBurned(songId)
        override fun songIsStemmed(songId: String) = app.ripsRepository.entry(songId)?.isStemmed == true
        override suspend fun burnSongStems(songId: String) = burns.burnStems(songId)
        override fun songStemFiles(songId: String) = burns.localStemFiles(songId)

        override suspend fun stemifySong(songId: String): Boolean {
            val tracker = app.ripJobTracker
            tracker.stemify(songId)
            val deadline = System.currentTimeMillis() + 4L * 60 * 60 * 1000 // matches the tracker's stemDeadlineMs
            while (System.currentTimeMillis() < deadline) {
                if (songIsStemmed(songId)) return true
                val phase = tracker.stemJobs.value[songId]?.phase
                // READY is terminal (the tracker already refreshed the manifest): stemmed or not, stop polling.
                if (phase == com.levi.pocketdj.data.stems.StemPhase.READY) return songIsStemmed(songId)
                if (phase == com.levi.pocketdj.data.stems.StemPhase.ERROR || phase == com.levi.pocketdj.data.stems.StemPhase.INELIGIBLE) return false
                if (phase == null && !tracker.isStemPolling(songId)) return songIsStemmed(songId)
                kotlinx.coroutines.delay(1_500)
            }
            return songIsStemmed(songId)
        }

        override suspend fun stemifyCustom(id: String, file: File) = demuxStemClient.stemifyCustom(id, file)

        override suspend fun peaks(file: File, durationMs: Int): FloatArray = kotlinx.coroutines.withContext(Dispatchers.Default) {
            if (file.extension.lowercase() == "mp3") com.levi.pocketdj.screens.mix.WaveformExtractor.peaks(file, null, null, 600)
            else runCatching {
                // 8 kHz is plenty for a 600-bucket envelope and keeps a long file under ~16 MB of float PCM.
                com.levi.pocketdj.audio.core.AudioDecoder.decode(file.path, 8_000)
                    ?.let { com.levi.pocketdj.screens.producer.common.WaveformMath.peaks(it, 600) }
            }.getOrNull() ?: FloatArray(0)
        }

        override fun fileLengthMs(file: File): Int {
            val r = android.media.MediaMetadataRetriever()
            return try {
                r.setDataSource(file.path)
                r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toIntOrNull()?.coerceAtLeast(1) ?: 1
            } catch (_: Exception) { 1 } finally { runCatching { r.release() } }
        }
    }

    override val settingsSections: List<com.levi.pocketdj.shell.SettingsSection> by lazy { listOf(studioStorageSection()) }

    // A user who never touched Studio must not build/reconcile/rewrite the doc on ON_STOP.
    // A take in flight is filed + the store flushed synchronously (Android blocks background mic capture).
    override val flushables: List<Flushable> = listOf(
        // (the mic take is finalized by the process ON_STOP observer, NOT here: this funnel also runs on onPause/rotation)
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

    override val syncEntries: List<SyncEntry> = listOf(
        // Final review: adopt pulled cues (building the store off the sync thread if need be); otherwise the next
        // local cue edit rewrites the mirror from stale memory and wipes the other device's cues in the cloud.
        SyncEntry("studio-cues", "pocketdj-studio.cues.json", onPulled = { studioStore.reloadCuesFromDisk() }),
    )

    override val deepLinkHandlers: List<DeepLinkHandler> = listOf(
        DeepLinkHandler { intent ->
            val seed = com.levi.pocketdj.studio.StudioSeed.requested(
                isDebuggable(), intent.getBooleanExtra(SEED_EXTRA, false), intent.getBooleanExtra(SEED_DEMUX_EXTRA, false),
            )
            if (seed.studio) app.appScope.launch(Dispatchers.IO) { runCatching { seedFixture() } }
            if (seed.demux) app.appScope.launch(Dispatchers.IO) { runCatching { seedDemuxFixture() } }
            false   // never consumes the intent
        },
    )

    private fun isDebuggable(): Boolean =
        (app.appContext.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0

    /** Debug fixture (`--ez PDJ_SEED_STUDIO true`); see [com.levi.pocketdj.studio.StudioSeed]. */
    fun seedFixture() = com.levi.pocketdj.studio.StudioSeed.seedStudio(studioStore, app.appContext)

    /** Debug fixture (`--ez PDJ_SEED_DEMUX true`): imports the bundled 1 s tone as a Demuxer source. */
    fun seedDemuxFixture() = com.levi.pocketdj.studio.StudioSeed.seedDemux(demuxStore, app.appContext)

    companion object {
        const val SEED_EXTRA = com.levi.pocketdj.studio.StudioSeed.STUDIO_EXTRA
        const val SEED_DEMUX_EXTRA = com.levi.pocketdj.studio.StudioSeed.DEMUX_EXTRA
    }
}
