package com.levi.pocketdj.mix.graph

import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.FXSlot
import com.levi.pocketdj.mix.model.FxRack
import com.levi.pocketdj.mix.model.MixMath
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min

/** One live FX slot as the render thread sees it: the slot value + its effective (modulated) strength. */
class SlotParams(val slot: FXSlot, val strength: Double)

/**
 * Immutable per-deck parameters, swapped atomically into the render thread via [RenderParams].
 * The render thread never mutates these; it ramps from what it last applied to these over one block.
 */
class DeckParams(
    /** Channel-fader send: min(volume,1) x equal-power crossfade factor. */
    val mainGain: Float = 1f,
    /** PFL send: cued ? cueVol / max(volume,1) : 0. */
    val cueGain: Float = 0f,
    /** Volume boost in dB (0 at <=100 %, +6 dB at 200 %). Written ONLY by volume changes. */
    val trimDb: Float = 0f,
    val eqLowDb: Float = 0f,
    val eqMidDb: Float = 0f,
    val eqHighDb: Float = 0f,
    /** Time-stretch tempo multiplier (pitch preserved). */
    val speed: Float = 1f,
    val pitchSemitones: Float = 0f,
    stemBalance: FloatArray = floatArrayOf(1f, 1f, 1f, 1f),
    /** Up to [FxRack.SLOT_COUNT] entries; a null / missing entry is an off slot. */
    val slots: List<SlotParams?> = emptyList(),
) {
    private val balance = stemBalance.copyOf(STEMS)

    /** Per-stem balance 0..1 (vocals, drums, bass, other); the handover voice gain multiplies it. */
    fun stemBalance(i: Int): Float = balance[i]

    fun slot(i: Int): SlotParams? = if (i < slots.size) slots[i] else null

    fun with(
        mainGain: Float = this.mainGain, cueGain: Float = this.cueGain, trimDb: Float = this.trimDb,
        eqLowDb: Float = this.eqLowDb, eqMidDb: Float = this.eqMidDb, eqHighDb: Float = this.eqHighDb,
        speed: Float = this.speed, pitchSemitones: Float = this.pitchSemitones,
        stemBalance: FloatArray = this.balance, slots: List<SlotParams?> = this.slots,
    ) = DeckParams(mainGain, cueGain, trimDb, eqLowDb, eqMidDb, eqHighDb, speed, pitchSemitones, stemBalance, slots)

    companion object { const val STEMS = 4 }
}

/**
 * House-level parameters. [housePan] is the hard pan of the house mix (non-zero only while any
 * deck is cued); [cuePan] the side the cue sends land on. Pans are +1 right / -1 left, 0 = off
 * (the stereo path is then skipped entirely, bit-identical to a mix that never had a cue).
 */
class HouseParams(
    val housePan: Float = 0f,
    val cuePan: Float = 0f,
    val limiterBypass: Boolean = false,
)

/** The whole graph's parameter snapshot: immutable, swapped through an AtomicReference. */
class RenderParams(val a: DeckParams = DeckParams(), val b: DeckParams = DeckParams(), val house: HouseParams = HouseParams()) {
    fun deck(d: Deck): DeckParams = if (d == Deck.A) a else b

    /** iOS `cueRoutingSnapshot`: (mainVol, cueVol, mainPan, cuePan) for one deck. */
    fun routing(d: Deck): RoutingSnapshot =
        RoutingSnapshot(deck(d).mainGain, deck(d).cueGain, house.housePan, house.cuePan)

    fun withDeck(d: Deck, p: DeckParams) = if (d == Deck.A) RenderParams(p, b, house) else RenderParams(a, p, house)
    fun withHouse(h: HouseParams) = RenderParams(a, b, h)
}

data class RoutingSnapshot(val mainVol: Float, val cueVol: Float, val mainPan: Float, val cuePan: Float)

/** The channel-strip gain split, as pure functions (iOS `userGain`/`applyBoost`/`applyCueRouting`). */
object Routing {
    /** Main fader: volume clamped to 1 times the equal-power crossfade factor. */
    fun mainGain(volume: Double, crossfade: Float): Float = min(volume, 1.0).toFloat() * crossfade

    /** Boost above unity rides the trim: 20*log10(max(volume,1)) dB. */
    fun trimDb(volume: Double): Float = (20 * log10(max(volume, 1.0))).toFloat()

    /** Pre-fader, pre-boost cue send: the boost is divided back out so the monitor sits at cueVol. */
    fun cueSend(volume: Double, cued: Boolean, cueVol: Double): Float =
        if (cued) (cueVol / max(volume, 1.0)).toFloat() else 0f

    fun cueSide(cueOnRight: Boolean): Float = if (cueOnRight) 1f else -1f

