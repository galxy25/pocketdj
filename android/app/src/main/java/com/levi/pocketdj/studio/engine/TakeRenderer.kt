package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.StudioFiles
import com.levi.pocketdj.studio.audio.AndroidStudioCodec
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.audio.StudioCodec
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.model.StudioTake
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.StudioRoots
import com.levi.pocketdj.studio.store.StudioStore
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

/** One scheduled synth action; times are ms from beat 1 (the take clock). */
data class NoteAction(val ms: Int, val on: Boolean, val note: Int, val velocity: Int)

/** Pure score -> action math shared by live replay and the offline render (iOS `replayActions`). */
object TakeScore {
    /** On/off list in time order; offs sort BEFORE ons at the same instant so a retrigger re-strikes. */
    fun actions(events: List<StudioNoteEvent>): List<NoteAction> {
        val out = ArrayList<NoteAction>(events.size * 2)
        for (e in events) {
            val on = max(0, e.onMs)
            out.add(NoteAction(on, true, e.note, e.velocity))
            // min 1 ms: a zero-length note would sort its off BEFORE its on and hang
            out.add(NoteAction(max(on + 1, e.offMs), false, e.note, e.velocity))
        }
        return out.sortedWith(ORDER)
    }

    /**
     * Actions for a replay STARTING at [from]: everything before it is dropped, except a note that began earlier
     * and is still sounding at [from] is struck AT [from] (MIDI "chase").
     */
    fun actions(events: List<StudioNoteEvent>, from: Int): List<NoteAction> {
        if (from <= 0) return actions(events)
        val out = actions(events).filter { it.ms >= from }.toMutableList()
        for (e in events) if (max(0, e.onMs) < from && max(max(0, e.onMs), e.offMs) > from) out.add(NoteAction(from, true, e.note, e.velocity))
        return out.sortedWith(ORDER)
    }

    private val ORDER = Comparator<NoteAction> { a, b -> if (a.ms != b.ms) a.ms.compareTo(b.ms) else if (a.on == b.on) 0 else if (!a.on) -1 else 1 }

    /** End of the score (last note-off) in ms. */
    fun endMs(events: List<StudioNoteEvent>): Int = events.maxOfOrNull { max(it.onMs, it.offMs) } ?: 0

    /** Rescale note times by oldBpm/newBpm (the same math as `StudioStore.setTakeTempo`). */
    fun rescaled(events: List<StudioNoteEvent>, oldBpm: Double, newBpm: Double): List<StudioNoteEvent> {
        if (!(oldBpm > 0) || !(newBpm > 0)) return events
        val scale = oldBpm / newBpm
        return events.map { it.copy(onMs = Math.round(it.onMs * scale).toInt(), offMs = Math.round(it.offMs * scale).toInt()) }
    }
}

/** Why a take render failed. */
sealed class TakeRenderException(msg: String) : Exception(msg) {
    class EmptyTake : TakeRenderException("no notes to render")
    class BankMissing(val instrument: InstrumentKey) : TakeRenderException("${instrument.displayName} pack not downloaded")
    class BankLoadFailed(val path: String) : TakeRenderException("couldn't load sound bank $path")
}

/**
 * Offline SoundFont take renderer (iOS `StudioRender.renderTake`): events -> PCM through a fresh synth (notes
 * fire frame-accurately, the release rings out into the -60 dBFS / 3 s tail drain), multi-staff mixed with a
 * float sum + hard clamp, written atomically as AAC m4a. The click is never part of this graph, so it can never
 * be in a rendered take.
 */
