package com.levi.pocketdj.mix.model

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

data class LoopWindow(val start: Double, val end: Double)
data class GlideParams(val outRate: Double, val outPitch: Double, val inRate: Double, val inPitch: Double)
data class GlideTexture(val effect: Effect, val peak: Double, val run: Int)

/** Deterministic splitmix64 PRNG state holder (unsigned 64-bit semantics via ULong). */
class SplitMix64(var state: ULong)

/** Port of the pure, nonisolated statics of iOS MixEngine / StemSync / CollectionMixDownloader. */
object MixMath {
    /** Torn-frame margin (s) for a growing file. */
    const val STREAM_FRONTIER_MARGIN = 1.5
    /** Runway (s) a still-arriving source needs before a stem handover. */
    const val HANDOVER_RUNWAY = 4.0
    /** 256 kbps mp3 = 32 KB of file per second of playback. */
    const val BYTES_PER_PLAYBACK_SECOND = 32_768.0
    /** 1 Camelot key as semitones at the 10%-per-key convention: 12*log2(1.1). */
    val SEMITONES_PER_KEY: Double = 12 * (ln(1.1) / ln(2.0))
    /** Sweepy effects used by FX-Glide (compressor excluded). */
    val FX_GLIDE_POOL: List<Effect> = listOf(Effect.FILTER, Effect.REVERB, Effect.FLANGER)

    // Crossfader

    /** Equal-power crossfade factor 0..1 for a deck at crossfader position [crossfader] (0=A, 1=B). */
    fun crossfadeFactor(deck: Deck, crossfader: Float): Float {
        val v = crossfader
        return if (deck == Deck.A) cos((PI / 2 * v).toFloat()) else cos((PI / 2 * (1 - v)).toFloat())
    }

    // Tempo

    /** Octave-fold a tempo ratio into 0.5..2.0 then clamp; non-finite / non-positive folds to 1.0. */
    fun octaveFolded(ratio: Double): Double {
        if (!ratio.isFinite() || ratio <= 0) return 1.0
        var r = ratio
        while (r > MixRanges.rate.endInclusive) r /= 2
        while (r < MixRanges.rate.start) r *= 2
        return r.coerceIn(MixRanges.rate.start, MixRanges.rate.endInclusive)
    }

    /** Follower tempo multiplier that matches the lead's effective BPM (octave-folded). */
    fun syncRate(leadBPM: Double, leadRate: Double, followerBPM: Double): Double {
        if (!(followerBPM > 0)) return 1.0
        return octaveFolded(leadBPM * leadRate / followerBPM)
    }

    // Loops

    /** Snap [anchorSec] back to the previous unit boundary off [phaseSec], run [units] forward. */
    fun loopWindowMath(anchorSec: Double, phaseSec: Double, unitSeconds: Double, units: Double, durationSec: Double): LoopWindow? {
        if (!(unitSeconds > 0) || !(units > 0) || !(durationSec > 0)) return null
        val anchor = anchorSec.coerceIn(0.0, durationSec)
        val rel = anchor - phaseSec
        val start = if (rel >= 0) phaseSec + floor(rel / unitSeconds) * unitSeconds else phaseSec
        return clampLoopWindow(start, start + units * unitSeconds, durationSec)
    }

    /** Fit a window in the deck: floor 50 ms, slide back (never shrink) on overrun. */
    fun clampLoopWindow(start: Double, end: Double, durationSec: Double): LoopWindow? {
        if (!(durationSec > 0)) return null
        var s = start
        val len = min(max(end - s, 0.05), durationSec)
        var e = s + len
        if (e > durationSec) { e = durationSec; s = max(0.0, e - len) }
        if (s < 0) { s = 0.0; e = min(durationSec, len) }
        if (!(e > s)) return null
        return LoopWindow(s, e)
    }

    // Glide

    /** Tempo multiplier for a glide of [keys] Camelot hours (1 key = +/-10%), clamped to the rate range. */
    fun glideRate(keys: Double): Double =
        (1 + 0.10 * keys).coerceIn(MixRanges.rate.start, MixRanges.rate.endInclusive)

    /** Pitch shift (semitones) for a glide of [keys], clamped to the pitch range. */
    fun glidePitch(keys: Double): Double =
        (keys * SEMITONES_PER_KEY).coerceIn(MixRanges.pitch.start, MixRanges.pitch.endInclusive)

    fun signedCamelotSteps(a: String?, b: String?): Int? = Camelot.signedSteps(a, b)

    /**
     * Per-deck tempo/pitch targets for a transition A(out) to B(in). Pitch only when both keys are
     * known and differ (<=1 key each); tempo only when both BPMs known (split octave-folded match).
     * Missing datum: identity.
     */
    fun glideParams(fromCamelot: String?, toCamelot: String?, fromBPM: Double?, toBPM: Double?): GlideParams {
        var outPitch = 0.0
        var inPitch = 0.0
        var outRate = 1.0
        var inRate = 1.0
        val d = signedCamelotSteps(fromCamelot, toCamelot)
        if (d != null && abs(d) >= 1) {
            val mag = min(1.0, abs(d).toDouble() / 2.0)
            val dir = if (d > 0) 1.0 else -1.0
            outPitch = glidePitch(dir * mag)
            inPitch = glidePitch(-dir * mag)
        }
        if (fromBPM != null && toBPM != null && fromBPM > 0 && toBPM > 0) {
            val split = sqrt(octaveFolded(fromBPM / toBPM))
            inRate = split.coerceIn(MixRanges.rate.start, MixRanges.rate.endInclusive)
            outRate = (1 / split).coerceIn(MixRanges.rate.start, MixRanges.rate.endInclusive)
        }
        return GlideParams(outRate, outPitch, inRate, inPitch)
    }

