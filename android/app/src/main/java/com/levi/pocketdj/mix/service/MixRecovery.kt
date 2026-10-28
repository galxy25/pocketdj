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
    /** The deck's voice is really producing frames (decoder-side truth). */
    fun voicePlaying(deck: Deck): Boolean
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
 * unparkEngineStall, silentPlayingCheck). [com.levi.pocketdj.audio.core.AudioTrackSink] already
 * recreates the AudioTrack between blocks and retries with backoff; it reports each outcome via
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
     * 1 Hz. A deck that has play intent, is not held, has audio left and a rendering sink but whose
     * voice is not producing is SILENT-PLAYING. Strike 1-2 re-kick it; strike 3 logs it and pauses
     * it unless a recording tap is open. Healthy / paused / held decks reset their strikes.
     */
    fun silentPlayingCheck() {
        for (d in Deck.entries) {
            val suspect = port.isRendering && port.deckPlaying(d) && !port.deckHeld(d) &&
                port.remainingSeconds(d) > END_GRACE_S && !port.voicePlaying(d)
            if (!suspect) { strikes[d.ordinal] = 0; continue }
            val n = ++strikes[d.ordinal]
            if (n < STRIKES) {
                log("recover: deck ${d.label} voice idle strike=$n - re-kick")
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
    override fun voicePlaying(deck: Deck) = engine.controller(deck).isVoicePlaying
    override fun remainingSeconds(deck: Deck) = engine.duration(deck) - engine.position(deck)
    override fun parkClocks() = dj.parkEngineStall()
    override fun unparkClocks() = dj.unparkEngineStall()
    override fun restartSink() = engine.startEngineIfNeeded()
    override fun reprime(deck: Deck) { if (!engine.streamHeld(deck)) engine.controller(deck).play() }
    override fun pauseDeck(deck: Deck) = engine.silence(deck)
}
