package com.levi.pocketdj.mix.service

import com.levi.pocketdj.mix.model.Deck

/** What recovery needs from the engine (main thread). Implemented over [com.levi.pocketdj.mix.engine.MixEngine]. */
interface RecoveryPort {
    fun nowMs(): Long
    /** The mix wants audio (a deck has play intent or Auto-DJ is between decks). */
    val mixWantsAudio: Boolean
    val isRendering: Boolean
    /** An open recording tap keeps the sink alive: never pause a "silent" deck under it. */
    val recording: Boolean
    fun deckPlaying(deck: Deck): Boolean
    /** The deck is waiting for stream bytes: silence is expected. */
    fun deckHeld(deck: Deck): Boolean
    /** The deck loops (a loop's silence-free by construction; iOS skips it). */
    fun deckLooping(deck: Deck): Boolean
    /** The deck's channel volume (0 = deliberately silent). */
    fun deckGain(deck: Deck): Double
    /** The crossfader's factor for the deck (0 = that side is closed). */
    fun crossfadeFactor(deck: Deck): Double
    /** Every stem of a stems-mode deck is muted (silence is the user's choice). */
    fun allStemsMuted(deck: Deck): Boolean
    /** Seconds since the render thread last produced an AUDIBLE block (the tap signal); -1 = never. */
    fun signalAgeSeconds(): Double
    /** Seconds left on the deck (silence at the very end is the natural finish, not a fault). */
    fun remainingSeconds(deck: Deck): Double
    /** Park the Auto-DJ wall clocks (sink down). Idempotent. */
    fun parkClocks()
    /** Shift every armed clock past the stall (sink back). */
    fun unparkClocks()
    /** Start the sink if it is not pulling blocks. True when it renders. */
    fun restartSink(): Boolean
    /** Re-kick a deck's voice at its frozen frame (the voice kept its position; this only restarts the pull). */
    fun reprime(deck: Deck)
    /** Pause one suspect deck. */
    fun pauseDeck(deck: Deck)
}

/**
 * Routing / device-change recovery plus the silent-playing detector (iOS recoverFromEngineStop,
 * unparkEngineStall, silentPlayingCheck). [com.levi.pocketdj.audio.core.AudioTrackSink] (emulator) and
 * [com.levi.pocketdj.audio.core.OboeSink] (device; both via StudioOutputs) already
 * recreate the stream between blocks and retries with backoff; it reports each outcome via
 * `onRoutingChanged`, which feeds [onSinkRouting]. The voices are decoder-driven and keep their
 * frame, so "resume at the frozen frame" is a re-kick of the pull, not a seek.
 */
