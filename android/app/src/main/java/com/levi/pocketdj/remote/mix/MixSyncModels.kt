package com.levi.pocketdj.remote.mix

import com.levi.pocketdj.mix.model.Deck
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.math.roundToLong

/**
 * Multiplayer Mix ("Mix Together") wire kinds + the authoritative model, ported from iOS `MixSyncModels.swift`.
 *
 * Mix rides the Remote session's transport and envelope with new `kind` strings (a Phase-1 build ignores them).
 * Audio is never streamed: every device renders both decks locally from shared state. JSON field names match iOS
 * exactly; the Swift-synthesised Codable REQUIRES non-optional keys (`rate`, `controls`, `assignedB`...), which
 * `PdjJson.lenient` emits because it encodes defaults.
 */
object MixWireKind {
    const val SNAPSHOT = "mix.snapshot"
    const val EVENT = "mix.event"
    const val REQUEST = "mix.request"
    const val READY = "mix.ready"
    const val BEAT = "mix.beat"
    const val REJECT = "mix.reject"
    const val HANDOVER = "mix.handover"

    val all = listOf(SNAPSHOT, EVENT, REQUEST, READY, BEAT, REJECT, HANDOVER)
}

/** The `RemoteHello.caps` entry a device that can own a deck advertises (an Apple TV never does). */
object MixCapability {
    const val DECK_OWNER = "mix"
}

/** Sync-layer event kinds beyond the engine's gesture kinds (iOS `MixSyncKind`). */
object MixSyncKind {
    const val PLAY = "play"
    const val PAUSE = "pause"
    const val SEEK = "seek"
    const val LOAD = "load"
    const val EJECT = "eject"
    const val LOOP = "loop"
    const val LOOP_UNITS = "loopUnits"
    const val CROSSFADER = "crossfader"
    const val RESET_DECK = "resetDeck"
    const val LEAD = "lead"
    const val TEMPO = "tempo"
    const val SYNC = "sync"

    /** participant -> host proposals; the host answers with an [OWNER] event. */
    const val CLAIM = "claim"
    const val RELEASE = "release"

    /** host-only: a deck's owner changed (`MixSyncEvent.owner`, null = free). */
    const val OWNER = "owner"

    /** host-only: the mix session started (`flag` true) / ended (false). */
    const val SESSION = "session"

    val transport: Set<String> = setOf(PLAY, PAUSE, SEEK)

    /** Continuous surfaces: proposals coalesce to one per [MixSyncTunables.CONTINUOUS_INTERVAL_MS] per control. */
    val continuous: Set<String> =
        setOf(TEMPO, "pitch", "volume", "eq", "effectStrength", "stemVolume", "effectMod", CROSSFADER)
}

/** "Deck at [positionMs] (source ms) at shared time [atSharedTime], playing or paused". */
@Serializable
data class MixSyncAnchor(
    val positionMs: Int,
    val atSharedTime: Double? = null,
    val isPlaying: Boolean,
) {
    /** The deck's position at shared time [t] (a playing deck advances at [rate] x wall time). */
    fun position(t: Double, rate: Double): Int {
        val at = atSharedTime
        if (!isPlaying || at == null) return positionMs
        return maxOf(0, positionMs + ((t - at) * rate).roundToLong().toInt())
    }
}

/** One mix event (iOS `MixSyncEvent`). [deck] is the iOS raw value, "A" / "B" = Android `Deck.label`. */
@Serializable
data class MixSyncEvent(
    val kind: String,
    val deck: String? = null,
    val songId: String? = null,
    val title: String? = null,
    val artist: String? = null,
    val appleMusicId: String? = null,
    val bpm: Double? = null,
    val camelot: String? = null,
    val key: String? = null,
    val albumId: String? = null,
    val lengthMs: Int? = null,
    val param: String? = null,
    val value: Double? = null,
    val flag: Boolean? = null,
    val slot: Int? = null,
    val posMs: Int? = null,
    val anchor: MixSyncAnchor? = null,
    val owner: String? = null,
    val loopStartMs: Int? = null,
    val loopEndMs: Int? = null,
) {
    val engineDeck: Deck? get() = deck?.let { Deck.fromLabel(it) }
    val isTransport: Boolean get() = kind in MixSyncKind.transport

    /** Carries a shared-clock anchor the host re-times into the future (transport, and reset). */
    val carriesAnchor: Boolean get() = isTransport || kind == MixSyncKind.RESET_DECK

    /**
     * The CONTROL this event sets: latest-wins per key. Every transport-ish kind (load / eject / play / pause /
     * seek) shares one key per deck.
     */
    val controlKey: String
        get() {
            val d = deck ?: "-"
            return when (kind) {
                MixSyncKind.LOAD, MixSyncKind.EJECT, MixSyncKind.PLAY, MixSyncKind.PAUSE, MixSyncKind.SEEK -> "transport:$d"
                MixSyncKind.TEMPO, MixSyncKind.SYNC -> "rate:$d"
                MixSyncKind.CROSSFADER -> "crossfader"
                MixSyncKind.LOOP, MixSyncKind.LOOP_UNITS -> "loop:$d"
                else -> "$kind:$d:${slot?.let { "#$it" } ?: param ?: ""}"
            }
        }
}