class TakeRenderer(
    private val roots: StudioRoots,
    private val store: StudioStore,
    private val synthFactory: () -> SynthVoice = { Sf2SynthVoice() },
    private val codec: StudioCodec = AndroidStudioCodec,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default,
) {
    private val mutex = Mutex()

    /** One staff -> canonical PCM (a fresh synth per call, closed on return). */
    fun renderStaffPcm(events: List<StudioNoteEvent>, bank: File, program: Int): PcmBuffer {
        val actions = TakeScore.actions(events)
        if (actions.isEmpty()) throw TakeRenderException.EmptyTake()
        val synth = synthFactory()
        try {
            if (!synth.load(bank.path) || !synth.setPreset(0, program)) throw TakeRenderException.BankLoadFailed(bank.path)
            return pump(synth, actions, StudioAudio.CANONICAL_RATE)
        } finally {
            synth.close()
        }
    }

    /**
     * Render [take]'s CURRENT score (edited events, every staff) to its rendered-cache file and file it with the
     * store. [bankFor] maps an instrument to its downloaded bank (null => pack missing). Returns the file, or null
     * when an edit landed mid-render (revision mismatch: the stale render is dropped).
     */
    suspend fun render(take: StudioTake, bankFor: (InstrumentKey) -> File?): File? = mutex.withLock {
        withContext(dispatcher) {
            val staffs = ArrayList<Triple<List<StudioNoteEvent>, InstrumentKey, Int>>()
            staffs.add(Triple(take.scoreEvents, take.instrument, take.instrument.gmProgram))
            take.extraStaffs?.forEach { staffs.add(Triple(it.scoreEvents, it.instrument, it.instrument.gmProgram)) }
            val buffers = ArrayList<PcmBuffer>()
            for ((events, inst, program) in staffs) {
                if (events.isEmpty()) continue
                val bank = bankFor(inst) ?: throw TakeRenderException.BankMissing(inst)
                buffers.add(renderStaffPcm(events, bank, program))
            }
            if (buffers.isEmpty()) throw TakeRenderException.EmptyTake()
            val pcm = if (buffers.size == 1) buffers[0] else StudioAudio.mixPcm(buffers)
            val name = StudioFolders.renderedTakeFileName(take.id, take.renderRevision)
            val dest = StudioFiles.appFile(roots, StudioFamily.TAKES, name) ?: throw java.io.IOException("no takes folder")
            writeAtomically(dest) { codec.writeM4a(pcm, it) }
            if (store.setTakeRendered(take.id, name, false, take.renderRevision)) dest else null
        }
    }

    /** The take's RAW audio file (rendered once at record time from the raw events). */
    suspend fun renderRaw(takeId: String, events: List<StudioNoteEvent>, instrument: InstrumentKey, bank: File, fileName: String): Int = mutex.withLock {
        withContext(dispatcher) {
            val pcm = renderStaffPcm(events, bank, instrument.gmProgram)
            val dest = StudioFiles.appFile(roots, StudioFamily.TAKES, fileName) ?: throw java.io.IOException("no takes folder")
            writeAtomically(dest) { codec.writeM4a(pcm, it) }
            Math.round(pcm.frames.toDouble() / StudioAudio.CANONICAL_RATE * 1000).toInt()
        }
    }

    private fun writeAtomically(dest: File, body: (File) -> Unit) {
        val dir = dest.absoluteFile.parentFile ?: throw java.io.IOException("no parent")
        dir.mkdirs()
        val tmp = File(dir, ".take-render-${UUID.randomUUID()}-${dest.name}")
        try {
            body(tmp)
            dest.delete()
            if (!tmp.renameTo(dest)) throw java.io.IOException("rename failed")
        } catch (t: Throwable) { tmp.delete(); throw t }
    }

    companion object {
        const val CHUNK_FRAMES = 512

        /**
         * Event-driven offline pump: render in blocks, firing each action at its exact frame (a block is split at
         * an event), then drain the release tail (first 512-frame window under -60 dBFS RMS, or 3 s). Frame 0 is
         * musical frame 0. Pure over [SynthVoice] so it is JVM-testable with a fake.
         */
        fun pump(synth: SynthVoice, actions: List<NoteAction>, sampleRate: Int): PcmBuffer {
            val lastMs = actions.maxOfOrNull { it.ms } ?: 0
            val nominal = Math.round(lastMs / 1000.0 * sampleRate)
            val capacity = nominal + (StudioAudio.TAIL_CAP_SECONDS * sampleRate).toLong() + CHUNK_FRAMES
            require(capacity < Int.MAX_VALUE / 2) { "take too long" }
            var acc = FloatArray(((nominal + 4096).coerceAtMost(capacity)).toInt() * 2)
            var written = 0L
            val scratch = FloatArray(CHUNK_FRAMES * 2)
            fun renderTo(target: Long) {
                while (written < target) {
                    val n = min(CHUNK_FRAMES.toLong(), target - written).toInt()
                    synth.render(scratch, n, false)
                    val need = ((written + n) * 2).toInt()
                    if (need > acc.size) acc = acc.copyOf(max(need, acc.size * 2).coerceAtMost((capacity * 2).toInt()))
                    System.arraycopy(scratch, 0, acc, (written * 2).toInt(), n * 2)
                    written += n
                }
            }
            for (a in actions) {
                renderTo(Math.round(max(0, a.ms) / 1000.0 * sampleRate))
                if (a.on) synth.noteOn(a.note.coerceIn(0, 127), a.velocity.coerceIn(1, 127)) else synth.noteOff(a.note.coerceIn(0, 127))
            }
            renderTo(nominal)
            // tail drain: windows are kept; the first below-floor window ends it
            val cap = nominal + (StudioAudio.TAIL_CAP_SECONDS * sampleRate).toLong()
            while (written < cap) {
                val start = written
                renderTo(min(cap, written + StudioAudio.TAIL_WINDOW_FRAMES))
                if (StudioAudio.isBelowFloor(acc, (start * 2).toInt(), ((written - start) * 2).toInt())) break
            }
            synth.allOff()
            return PcmBuffer(sampleRate, 2, acc.copyOf((written * 2).toInt()))
        }
    }
}

