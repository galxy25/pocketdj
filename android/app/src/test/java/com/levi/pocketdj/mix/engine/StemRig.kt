package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.mix.model.Deck
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers

/** A growing four-part stem stream backed by synthetic sources. */
class FakeStemStream(override val songId: String, val srcs: List<SyntheticPcmSource>, val sr: Int) : StemStream {
    var isFailed = false
    var cancelled = 0
    override val failed: Boolean get() = isFailed
    override val complete: Boolean get() = srcs.all { it.isComplete }
    override fun parts(): List<PcmSource>? = if (srcs.all { it.availableFrames > 0 }) srcs else null
    override fun cancel() { cancelled++ }
    fun growTo(sec: Double) { srcs.forEach { it.available = (sec * sr).toLong() } }
}

class FakeStems(val sr: Int) : StemProvider {
    val local = HashMap<String, () -> StemParts>()
    val streams = HashMap<String, FakeStemStream>()
    var fetchGate: CompletableDeferred<Boolean>? = null
    var fetchCalls = 0
    var streamOpens = 0
    override fun local(songId: String): StemParts? = local[songId]?.invoke()
    override fun canStream(songId: String) = songId in streams
    override fun openStream(songId: String, owner: String): StemStream? = streams[songId]?.also { streamOpens++ }
    override suspend fun fetchWhole(songId: String): Boolean {
        fetchCalls++
        return fetchGate!!.await()
    }
}

class FakeMain(var end: Double, var complete: Boolean = false, var truncated: Boolean = true, var canGrow: Boolean = false) : MainVoiceStatus {
    override fun endSeconds(deck: Deck) = end
    override fun complete(deck: Deck) = complete
    override fun truncated(deck: Deck) = truncated
    override fun canGrow(deck: Deck) = canGrow
}

/** An engine + stem/loop/beat-grid controllers on an offline sink; rendering interleaved with 100 ms ticks. */
class StemRig(val seconds: Double = 10.0) {
    val h = EngineHarness()
    val fake = FakeStems(h.sr)
    val extras = MixDeckExtras(
        engine = h.engine, provider = fake,
        runner = { v -> h.voices += v; AutoCloseable { h.voices -= v } },
        scope = CoroutineScope(Dispatchers.Unconfined),
        localGrid = { null }, downloadGrid = { null },
    )
    val stems get() = extras.stems
    val loops get() = extras.loops
    val engine get() = h.engine
    val A = Deck.A

    fun load(id: String = "s", deck: Deck = A, secs: Double = seconds) {
        engine.load(h.addSong(id, secs), deck)
    }

    private fun tone(total: Long, amp: Float = 0.125f) = SyntheticPcmSource.tone(220.0, total, h.sr, amp)

    /** Four stems that sum to the 0.5-amp 220 Hz full mix, burned (complete) for [id]. */
    fun burn(id: String = "s", secs: Double = seconds) {
        fake.local[id] = { StemParts(List(4) { tone((secs * h.sr).toLong()) }, complete = true) }
    }

    /** A growing stream for [id] with [availableSec] present of [secs]. */
    fun stream(id: String = "s", secs: Double = seconds, availableSec: Double): FakeStemStream {
        val total = (secs * h.sr).toLong()
        val srcs = List(4) {
            SyntheticPcmSource(h.sr, 2, total, (availableSec * h.sr).toLong()) { f, _ ->
                (0.125 * Math.sin(2 * Math.PI * 220.0 * f / h.sr)).toFloat()
            }
        }
        return FakeStemStream(id, srcs, h.sr).also { fake.streams[id] = it }
    }

    /** Render [sec] seconds in 100 ms steps, ticking the engine between blocks. */
    fun run(sec: Double): FloatArray {
        val steps = Math.round(sec * 10).toInt()
        val out = FloatArray(steps * 4410 * 2)
        for (i in 0 until steps) {
            val b = h.render(4410)
            System.arraycopy(b, 0, out, i * 4410 * 2, b.size)
            h.tick(100)
        }
        return out
    }
}