/** A proposal (participant -> host: [hostSeq] null) or an ordered event (host -> all). */
@Serializable
data class MixSyncEventMessage(
    /** The ORIGIN's own monotonic counter; pairs an echo with the proposal it answers. */
    val originSeq: Int,
    val origin: String? = null,
    val hostSeq: Int? = null,
    val epoch: String? = null,
    val event: MixSyncEvent,
)

/** One deck of the authoritative mix. */
@Serializable
data class MixSyncDeckState(
    val owner: String? = null,
    val track: MixSyncEvent? = null,
    val anchor: MixSyncAnchor? = null,
    val rate: Double = 1.0,
    val controls: List<MixSyncEvent> = emptyList(),
) {
    fun withControl(e: MixSyncEvent): MixSyncDeckState {
        val k = e.controlKey
        return copy(controls = controls.filter { it.controlKey != k } + e)
    }

    fun dropControls(drop: (MixSyncEvent) -> Boolean): MixSyncDeckState = copy(controls = controls.filterNot(drop))
}

/** The full authoritative mix (a `mix.snapshot` body). */
@Serializable
data class MixSyncSnapshot(
    val epoch: String,
    val active: Boolean,
    val hostSeq: Int,
    val decks: Map<String, MixSyncDeckState>,
    val crossfader: Double? = null,
    val assignedB: Boolean,
)

@Serializable
data class MixSyncReady(val deck: String, val songId: String? = null, val status: Status) {
    @Serializable
    enum class Status {
        @SerialName("ready") READY,
        @SerialName("loading") LOADING,
        @SerialName("unavailable") UNAVAILABLE,
        @SerialName("empty") EMPTY,
    }
}

@Serializable
data class MixSyncBeat(
    val deck: String,
    val songId: String,
    val anchor: MixSyncAnchor,
    val epoch: String,
    val uncertaintyMs: Double? = null,
)

/** `mix.handover` body: a mirror's snapshot with every anchor on the SENDER's local clock. */
@Serializable
data class MixSyncHandover(val snapshot: MixSyncSnapshot, val sentAtLocal: Double)

@Serializable
data class MixSyncReject(val originSeq: Int, val reason: String)

@Serializable
data class MixSyncRequest(val reason: String)

