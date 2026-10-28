package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.graph.SlotParams
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.MixMath
import com.levi.pocketdj.mix.model.MixRanges
import com.levi.pocketdj.mix.model.SplitMix64

/** Per-transition glide parameters, snapshotted when a glide transition begins. */
internal class GlideContext(
    val from: Deck, val to: Deck,
    val fxOn: Boolean,
    /** The rolled texture, kept for the timeline `param`, not for addressing a node. */
    val fxEffect: Effect,
    /** The rack SLOT swept on each deck (resolved per deck; null = nothing sweepable there). */
    val fxSlotFrom: Int?, val fxSlotTo: Int?,
    val fxPeak: Double,
    val savedFromOn: Boolean, val savedFromStrength: Double,
    val savedToOn: Boolean, val savedToStrength: Double,
    val mixOn: Boolean,
    val outRate: Double, val outPitch: Double,
    val inRate: Double, val inPitch: Double,
)

/**
 * The FX Glide + Mix Glide transition phases (iOS "Auto-Mix glide"). A transition layers optional
 * PRE-ROLL (ramp glide in on the outgoing deck, before the volume sweep) and POST-ROLL (ramp glide
 * back off on the incoming deck, after the sweep) around the crossfade. With neither feature on,
 * no phase is ever entered and behaviour is the plain crossfade.
 *
 * Glide setters mutate deck state + push to the graph WITHOUT recording a per-tick event: the
 * trajectory is captured compactly as one `.glide` event per ramp ([recGlide]). Auto sweeps never
 * record `.crossfader` either (they ride the engine's non-recording `applyCrossfader`).
 */
class GlideMachine internal constructor(private val dj: AutoDj) {
    private val e get() = dj.engine

    /** FX GLIDE: sweep a coherent effect in/out around each transition. Read per transition. */
    var fxGlideEnabled = false; internal set
    /** MIX GLIDE: bend bpm+pitch toward a shared key (+ best-effort downbeat align), then settle. */
    var mixGlideEnabled = false; internal set
    /** How long tempo/pitch/effect eases IN (pre-roll) and back OUT (post-roll). Settings > Mix, default 10. */
    var mixGlideSeconds = 10.0; private set

    fun setMixGlideSeconds(s: Double) { mixGlideSeconds = maxOf(0.5, s) }

    internal var prerollStartedAt: Long? = null
    internal var postrollStartedAt: Long? = null
    /** This transition's preroll length (s), capped to fit the outgoing runway. */
    internal var glideInSecondsActive = 0.0
    /** True while the IN-FLIGHT transition is a glide (captured at its start). */
    internal var transitionIsGlide = false
    internal var ctx: GlideContext? = null

    private var textureEffect: Effect? = null
    private var texturePeak = 0.6
    private var textureRunRemaining = 0
    private var prng = SplitMix64(0x9E37_79B9_7F4A_7C15uL)

    /** Either glide feature armed => a transition uses the pre/post-roll machine. */
    val anyGlide: Boolean get() = fxGlideEnabled || mixGlideEnabled

    /** Reset the machine and seed the (deterministic) texture PRNG for a new mix. */
    internal fun reset(items: List<AutoMixItem>) {
        prerollStartedAt = null; postrollStartedAt = null
        transitionIsGlide = false; ctx = null
        textureEffect = null; textureRunRemaining = 0
        prng = SplitMix64(MixMath.fxSeed(items))
    }

    /** Drop every in-flight phase marker (the context is restored separately by [abort]). */
    internal fun clearPhases() {
        prerollStartedAt = null
        postrollStartedAt = null
        transitionIsGlide = false
    }

    internal fun shift(deltaMs: Long) {
        prerollStartedAt = prerollStartedAt?.plus(deltaMs)
        postrollStartedAt = postrollStartedAt?.plus(deltaMs)
    }

    /** Restore both decks from an interrupted glide. No-op when none is in flight. */
    internal fun abort() {
        val c = ctx ?: return
        setSlot(c.fxSlotFrom, c.savedFromOn, c.savedFromStrength, c.from)
        setSlot(c.fxSlotTo, c.savedToOn, c.savedToStrength, c.to)
        setRate(1.0, c.from); setPitch(0.0, c.from)
        setRate(1.0, c.to); setPitch(0.0, c.to)
        ctx = null
    }

