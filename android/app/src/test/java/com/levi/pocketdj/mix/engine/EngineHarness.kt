package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.OfflineRenderer
import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.mix.graph.MixGraph
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.store.MixDeckSessionStore
import com.levi.pocketdj.mix.store.MixEventKind
import com.levi.pocketdj.mix.store.MixSessionRecorder
import java.io.File

/** Records every event the engine emits. */
class FakeRecorder : MixSessionRecorder {
    data class Ev(val kind: MixEventKind, val deck: String?, val songId: String?, val bpm: Double?, val camelot: String?,
                  val param: String?, val value: Double?, val flag: Boolean?, val posMs: Int?, val slot: Int?)
    val events = mutableListOf<Ev>()
    val played = mutableListOf<String>()
    override fun logEvent(kind: MixEventKind, deck: String?, songId: String?, title: String?, artist: String?,
                          bpm: Double?, camelot: String?, param: String?, value: Double?, flag: Boolean?, posMs: Int?, slot: Int?) {
        events += Ev(kind, deck, songId, bpm, camelot, param, value, flag, posMs, slot)
    }
    override fun logGlide(deck: String?, param: String, songId: String?, title: String?, artist: String?,
                          from: Double, to: Double, rate: Double, posMs: Int?, slot: Int?) {}
    override fun notePlayed(songId: String) { played += songId }
    override fun hasPlayed(songId: String) = songId in played
    fun of(kind: MixEventKind) = events.filter { it.kind == kind }
    fun kinds() = events.map { it.kind.raw }
}

class ManualTickDriver : TickDriver {
    var block: (() -> Boolean)? = null
    var starts = 0
    override fun start(intervalMs: Long, block: () -> Boolean): AutoCloseable {
        this.block = block; starts++
        return AutoCloseable { this.block = null }
    }
    val running: Boolean get() = block != null
}

class FakeAutoDj : AutoDjHooks {
    override var isMixing = false
    override var isPaused = false
    var ended = 0
    var seeks = mutableListOf<Deck>()
    override fun endAutoLoop() { ended++; isMixing = false }
    override fun onSeek(deck: Deck) { seeks += deck }
}

/** A MixEngine on an OfflineRenderer sink with synthetic songs and manual clock / tick / decoder pumping. */
class EngineHarness(store: MixDeckSessionStore? = null, val block: Int = 512) {
    val sr = 44_100
    val renderer = OfflineRenderer(sr, block)
    var nowMs = 1_800_000_000_000L
    var nano = 1L
    val driver = ManualTickDriver()
    val voices = mutableListOf<Voice>()
    val diags = mutableListOf<String>()
    private val songs = HashMap<String, ResolvedTrack>()
    private val sources = HashMap<String, () -> PcmSource>()
    val recorder = FakeRecorder()
    val engine: MixEngine = MixEngine(
        graph = MixGraph(sr, 2048),
        sinkFactory = { renderer },
        resolver = { id -> songs[id] },
        opener = { f -> sources[f.name]?.invoke() },
        runner = { v -> voices += v; AutoCloseable { voices -= v } },
        tickDriver = driver,
        clockMs = { nowMs },
        nanoClock = { nano },
        deckStore = store,
        diagSink = { diags += it },
    ).also { it.recorder = recorder }

    /** Register a song whose file decodes to [seconds] of a tone (or [source] if given). */
    fun addSong(
        id: String, seconds: Double = 10.0, isCut: Boolean = true, startMs: Int? = null,
        gridBpm: Double? = null, firstDownbeatMs: Int? = null, source: (() -> PcmSource)? = null,
    ): MixLoadable {
        val f = File("/fake/$id.mp3")
        songs[id] = ResolvedTrack(f, isCut, startMs, gridBpm, firstDownbeatMs)
        sources[f.name] = source ?: { SyntheticPcmSource.tone(220.0, (seconds * sr).toLong(), sr) }
        return MixLoadable(id, "Title $id", "Artist", bpm = gridBpm, camelot = "8A")
    }

    fun removeSong(id: String) { songs.remove(id) }

    fun pumpAll() {
        var guard = 0
        do {
            var any = false
            for (v in voices.toList()) while (v.pump()) any = true
            guard++
        } while (any && guard < 100)
    }

    /** Render [frames] frames block by block (pumping decoders), returning the interleaved output. */
    fun render(frames: Int): FloatArray {
        val out = FloatArray(frames * 2)
        var done = 0
        while (done < frames) {
            pumpAll()
            val n = minOf(block, frames - done)
            val b = renderer.renderFrames(n)
            System.arraycopy(b, 0, out, done * 2, n * 2)
            done += n
        }
        return out
    }

    /** Advance the wall clock and run one engine tick. */
    fun tick(advanceMs: Long = 100): Boolean {
        nowMs += advanceMs
        return driver.block?.invoke() ?: false
    }

    fun seconds(s: Double) = (s * sr).toInt()
}