    // PRNG

    /** splitmix64 step; mutates [rng]. */
    fun splitmix64(rng: SplitMix64): ULong {
        rng.state += 0x9E37_79B9_7F4A_7C15uL
        var z = rng.state
        z = (z xor (z shr 30)) * 0xBF58_476D_1CE4_E5B9uL
        z = (z xor (z shr 27)) * 0x94D0_49BB_1331_11EBuL
        return z xor (z shr 31)
    }

    /** Next FX-Glide texture: pool effect, peak 0.5..0.8, run 3..5. Deterministic given state. */
    fun rollTexture(rng: SplitMix64): GlideTexture {
        val a = splitmix64(rng)
        val b = splitmix64(rng)
        val c = splitmix64(rng)
        val effect = FX_GLIDE_POOL[(a % FX_GLIDE_POOL.size.toULong()).toInt()]
        val peak = 0.5 + (b % 1000uL).toDouble() / 1000.0 * 0.3
        val run = 3 + (c % 3uL).toInt()
        return GlideTexture(effect, peak, run)
    }

    /** FNV-1a over the first song id (or "seed") xor the item count. */
    fun fxSeed(items: List<AutoMixItem>): ULong {
        var h = 0xcbf2_9ce4_8422_2325uL
        for (byte in (items.firstOrNull()?.loadable?.songId ?: "seed").toByteArray(Charsets.UTF_8)) {
            h = (h xor (byte.toInt() and 0xFF).toULong()) * 0x0000_0100_0000_01B3uL
        }
        return h xor items.size.toULong()
    }

    // Streaming

    /**
     * Bytes of file per second of audio for a growing LAME mp3; null when the header can't cover
     * [expectedBytes] at the max mp3 bitrate (headerless: don't play until complete).
     */
    fun streamBytesPerSecond(totalFrames: Long, sampleRate: Double, expectedBytes: Long?): Double? {
        if (!(sampleRate > 0) || totalFrames <= 0) return null
        val seconds = totalFrames.toDouble() / sampleRate
        if (expectedBytes == null || expectedBytes <= 0) return BYTES_PER_PLAYBACK_SECOND
        if (seconds < expectedBytes.toDouble() / 41_000.0) return null
        return expectedBytes.toDouble() / seconds
    }

    /** Last FILE frame safe to schedule given [bytes] downloaded; null rate means startFrame. */
    fun streamPlayableFrames(bytes: Long, bytesPerSecond: Double?, sampleRate: Double, startFrame: Long): Long {
        val bps = bytesPerSecond
        if (bps == null || !(bps > 0)) return startFrame
        val seconds = bytes.toDouble() / bps - STREAM_FRONTIER_MARGIN
        return max(startFrame, (max(0.0, seconds) * sampleRate).toLong())
    }

    /** Does a source with [runway] seconds past the playhead qualify for a stem handover? */
    fun handoverReady(runway: Double, complete: Boolean, songLeft: Double): Boolean {
        if (!(runway > 0.05)) return false
        if (complete) return true
        return runway >= min(HANDOVER_RUNWAY, max(0.05, songLeft - 0.05))
    }

    /** Seconds of stem audio a fresh open of a part can play from 0:00. */
    fun playableSeconds(
        lengthSeconds: Double, bytes: Long, expectedBytes: Long?, songSeconds: Double, complete: Boolean,
        fallbackBytesPerSecond: Double = BYTES_PER_PLAYBACK_SECOND,
    ): Double {
        if (complete) return max(0.0, lengthSeconds)
        var bps = fallbackBytesPerSecond
        if (expectedBytes != null && expectedBytes > 0 && songSeconds > 0) bps = expectedBytes.toDouble() / songSeconds
        val byBytes = if (bps > 0) bytes.toDouble() / bps else 0.0
        return max(0.0, min(lengthSeconds, byBytes) - STREAM_FRONTIER_MARGIN)
    }

    // Download throughput / ETA

    /** Remaining playback-seconds to ETA seconds at the observed throughput; null without a sample. */
    fun etaSeconds(remainingPlaybackSeconds: Double, bytesPerSecond: Double?): Double? {
        val bps = bytesPerSecond ?: return null
        return remainingPlaybackSeconds * BYTES_PER_PLAYBACK_SECOND / max(bps, 1.0)
    }

    /** "3m 20s" / "45s", or an em dash while there is no sample. */
    fun etaLabel(seconds: Double?): String {
        if (seconds == null || !seconds.isFinite() || seconds < 0) return "—"
        val t = roundAway(seconds).toInt()
        return if (t >= 60) "${t / 60}m ${t % 60}s" else "${t}s"
    }
}

/**
 * 30-second rolling window of observed download throughput (pure; scripted clock in tests).
 * NOT thread-safe: single-thread confined; the owning downloader must serialize access.
 */
class ThroughputWindow {
    private data class Sample(val t: Double, val bytes: Long)
    private val samples = ArrayList<Sample>()

    val sampleCount: Int get() = samples.size

    fun add(bytes: Long, at: Double) {
        samples.add(Sample(at, bytes))
        prune(at)
    }

    private fun prune(t: Double) {
        samples.removeAll { it.t < t - SPAN }
    }

    /** Sum of window bytes / elapsed span (capped at 30 s, floored at 1 s); null until a sample lands. */
    fun bytesPerSecond(at: Double): Double? {
        prune(at)
        val oldest = samples.firstOrNull()?.t ?: return null
        val span = max(min(at - oldest, SPAN), 1.0)
        return samples.sumOf { it.bytes }.toDouble() / span
    }

    companion object { const val SPAN = 30.0 }
}
