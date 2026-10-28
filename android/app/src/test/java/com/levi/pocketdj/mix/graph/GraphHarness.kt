package com.levi.pocketdj.mix.graph

import com.levi.pocketdj.audio.core.OfflineRenderer
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.audio.core.VoiceGroup
import com.levi.pocketdj.mix.model.Deck
import kotlin.math.abs
import kotlin.math.sqrt

/** Deterministic harness: a MixGraph on an OfflineRenderer, with decoder pumping interleaved per block. */
class GraphHarness(val block: Int = 512) {
    val sr = 44_100
    val graph = MixGraph(sr, 2048)
    val sink = OfflineRenderer(sr, block)
    val composer = ParamsComposer(graph)
    val voices = mutableListOf<Voice>()

    init { graph.attach(sink) }

    /** Looping tone voice (integer cycles per loop so the seam is continuous). */
    fun toneVoice(freq: Double, amp: Float = 0.5f, seconds: Int = 10): Voice {
        val total = sr.toLong() * seconds
        val v = Voice(SyntheticPcmSource.tone(freq, total, sr, amp), sr)
        v.setLoop(0, total)
        voices += v
        return v
    }

    fun stemGroup(freq: Double, amp: Float = 0.5f, seconds: Int = 10): VoiceGroup =
        VoiceGroup(List(4) { toneVoice(freq, amp / 4f, seconds) })

    fun pumpAll() {
        var guard = 0
        do {
            var any = false
            for (v in voices) while (v.pump()) any = true
            guard++
        } while (any && guard < 100)
    }

    /** Render [frames] frames block by block, pumping the decoders between blocks. */
    fun render(frames: Int): FloatArray {
        val out = FloatArray(frames * 2)
        var done = 0
        while (done < frames) {
            pumpAll()
            val n = minOf(block, frames - done)
            val b = sink.renderFrames(n)
            System.arraycopy(b, 0, out, done * 2, n * 2)
            done += n
        }
        return out
    }

    /** Start [v] as the deck's full mix and run until it is audible. */
    fun playMain(d: Deck, v: Voice, warm: Int = 4096) {
        graph.setMain(d, v)
        v.schedule(0)
        v.play()
        render(warm)
    }

    companion object {
        fun peak(buf: FloatArray, fromFrame: Int = 0, toFrame: Int = buf.size / 2, ch: Int = -1): Float {
            var p = 0f
            for (f in fromFrame until toFrame) {
                if (ch != 1) p = maxOf(p, abs(buf[f * 2]))
                if (ch != 0) p = maxOf(p, abs(buf[f * 2 + 1]))
            }
            return p
        }

        fun rms(buf: FloatArray, fromFrame: Int, toFrame: Int, ch: Int): Double {
            var s = 0.0
            for (f in fromFrame until toFrame) { val x = buf[f * 2 + ch].toDouble(); s += x * x }
            return sqrt(s / (toFrame - fromFrame))
        }

        /** Longest run (frames) of near-silence on both channels within [from, to). */
        fun longestSilence(buf: FloatArray, from: Int, to: Int, eps: Float = 1e-3f): Int {
            var best = 0; var run = 0
            for (f in from until to) {
                if (abs(buf[f * 2]) < eps && abs(buf[f * 2 + 1]) < eps) { run++; if (run > best) best = run } else run = 0
            }
            return best
        }

        /** Largest sample-to-sample step on channel 0 within [from, to). */
        fun maxStep(buf: FloatArray, from: Int, to: Int): Float {
            var m = 0f
            for (f in from + 1 until to) m = maxOf(m, abs(buf[f * 2] - buf[(f - 1) * 2]))
            return m
        }
    }
}