/** Why filing a take / making a sample from one failed (the UI maps each to copy). */
sealed class TakeFileFailure(val message: String) {
    object NoNotes : TakeFileFailure("No notes were played, so there's nothing to save.")
    class PackMissing(val instrument: InstrumentKey) : TakeFileFailure("Download the ${instrument.displayName} pack first.")
    object Failed : TakeFileFailure("Couldn't save that take.")
}

class TakeFileException(val failure: TakeFileFailure) : Exception(failure.message)

/**
 * Files a finished recording and derives samples from takes: the take's audio is rendered from its events
 * (the click was never in the graph), the record is added through [StudioStore.addTakeRelocating], and
 * "Use as sample" COPIES the audio into its own sample file — the sample outlives its take.
 */
class TakeFiler(
    private val roots: StudioRoots,
    private val store: StudioStore,
    private val renderer: TakeRenderer,
    private val studioRender: com.levi.pocketdj.studio.audio.StudioRender,
    /** Makes a SAF-stored (content://) take usable wherever a File is needed; default = files only. */
    private val materializer: com.levi.pocketdj.studio.store.StudioMaterializer? = null,
    private val now: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    /** Render + file [result]. Throws [TakeFileException]. */
    suspend fun file(result: TakeResult, name: String, bank: File?): StudioTake {
        if (result.events.isEmpty()) throw TakeFileException(TakeFileFailure.NoNotes)
        if (bank == null) throw TakeFileException(TakeFileFailure.PackMissing(result.instrument))
        try {
            renderer.renderRaw(result.takeId, result.events, result.instrument, bank, result.fileName)
        } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Throwable) {   // incl. LinkageError (native lib missing)
            StudioFiles.appFile(roots, StudioFamily.TAKES, result.fileName)?.delete()
            throw TakeFileException(TakeFileFailure.Failed)
        }
        val filed = store.addTakeRelocating(
            StudioTake(
                id = result.takeId, name = name, instrument = result.instrument, fileName = result.fileName,
                wasUserFolder = false, bpm = result.bpm, events = result.events, durationMs = result.durationMs, createdAt = now(),
            ),
        )
        // Overdub staffs ride with the take (same path as ScoreScreen's overdub); adding one marks the render stale, so the
        // next play re-renders the whole multi-staff score.
        for (s in result.extraStaffs) store.addOverdubStaff(filed.id, s.instrument, s.events)
        return if (result.extraStaffs.isEmpty()) filed else store.take(filed.id) ?: filed
    }

    /** The take's CURRENT audio file: the fresh render cache, else the raw file when never edited/retimed, else null (needs a render). */
    fun currentAudioFile(take: StudioTake): File? {
        if (take.isRenderFresh) {
            StudioFolders.fileRef(roots, StudioFamily.TAKES, take.renderedFileName!!, take.renderedWasUserFolder ?: false)?.file?.takeIf { it.isFile }?.let { return it }
        }
        if (take.editedEvents == null && take.renderRevision == 0) {
            return StudioFolders.fileRef(roots, StudioFamily.TAKES, take.fileName, take.wasUserFolder)?.file?.takeIf { it.isFile }
        }
        return null
    }

    /** Like [currentAudioFile] but also resolves a SAF (file-less) ref. */
    fun currentAudioRef(take: StudioTake): com.levi.pocketdj.studio.store.StudioFileRef? {
        if (take.isRenderFresh) {
            StudioFolders.fileRef(roots, StudioFamily.TAKES, take.renderedFileName!!, take.renderedWasUserFolder ?: false)?.let { return it }
        }
        if (take.editedEvents == null && take.renderRevision == 0) {
            return StudioFolders.fileRef(roots, StudioFamily.TAKES, take.fileName, take.wasUserFolder)
        }
        return null
    }

    /** Lease of the take's CURRENT audio (direct file or SAF copy); null when it needs a render. Caller releases. */
    suspend fun leaseCurrentAudio(take: StudioTake): com.levi.pocketdj.studio.store.StudioLease? {
        val ref = currentAudioRef(take) ?: return null
        return (materializer ?: com.levi.pocketdj.studio.store.StudioMaterializer.FILES_ONLY).lease(ref)
    }

    /** Make sure [take] has playable audio matching its score, rendering when stale. */
    suspend fun ensureAudio(take: StudioTake, bankFor: (InstrumentKey) -> File?): File? {
        currentAudioFile(take)?.let { return it }
        return renderer.render(take, bankFor)
    }

    /** COPY the take's audio into a new sample (grid = the take's tempo, source = the take). */
    suspend fun useAsSample(take: StudioTake, bankFor: (InstrumentKey) -> File?): com.levi.pocketdj.studio.model.StudioSample {
        val lease = leaseCurrentAudio(take)
        try {
            return useAsSampleFrom(take, lease?.file, bankFor)
        } finally { lease?.release() }
    }

    private suspend fun useAsSampleFrom(take: StudioTake, leased: File?, bankFor: (InstrumentKey) -> File?): com.levi.pocketdj.studio.model.StudioSample {
        val src = leased ?: try { ensureAudio(take, bankFor) } catch (e: TakeRenderException.BankMissing) {
            throw TakeFileException(TakeFileFailure.PackMissing(e.instrument))
        } catch (e: TakeRenderException.EmptyTake) { throw TakeFileException(TakeFileFailure.NoNotes) }
            ?: throw TakeFileException(TakeFileFailure.Failed)
        val id = com.levi.pocketdj.studio.model.StudioFactory.newSampleId()
        val name = StudioFolders.fileName(StudioFamily.SAMPLES, id)
        val dest = StudioFiles.appFile(roots, StudioFamily.SAMPLES, name) ?: throw TakeFileException(TakeFileFailure.Failed)
        val res = try { studioRender.importAudioFile(src.path, dest) } catch (e: com.levi.pocketdj.studio.audio.StudioRenderException) {
            dest.delete(); throw TakeFileException(TakeFileFailure.Failed)
        }
        return store.addSampleRelocating(
            com.levi.pocketdj.studio.model.StudioSample(
                id, take.name, name, wasUserFolder = false, createdAt = now(), durationMs = res.durationMs,
                source = com.levi.pocketdj.studio.model.StudioSource.Take(take.id),
                grid = com.levi.pocketdj.studio.model.StudioGrid(take.bpm),
            ),
        )
    }
}