/** The mix as the HOST orders it, mirrored on every device by applying ordered events in host order. */
data class MixSyncModel(
    val epoch: String = "",
    val active: Boolean = false,
    val hostSeq: Int = 0,
    val decks: Map<Deck, MixSyncDeckState> = mapOf(Deck.A to MixSyncDeckState(), Deck.B to MixSyncDeckState()),
    val crossfader: Double? = null,
    val assignedB: Boolean = false,
) {
    constructor(s: MixSyncSnapshot) : this(
        epoch = s.epoch, active = s.active, hostSeq = s.hostSeq,
        decks = Deck.entries.associateWith { s.decks[it.label] ?: MixSyncDeckState() },
        crossfader = s.crossfader, assignedB = s.assignedB,
    )

    fun snapshot() = MixSyncSnapshot(
        epoch, active, hostSeq, decks.entries.associate { it.key.label to it.value }, crossfader, assignedB,
    )

    fun deck(d: Deck): MixSyncDeckState = decks[d] ?: MixSyncDeckState()
    fun owner(d: Deck): String? = decks[d]?.owner
    fun decks(ownedBy: String): List<Deck> = Deck.entries.filter { owner(it) == ownedBy }

    /** Fold one ORDERED event in. [sharedNow] stamps an anchor that arrived without a time. */
    fun apply(e: MixSyncEvent, sharedNow: Double): MixSyncModel {
        if (e.kind == MixSyncKind.SESSION) return copy(active = e.flag ?: false)
        if (e.kind == MixSyncKind.CROSSFADER) return copy(crossfader = e.value)
        val d = e.engineDeck ?: return this
        var ds = deck(d)
        var b = assignedB
        var out = decks
        fun stamp(a: MixSyncAnchor) = if (a.atSharedTime == null) a.copy(atSharedTime = sharedNow) else a
        when (e.kind) {
            MixSyncKind.OWNER -> {
                ds = ds.copy(owner = e.owner)
                if (d == Deck.B && e.owner != null) b = true
            }
            MixSyncKind.LOAD -> {
                ds = ds.copy(track = e, anchor = MixSyncAnchor(0, sharedNow, false), rate = 1.0)
                    .dropControls { it.kind in RESET_BY_LOAD }
            }
            MixSyncKind.EJECT -> ds = ds.copy(track = null, anchor = null, rate = 1.0, controls = emptyList())
            MixSyncKind.PLAY, MixSyncKind.PAUSE, MixSyncKind.SEEK ->
                e.anchor?.let { ds = ds.copy(anchor = stamp(it)) }
            MixSyncKind.RESET_DECK -> {
                ds = ds.copy(rate = 1.0).dropControls { it.kind in RESET_BY_RESET }
                val a = e.anchor
                ds = if (a != null) ds.copy(anchor = stamp(a))
                else ds.copy(anchor = MixSyncAnchor(0, sharedNow, ds.anchor?.isPlaying ?: false))
            }
            MixSyncKind.TEMPO, MixSyncKind.SYNC -> {
                ds = ds.copy(rate = e.value ?: ds.rate).withControl(e)
            }
            MixSyncKind.LEAD -> {
                ds = ds.withControl(e)
                if (e.flag == true) {
                    out = out.mapValues { (k, v) -> if (k != d) v.dropControls { it.kind == MixSyncKind.LEAD } else v }
                }
            }
            else -> ds = ds.withControl(e)
        }
        return copy(decks = out + (d to ds), assignedB = b)
    }

    companion object {
        /** Controls a fresh LOAD returns to default. */
        val RESET_BY_LOAD = setOf(
            MixSyncKind.TEMPO, MixSyncKind.SYNC, "pitch", "stemMode", "stemMute", "stemVolume",
            MixSyncKind.LOOP, MixSyncKind.LOOP_UNITS, MixSyncKind.LEAD,
        )

        /** Controls the reset returns to default (keeps rack layout, stem mode, lead, loop). */
        val RESET_BY_RESET = setOf(
            MixSyncKind.TEMPO, MixSyncKind.SYNC, "pitch", "volume", "effectToggle", "effectStrength", "eq",
            "stemMute", "stemVolume",
        )
    }
}

/** The tunables (iOS `MixSync` statics). Drift constants live here too so REM-12 shares one source. */
object MixSyncTunables {
    const val TICK_INTERVAL_MS = 250.0
    const val START_LEAD_MS = 300.0
    const val MIN_LEAD_MS = 60.0
    const val HEARTBEAT_MS = 2_000.0
    const val DRIFT_THRESHOLD_MS = 40
    const val DRIFT_MARGIN_MS = 20.0
    const val DRIFT_STRIKES_NEEDED = 2
    const val NUDGE_MAX_MS = 250
    const val NUDGE_RATE = 0.01
    const val DRIFT_COOLDOWN_MS = 4_000.0
    const val STALE_BEAT_MS = 1_500.0
    const val READY_TIMEOUT_MS = 4_000.0
    const val GAP_TIMEOUT_MS = 1_500.0
    const val SNAPSHOT_RETRY_MS = 3_000.0
    const val SNAPSHOT_MAX_ATTEMPTS = 5
    const val PENDING_TIMEOUT_MS = 2_000.0
    const val CONTINUOUS_INTERVAL_MS = 50.0
    const val SEEK_INTERVAL_MS = 250.0
    const val MAX_LEAD_MS = 2_000.0
    const val EVENT_BUFFER_CAP = 512
    const val AUTO_DJ_BLOCKED_REASON = "Auto DJ is off while you mix together."
}