    /**
     * Begin a GLIDE transition: snapshot the texture + tempo/pitch targets, then either start a
     * PRE-ROLL or (no room / manual skip) snap the outgoing glide and go straight to the crossfade.
     * [fade] (manual skip) overrides the crossfade length for this one transition.
     */
    internal fun begin(now: Long, preroll: Double, fade: Double? = null) {
        val from = dj.liveDeck
        val to = from.other
        val fxOn = fxGlideEnabled
        val tex = if (fxOn) currentTexture() else GlideTextureRoll(Effect.FILTER, 0.0)
        val mixOn = mixGlideEnabled
        val mp = if (mixOn) MixMath.glideParams(
            e.loaded(from)?.camelot, e.loaded(to)?.camelot, e.matchBpm(from), e.matchBpm(to),
        ) else com.levi.pocketdj.mix.model.GlideParams(1.0, 0.0, 1.0, 0.0)
        val slotFrom = slotFor(tex.effect, from)
        val slotTo = slotFor(tex.effect, to)
        val savedFrom = slotFrom?.let { e.deckState(from).slots.getOrNull(it) }
        val savedTo = slotTo?.let { e.deckState(to).slots.getOrNull(it) }
        ctx = GlideContext(
            from, to, fxOn, tex.effect, slotFrom, slotTo, tex.peak,
            savedFrom?.enabled ?: false, savedFrom?.strength ?: 0.5,
            savedTo?.enabled ?: false, savedTo?.strength ?: 0.5,
            mixOn, mp.outRate, mp.outPitch, mp.inRate, mp.inPitch,
        )
        transitionIsGlide = true
        if (fade != null) {                              // manual skip: custom fade, restored afterwards
            if (dj.pendingFadeRestore == null) dj.pendingFadeRestore = dj.fadeSeconds
            dj.fadeSeconds = maxOf(0.2, fade)
        }
        if (preroll > 0.05) {
            glideInSecondsActive = preroll
            prerollStartedAt = now
            emitOutgoing(preroll)
            if (fxOn) setSlot(slotFrom, true, 0.0, from)    // engage at 0
            applyOutgoing(0.0)
        } else {                                         // no runway / skip: snap + straight to the fade
            glideInSecondsActive = 0.0
            emitOutgoing(0.0)
            applyOutgoing(1.0)
            dj.beginAutoCrossfade(now)
            startCrossfade()
        }
    }

    /** PRE-ROLL step (progress 0..1): ramp the texture effect + tempo/pitch IN on the outgoing deck. */
    internal fun applyOutgoing(p: Double) {
        val c = ctx ?: return
        if (c.fxOn) setSlot(c.fxSlotFrom, true, p * c.fxPeak, c.from)
        if (c.mixOn) {
            setRate(1 + (c.outRate - 1) * p, c.from)
            setPitch(c.outPitch * p, c.from)
        }
    }

    /**
     * CROSSFADE begin: pin the outgoing deck at its glide target + the effect at peak on BOTH
     * decks, start the incoming at its opposite offset, best-effort downbeat-align it.
     */
    internal fun startCrossfade() {
        val c = ctx ?: return
        if (c.fxOn) {
            setSlot(c.fxSlotFrom, true, c.fxPeak, c.from)
            setSlot(c.fxSlotTo, true, c.fxPeak, c.to)
        }
        if (c.mixOn) {
            setRate(c.outRate, c.from); setPitch(c.outPitch, c.from)
            setRate(c.inRate, c.to); setPitch(c.inPitch, c.to)
            phaseAlign(c.to, c.from)
        }
    }

    /**
     * Best-effort downbeat align for the incoming deck. Uses the RECORDING seek (so the
     * beat-align lands in the timeline); during a transition the engine's seek hook no-ops the
     * end re-time, so the crossfade timing is undisturbed.
     */
    internal fun phaseAlign(f: Deck, l: Deck) {
        if (!e.isPlaying(f) || !e.isPlaying(l)) return
        val leadBpm = e.matchBpm(l) ?: return
        val folBpm = e.matchBpm(f) ?: return
        val leadBeat = 60.0 / leadBpm
        val folBeat = 60.0 / folBpm
        val leadDb = (e.loaded(l)?.firstDownbeatMs ?: 0) / 1000.0
        val folDb = (e.loaded(f)?.firstDownbeatMs ?: 0) / 1000.0
        val leadPhase = ((e.position(l) - leadDb) / leadBeat) % 1.0
        val folPhase = ((e.position(f) - folDb) / folBeat) % 1.0
        var delta = leadPhase - folPhase
        if (delta > 0.5) delta -= 1 else if (delta < -0.5) delta += 1
        e.seek(f, maxOf(0.0, e.position(f) + delta * folBeat))
    }

    /** POST-ROLL step (progress 0..1): ease the incoming deck's effect OFF + tempo/pitch to natural. */
    internal fun applyIncoming(p: Double) {
        val c = ctx ?: return
        if (c.fxOn) setSlot(c.fxSlotTo, true, (1 - p) * c.fxPeak, c.to)
        if (c.mixOn) {
            setRate(c.inRate + (1 - c.inRate) * p, c.to)
            setPitch(c.inPitch * (1 - p), c.to)
        }
    }

    /** Transition complete: restore the incoming deck's pre-glide effect state + natural tempo/pitch. */
    internal fun finish() {
        postrollStartedAt = null
        ctx?.let { c ->
            setSlot(c.fxSlotTo, c.savedToOn, c.savedToStrength, c.to)
            if (c.mixOn) { setRate(1.0, c.to); setPitch(0.0, c.to) }
        }
        ctx = null
        transitionIsGlide = false
    }

