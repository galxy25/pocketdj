package com.levi.pocketdj.studio.demux

import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** The loaded source's resolve ladder phase (iOS StudioDemuxView.Phase). */
sealed class DemuxPhase {
    object Idle : DemuxPhase()
    object Resolving : DemuxPhase()
    object Ready : DemuxPhase()
    object NeedsBurn : DemuxPhase()
    object Burning : DemuxPhase()
    object RipFirst : DemuxPhase()
    data class Failed(val message: String) : DemuxPhase()
}

/** Stem availability for the loaded source (iOS StemState). */
sealed class DemuxStemState {
    object None : DemuxStemState()
    object Creatable : DemuxStemState()
    object Creating : DemuxStemState()
    object Downloadable : DemuxStemState()
    object Downloading : DemuxStemState()
    object Burned : DemuxStemState()
    data class Failed(val message: String) : DemuxStemState()
}

data class DemuxSongInfo(val title: String, val artist: String, val lengthMs: Int)

/** A song's on-device audio: [offsetMs] > 0 means a shared analog side that must be carved once. */
data class DemuxLocalSong(val file: File, val isCut: Boolean, val offsetMs: Int)

/** Everything the session needs from the app (catalog, burns, studio, rip server) so the ladder is JVM-testable. */
interface DemuxEnv {
    fun songInfo(songId: String): DemuxSongInfo?
    fun localSong(songId: String): DemuxLocalSong?
    fun inManifest(songId: String): Boolean
    /** Burn-on-demand; true when a local file should now exist. */
    suspend fun burn(songId: String, title: String, artist: String): Boolean
    /** Carve [startMs, endMs) of [src] into [dest]; true on success. */
    suspend fun carve(src: File, startMs: Int, endMs: Int, dest: File): Boolean
    /** Playable local file for a Performance item; a SAF-stored one is copied into the cache (suspend). */
    suspend fun studioFile(id: String): File?
    suspend fun hasServer(): Boolean
    fun songStemsBurned(songId: String): Boolean
    fun songIsStemmed(songId: String): Boolean
    suspend fun burnSongStems(songId: String): Map<String, File>?
    fun songStemFiles(songId: String): Map<String, File>?
    /** Request + await catalog stemify; true when the manifest now says stemmed. */
    suspend fun stemifySong(songId: String): Boolean
    suspend fun stemifyCustom(id: String, file: File): Map<String, String>?
    suspend fun peaks(file: File, durationMs: Int): FloatArray
    fun fileLengthMs(file: File): Int
}

/**
 * The Demuxer's selection/resolve/stems state machine (the logic half of iOS StudioDemuxView):
 *  - [select] cancels the in-flight resolve and bumps a generation token; EVERY await point re-checks
 *    [isCurrent] so an older selection finishing later can never overwrite the current one;
 *  - the resolve ladder: imported file -> studio item -> song (local, carved once for analog sides,
 *    else NeedsBurn when in the manifest, else RipFirst);
 *  - stems: Burned / Downloadable / Creatable / Creating / Downloading / Failed, all-or-nothing downloads.
 * The player is shared and owned here so a re-select always stops the previous audio.
 */