    /** The house goes to the opposite side of the cue, only while any deck is cued. */
    fun housePan(anyCued: Boolean, cueSide: Float): Float = if (anyCued) -cueSide else 0f
}

/** Control-thread view of a deck, enough to compose [DeckParams]. */
data class DeckInputs(
    val volume: Double = 1.0,
    val cued: Boolean = false,
    val cueVol: Double = 1.0,
    val eqLowDb: Double = 0.0,
    val eqMidDb: Double = 0.0,
    val eqHighDb: Double = 0.0,
    val speed: Double = 1.0,
    val pitchSemitones: Double = 0.0,
    val stemBalance: FloatArray = floatArrayOf(1f, 1f, 1f, 1f),
    val slots: List<SlotParams?> = emptyList(),
) {
    override fun equals(other: Any?) = other is DeckInputs && volume == other.volume && cued == other.cued &&
        cueVol == other.cueVol && eqLowDb == other.eqLowDb && eqMidDb == other.eqMidDb && eqHighDb == other.eqHighDb &&
        speed == other.speed && pitchSemitones == other.pitchSemitones && stemBalance.contentEquals(other.stemBalance) &&
        slots == other.slots
    override fun hashCode() = volume.hashCode() * 31 + cued.hashCode()
}

/**
 * Builds [RenderParams] from engine-side state, and is where the boost/crossfade separation is
 * enforced: [setCrossfader] recomputes only mainGain (the trim dB is carried over unchanged and
 * [boostWrites] does not move); only [setVolume] (and a full [reset]) re-derives the trim.
 */
class ParamsComposer(private val graph: MixGraph? = null) {
    private val inputs = arrayOf(DeckInputs(), DeckInputs())
    var crossfader = 0.5f; private set
    var cueOnRight = true; private set
    var limiterBypass = false; private set

    /** Number of times the trim (volume boost) was re-derived. Crossfader moves must not bump it. */
    var boostWrites = 0; private set

    var current: RenderParams = compose(); private set

    fun inputs(d: Deck): DeckInputs = inputs[d.ordinal]

    fun setVolume(d: Deck, v: Double) { update(d) { it.copy(volume = v) }; boostWrites++; publish(trimFrom = null) }
    fun setCued(d: Deck, on: Boolean) { update(d) { it.copy(cued = on) }; publish() }
    fun setCueVolume(d: Deck, v: Double) { update(d) { it.copy(cueVol = v) }; publish() }
    fun setCueOnRight(on: Boolean) { cueOnRight = on; publish() }
    fun setCrossfader(x: Float) { crossfader = x; publish() }
    fun setLimiterBypass(on: Boolean) { limiterBypass = on; publish() }
    fun setEq(d: Deck, low: Double, mid: Double, high: Double) { update(d) { it.copy(eqLowDb = low, eqMidDb = mid, eqHighDb = high) }; publish() }
    fun setTempoPitch(d: Deck, speed: Double, semitones: Double) { update(d) { it.copy(speed = speed, pitchSemitones = semitones) }; publish() }
    fun setStemBalance(d: Deck, balance: FloatArray) { update(d) { it.copy(stemBalance = balance.copyOf()) }; publish() }
    fun setSlots(d: Deck, slots: List<SlotParams?>) { update(d) { it.copy(slots = slots) }; publish() }

    private inline fun update(d: Deck, f: (DeckInputs) -> DeckInputs) { inputs[d.ordinal] = f(inputs[d.ordinal]) }

    /** Recompose. [trimFrom] null = re-derive trim from volume; otherwise keep the previous trim dB. */
    private fun publish(trimFrom: RenderParams? = current) {
        current = compose(trimFrom)
        graph?.setParams(current)
    }

    private fun compose(prev: RenderParams? = null): RenderParams {
        val side = Routing.cueSide(cueOnRight)
        val any = inputs[0].cued || inputs[1].cued
        return RenderParams(
            deckParams(Deck.A, prev?.a), deckParams(Deck.B, prev?.b),
            HouseParams(Routing.housePan(any, side), side, limiterBypass),
        )
    }

    private fun deckParams(d: Deck, prev: DeckParams?): DeckParams {
        val i = inputs[d.ordinal]
        return DeckParams(
            mainGain = Routing.mainGain(i.volume, MixMath.crossfadeFactor(d, crossfader)),
            cueGain = Routing.cueSend(i.volume, i.cued, i.cueVol),
            trimDb = prev?.trimDb ?: Routing.trimDb(i.volume), // crossfader path keeps the trim untouched
            eqLowDb = i.eqLowDb.toFloat(), eqMidDb = i.eqMidDb.toFloat(), eqHighDb = i.eqHighDb.toFloat(),
            speed = i.speed.toFloat(), pitchSemitones = i.pitchSemitones.toFloat(),
            stemBalance = i.stemBalance, slots = i.slots,
        )
    }
}