    /** After the crossfade: restore the retired outgoing deck BEFORE it is reloaded, then post-roll. */
    internal fun restoreOutgoing(from: Deck) {
        val c = ctx ?: return
        if (!transitionIsGlide) return
        setSlot(c.fxSlotFrom, c.savedFromOn, c.savedFromStrength, from)
        setRate(1.0, from); setPitch(0.0, from)
    }

    /** Hand off to the post-roll that eases the now-live incoming deck back to natural. */
    internal fun beginPostroll() {
        if (!transitionIsGlide) return
        if (mixGlideSeconds > 0.05) {
            postrollStartedAt = e.nowMs()
            emitIncoming()
        } else finish()
    }

    // ---------------------------------------------------------------------------------- texture

    internal class GlideTextureRoll(val effect: Effect, val peak: Double)

    /** Reuse the current texture across a run of 3..5 transitions, then re-roll (deterministic). */
    private fun currentTexture(): GlideTextureRoll {
        if (textureRunRemaining <= 0 || textureEffect == null) {
            val t = MixMath.rollTexture(prng)
            textureEffect = t.effect
            texturePeak = t.peak
            textureRunRemaining = t.run
        }
        textureRunRemaining -= 1
        return GlideTextureRoll(textureEffect ?: Effect.FILTER, texturePeak)
    }

    /**
     * Which slot a glide sweeps on [deck]: the first slot holding the rolled texture effect, else
     * the first holding ANY sweepable (pool) effect; null = nothing worth sweeping (all compressors).
     */
    internal fun slotFor(effect: Effect, deck: Deck): Int? {
        val slots = e.deckState(deck).slots
        slots.indexOfFirst { it.effect == effect }.takeIf { it >= 0 }?.let { return it }
        return slots.indexOfFirst { it.effect in MixMath.FX_GLIDE_POOL }.takeIf { it >= 0 }
    }

    // ---------------------------------------------------------------------------------- setters

    internal fun setRate(rate: Double, deck: Deck) {
        val r = rate.coerceIn(MixRanges.rate.start, MixRanges.rate.endInclusive)
        e.updateDeck(deck) { it.copy(rate = r) }
        e.params.setTempoPitch(deck, r, e.deckState(deck).pitch)
    }

    internal fun setPitch(semitones: Double, deck: Deck) {
        val p = semitones.coerceIn(MixRanges.pitch.start, MixRanges.pitch.endInclusive)
        e.updateDeck(deck) { it.copy(pitch = p) }
        e.params.setTempoPitch(deck, e.deckState(deck).rate, p)
    }

    /**
     * Sweep ONE rack slot. Never touches the slot's effect/variant: the glide rides whatever the DJ
     * put there. A null slot is a silent no-op.
     */
    internal fun setSlot(i: Int?, enabled: Boolean, strength: Double, deck: Deck) {
        if (i == null || e.deckState(deck).slots.getOrNull(i) == null) return
        e.updateDeck(deck) { s -> s.withSlot(i) { it.setEnabled(enabled).setStrength(strength) } }
        e.params.setSlots(deck, e.deckState(deck).slots.map { SlotParams(it, it.strength) })
    }

    // ---------------------------------------------------------------------------------- recording

    /** ONE compact `.glide` event per ramp; a no-op ramp (from ~ to) logs nothing. */
    internal fun recGlide(param: String, deck: Deck?, from: Double, to: Double, span: Double, slot: Int? = null) {
        val r = e.recorder ?: return
        if (kotlin.math.abs(to - from) <= 1e-6) return
        val l = deck?.let { e.loaded(it) }
        r.logGlide(
            deck?.label, param, l?.songId, l?.title, l?.artist, from, to,
            (to - from) / maxOf(0.05, span), deck?.let { (e.position(it) * 1000).toInt() }, slot,
        )
    }

    private fun emitOutgoing(span: Double) {
        val c = ctx ?: return
        if (c.mixOn) {
            recGlide("tempo", c.from, 1.0, c.outRate, span)
            recGlide("pitch", c.from, 0.0, c.outPitch, span)
        }
        // Only an FX ramp that actually happened: a rack with nothing sweepable leaves no phantom node.
        if (c.fxOn && c.fxSlotFrom != null) recGlide(c.fxEffect.raw, c.from, 0.0, c.fxPeak, span, c.fxSlotFrom)
    }

    private fun emitIncoming() {
        val c = ctx ?: return
        val span = maxOf(mixGlideSeconds, 0.01)
        if (c.mixOn) {
            recGlide("tempo", c.to, c.inRate, 1.0, span)
            recGlide("pitch", c.to, c.inPitch, 0.0, span)
        }
        if (c.fxOn && c.fxSlotTo != null) recGlide(c.fxEffect.raw, c.to, c.fxPeak, 0.0, span, c.fxSlotTo)
    }
}