class MixRecovery(
    private val port: RecoveryPort,
    private val log: (String) -> Unit = { MixDiag.log(it) },
) {
    /** When the sink went down, or null while it renders. */
    var downAtMs: Long? = null; private set
    private val strikes = IntArray(Deck.entries.size)
    private var runningSinceMs = -1L
    var silentPlayingEvents = 0; private set

    /** The sink finished a route rebuild ([rendering] = it works) or lost its track. */
    fun onSinkRouting(rendering: Boolean) {
        if (!rendering) {
            if (downAtMs == null && port.mixWantsAudio) {
                downAtMs = port.nowMs()
                port.parkClocks()
                log("recover: sink down - clocks parked")
            }
            return
        }
        val stalled = downAtMs?.let { port.nowMs() - it } ?: 0L
        val wasDown = downAtMs != null
        downAtMs = null
        if (wasDown) port.unparkClocks()
        val ok = port.restartSink()   // no-op when the sink already renders
        log("recover: sink restarted stall=${stalled}ms ok=$ok")
        reprimeAll()
    }

    private fun reprimeAll() {
        for (d in Deck.entries) if (port.deckPlaying(d) && !port.deckHeld(d)) port.reprime(d)
    }

    /**
     * 1 Hz (iOS silentPlayingCheck). A deck that is playing, not stream-held, not looping, audible by
     * gain + crossfader + stems, with audio left, while the mix has run > 3 s and the render tap has
     * seen no audible block for > 3 s (or never), is SILENT-PLAYING. Strike 1-2 re-kick it (only a
     * voice that is IDLE/UNDERRUN is touched); strike 3 logs it and pauses it unless a recording tap is
     * open. Anything else resets the deck's strikes. The decks share one tap, so a signal from either
     * deck clears every suspect (as on iOS).
     */
    fun silentPlayingCheck() {
        val now = port.nowMs()
        val anyPlaying = Deck.entries.any { port.deckPlaying(it) }
        if (!anyPlaying) runningSinceMs = -1L else if (runningSinceMs < 0) runningSinceMs = now
        val runningLong = runningSinceMs >= 0 && now - runningSinceMs > SILENCE_S * 1000
        val age = port.signalAgeSeconds()
        val silent = age < 0 || age > SILENCE_S
        for (d in Deck.entries) {
            val suspect = runningLong && silent && port.isRendering && port.deckPlaying(d) &&
                !port.deckHeld(d) && !port.deckLooping(d) &&
                port.deckGain(d) > GAIN_FLOOR && port.crossfadeFactor(d) > GAIN_FLOOR &&
                !port.allStemsMuted(d) && port.remainingSeconds(d) > END_GRACE_S
            if (!suspect) { strikes[d.ordinal] = 0; continue }
            val n = ++strikes[d.ordinal]
            if (n < STRIKES) {
                log("recover: deck ${d.label} silent strike=$n sigAge=$age - re-kick")
                port.reprime(d)
            } else {
                silentPlayingEvents++
                strikes[d.ordinal] = 0
                if (port.recording) {
                    log("SILENT-PLAYING deck ${d.label} (recording - left running)")
                } else {
                    log("SILENT-PLAYING deck ${d.label} - paused")
                    port.pauseDeck(d)
                }
            }
        }
    }

    fun strikeCount(deck: Deck) = strikes[deck.ordinal]

    companion object {
        const val STRIKES = 3
        const val END_GRACE_S = 1.0
        const val SILENCE_S = 3.0
        const val GAIN_FLOOR = 0.01
    }
}

/** [RecoveryPort] over the real engine + Auto-DJ. */
class EngineRecoveryPort(
    private val engine: com.levi.pocketdj.mix.engine.MixEngine,
    private val dj: com.levi.pocketdj.mix.engine.AutoDj,
) : RecoveryPort {
    override fun nowMs() = engine.nowMs()
    override val mixWantsAudio get() = engine.mixWantsAudio
    override val isRendering get() = engine.isRendering
    override val recording get() = engine.keepEngineAlive()
    override fun deckPlaying(deck: Deck) = engine.isPlaying(deck)
    override fun deckHeld(deck: Deck) = engine.streamHeld(deck)
    override fun deckLooping(deck: Deck) = engine.deckState(deck).loopOn || engine.loopWindow(deck) != null
    override fun deckGain(deck: Deck) = engine.volume(deck)
    override fun crossfadeFactor(deck: Deck) =
        com.levi.pocketdj.mix.model.MixMath.crossfadeFactor(deck, engine.crossfader.toFloat()).toDouble()
    override fun allStemsMuted(deck: Deck): Boolean {
        val st = engine.deckState(deck)
        return st.stemMode && com.levi.pocketdj.data.burns.BurnFileNames.STEM_NAMES.all { it in st.stemMuted }
    }
    override fun signalAgeSeconds() = engine.tapAgeSeconds(true)
    override fun remainingSeconds(deck: Deck) = engine.duration(deck) - engine.position(deck)
    override fun parkClocks() = dj.parkEngineStall()
    override fun unparkClocks() = dj.unparkEngineStall()
    override fun restartSink() = engine.startEngineIfNeeded()
    override fun reprime(deck: Deck) {
        if (engine.streamHeld(deck)) return
        val c = engine.controller(deck)
        // Only a voice that stopped pulling needs the kick; play() on a live (or beat-scheduled) voice
        // would reset its startAt to IMMEDIATE.
        val status = if (c.onStems) c.stems?.voices?.get(0)?.status else c.voiceStatus
        if (status == null || status == com.levi.pocketdj.audio.core.Voice.Status.IDLE ||
            status == com.levi.pocketdj.audio.core.Voice.Status.UNDERRUN) c.play()
    }
    override fun pauseDeck(deck: Deck) = engine.silence(deck)
}