class DemuxSession(
    private val scope: CoroutineScope,
    private val store: DemuxStore,
    private val env: DemuxEnv,
    val player: StemPlayer,
    /** All player load/stop calls run here (ONE thread in production) so a stale blocking load can never race a stop. */
    private val playerContext: CoroutineDispatcher = Dispatchers.Unconfined,
) {
    private val _source = MutableStateFlow<DemuxSource?>(null)
    val source: StateFlow<DemuxSource?> = _source.asStateFlow()
    private val _phase = MutableStateFlow<DemuxPhase>(DemuxPhase.Idle)
    val phase: StateFlow<DemuxPhase> = _phase.asStateFlow()
    private val _stemState = MutableStateFlow<DemuxStemState>(DemuxStemState.None)
    val stemState: StateFlow<DemuxStemState> = _stemState.asStateFlow()
    private val _audio = MutableStateFlow<File?>(null)
    val audioFile: StateFlow<File?> = _audio.asStateFlow()
    private val _durationMs = MutableStateFlow(0)
    val durationMs: StateFlow<Int> = _durationMs.asStateFlow()
    private val _peaks = MutableStateFlow(FloatArray(0))
    val peaks: StateFlow<FloatArray> = _peaks.asStateFlow()
    private val _stemMode = MutableStateFlow(false)
    val stemMode: StateFlow<Boolean> = _stemMode.asStateFlow()

    private var resolveJob: Job? = null
    @Volatile private var generation = 0
    private var stemJob: Job? = null

    /** Test/diagnostic: the resolve job (join it). */
    val resolving: Job? get() = resolveJob

    fun select(src: DemuxSource): Job {
        resolveJob?.cancel()
        clearSource()
        val gen = ++generation
        _source.value = src
        _phase.value = DemuxPhase.Resolving
        return scope.launch { resolve(src, gen) }.also { resolveJob = it }
    }

    /** A resolve that woke from an await must still be the CURRENT run before it writes any state. */
    private fun isCurrent(src: DemuxSource, gen: Int): Boolean =
        gen == generation && _source.value?.key == src.key

    fun clearSource() {
        resolveJob?.cancel()
        stemJob?.cancel(); stemJob = null
        generation++
        stopPlayer()
        _source.value = null
        _phase.value = DemuxPhase.Idle
        _stemState.value = DemuxStemState.None
        _stemMode.value = false
        _audio.value = null
        _durationMs.value = 0
        _peaks.value = FloatArray(0)
    }

    /** Ordered on [playerContext] so it lands after any load already running there. */
    private fun stopPlayer() { scope.launch(playerContext) { runCatching { player.stop() } } }

    private suspend fun resolve(src: DemuxSource, gen: Int) {
        when (src) {
            is DemuxSource.ImportedFile -> {
                val f = store.importedAudioFile(src.id)
                if (f == null) { fail(src, gen, "This imported file is gone from the demux cache. Import it again."); return }
                enterReady(src, gen, f, env.fileLengthMs(f))
            }
            is DemuxSource.Studio -> {
                val f = env.studioFile(src.id)
                if (f == null) { fail(src, gen, "This item has no playable audio yet (render or bounce it first)."); return }
                enterReady(src, gen, f, env.fileLengthMs(f))
            }
            is DemuxSource.Song -> {
                val info = env.songInfo(src.id)
                if (info == null) { fail(src, gen, "This track isn’t in the loaded catalog anymore."); return }
                val local = ensureSongAudio(src.id, info)
                if (!isCurrent(src, gen)) return
                if (local != null) enterReady(src, gen, local, info.lengthMs)
                else _phase.value = if (env.inManifest(src.id)) DemuxPhase.NeedsBurn else DemuxPhase.RipFirst
            }
        }
    }

    private fun fail(src: DemuxSource, gen: Int, msg: String) { if (isCurrent(src, gen)) _phase.value = DemuxPhase.Failed(msg) }

    /**
     * A local file whose 0:00 is the SONG's 0:00: a per-song cut or digital rip plays as-is; a shared analog
     * album side is carved ONCE into the demux audio cache (re-select reuses it).
     */
    private suspend fun ensureSongAudio(songId: String, info: DemuxSongInfo): File? {
        val h = env.localSong(songId) ?: return null
        val offset = if (h.isCut) 0 else h.offsetMs
        if (offset == 0) return h.file
        store.carvedSongFile(songId)?.let { return it }
        val dest = store.carvedSongDestination(songId) ?: return null
        return if (env.carve(h.file, offset, offset + info.lengthMs, dest)) dest else null
    }

    private suspend fun enterReady(src: DemuxSource, gen: Int, file: File, lengthMs: Int) {
        if (!isCurrent(src, gen)) return
        _audio.value = file
        val dur = maxOf(lengthMs, 1)
        _durationMs.value = dur
        store.update(src) { it.copy(durationMs = maxOf(it.durationMs, dur)) }
        refreshStemState(src)
        if (!isCurrent(src, gen)) return
        val loaded = withContext(playerContext) {
            isCurrent(src, gen) && runCatching { player.load("${src.key}#mix", mapOf("vocals" to file)) }.getOrDefault(false)
        }
        if (!isCurrent(src, gen)) return
        if (!loaded) {
            _audio.value = null
            _phase.value = DemuxPhase.Failed("Couldn’t play this audio")
            return
        }
        _phase.value = DemuxPhase.Ready
        store.analyzeChords(scope, src, file.path, dur)
        val p = env.peaks(file, dur)
        if (!isCurrent(src, gen)) return
        _peaks.value = p
    }

    /** "Burn + demux" from the NeedsBurn state. */
    fun burnThenReady(): Job? {
        val src = _source.value as? DemuxSource.Song ?: return null
        val gen = generation
        return scope.launch {
            _phase.value = DemuxPhase.Burning
            val ok = env.burn(src.id, src.title, src.artist)
            if (!isCurrent(src, gen)) return@launch
            val info = env.songInfo(src.id)
            val local = if (ok && info != null) ensureSongAudio(src.id, info) else null
            if (!isCurrent(src, gen)) return@launch
            if (local != null && info != null) enterReady(src, gen, local, info.lengthMs)
            else _phase.value = DemuxPhase.Failed("Couldn’t burn this track for demuxing.")
        }.also { resolveJob = it }
    }

    // ---- stems -------------------------------------------------------------------------------

    suspend fun refreshStemState(src: DemuxSource) {
        val songId = src.songId
        val server = env.hasServer()
        _stemState.value = if (songId == null) {
            when {
                store.localStemFiles(src.key) != null -> DemuxStemState.Burned
                server -> DemuxStemState.Creatable
                else -> DemuxStemState.None
            }
        } else when {
            env.songStemsBurned(songId) -> DemuxStemState.Burned
            env.songIsStemmed(songId) -> DemuxStemState.Downloadable
            server && env.inManifest(songId) -> DemuxStemState.Creatable
            else -> DemuxStemState.None
        }
    }

    fun downloadStems(): Job? {
        val src = _source.value ?: return null
        val songId = src.songId ?: return null
        val gen = generation
        return scope.launch {
            _stemState.value = DemuxStemState.Downloading
            val got = env.burnSongStems(songId)
            if (gen != generation) return@launch
            _stemState.value = if (got != null) DemuxStemState.Burned else DemuxStemState.Failed("Couldn’t download this track’s stems.")
        }.also { stemJob = it }
    }

    /** Trigger separation on the import server, then pull the stems down (catalog: /stemify; custom: upload). */
    fun createStems(): Job? {
        val src = _source.value ?: return null
        val gen = generation
        return scope.launch {
            _stemState.value = DemuxStemState.Creating
            val songId = src.songId
            if (songId != null) {
                val ok = env.stemifySong(songId)
                if (gen != generation) return@launch
                if (!ok) { _stemState.value = DemuxStemState.Failed("The import server couldn’t stem this track (check it’s reachable and try again)."); return@launch }
                _stemState.value = DemuxStemState.Downloading
                val got = env.burnSongStems(songId)
                if (gen != generation) return@launch
                _stemState.value = if (got != null) DemuxStemState.Burned else DemuxStemState.Failed("Couldn’t download this track’s stems.")
                return@launch
            }
            val audio = _audio.value
            if (audio == null) { _stemState.value = DemuxStemState.Failed("No local audio to upload."); return@launch }
            val remote = env.stemifyCustom(src.key, audio)
            if (gen != generation) return@launch
            if (remote == null) { _stemState.value = DemuxStemState.Failed("The import server couldn’t stem this audio (check it’s reachable and try again)."); return@launch }
            _stemState.value = DemuxStemState.Downloading
            val files = store.downloadStems(src.key, remote)
            if (gen != generation) return@launch
            _stemState.value = if (files != null) DemuxStemState.Burned else DemuxStemState.Failed("Couldn’t download the separated stems.")
        }.also { stemJob = it }
    }

    /**
     * Flip the Stems switch: reload the shared player in mix or stems mode, preserving position + play state.
     * Loading runs on [playerContext] (never the UI thread); stem mode is only reported when the stems really
     * loaded, otherwise the mix is restored.
     */
    fun setStemMode(on: Boolean): Job? {
        val src = _source.value ?: return null
        val gen = generation
        val pos = player.currentTimeSec
        val wasPlaying = player.isPlaying
        val stems = if (on) (src.songId?.let { env.songStemFiles(it) } ?: store.localStemFiles(src.key)) else null
        val audio = _audio.value
        if (stems == null && audio == null) return null
        return scope.launch(playerContext) {
            if (!isCurrent(src, gen)) return@launch
            var stemsOn = false
            var ok = false
            if (stems != null) {
                ok = runCatching { player.load("${src.key}#stems", stems) }.getOrDefault(false)
                stemsOn = ok
            }
            if (!ok && audio != null) ok = runCatching { player.load("${src.key}#mix", mapOf("vocals" to audio)) }.getOrDefault(false)
            if (!isCurrent(src, gen)) return@launch
            _stemMode.value = stemsOn
            if (!ok) return@launch
            player.seek(pos)
            if (wasPlaying && !player.isPlaying) player.togglePlayPause()
        }
    }

    /** Re-run chord detection over the loaded audio (the failed-status Retry). */
    fun reanalyzeChords() {
        val src = _source.value ?: return
        val file = _audio.value ?: return
        store.analyzeChords(scope, src, file.path, _durationMs.value, force = true)
    }

    fun seekMs(ms: Int) = player.seek(ms / 1000.0)

    fun dispose() { resolveJob?.cancel(); stemJob?.cancel(); generation++; stopPlayer() }
}
