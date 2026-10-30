package com.levi.pocketdj.mix.store

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.EffectVariant
import com.levi.pocketdj.mix.model.FXSlot
import com.levi.pocketdj.mix.model.FxRack
import com.levi.pocketdj.mix.model.ModRate
import com.levi.pocketdj.mix.model.ModShape
import com.levi.pocketdj.mix.model.ModSource
import com.levi.pocketdj.mix.model.SlotMod
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Version stamp on the persisted mix-deck snapshot; a mismatched file never restores (never migrated). */
const val MIX_DECK_SESSION_SCHEMA_VERSION = 1

/** A deck-loadable track's identity + display metadata (iOS `TrackRef`). */
@Serializable
data class TrackRef(
    val songId: String,
    val title: String,
    val artist: String,
    val bpm: Double? = null,
    val camelot: String? = null,
    val key: String? = null,
    val albumId: String? = null,
    /** Bounds an analog shared-album fallback to its slice on re-load. */
    val lengthMs: Int? = null,
)

/**
 * One rack slot on disk. Strings (not enums) so an unrecognised value from a NEWER build
 * degrades to a default on load instead of discarding the whole session.
 */
@Serializable
data class FXSlotSnapshot(
    val effect: String,
    val variant: String,
    val on: Boolean,
    val strength: Double,
    val modSource: String? = null,
    val modRate: String? = null,
    val modShape: String? = null,
    val modDepth: Double? = null,
    val modPhase: Double? = null,
) {
    /**
     * Both raw values resolve AND the variant belongs to the effect's family. Mod fields are
     * deliberately NOT validated: garbage there must never cost the user the rack layout.
     */
    val isWellFormed: Boolean
        get() {
            val e = Effect.fromRaw(effect) ?: return false
            val v = EffectVariant.fromRaw(variant) ?: return false
            return v.effect == e
        }

    /** Total: unknown/absent mod values become defaults (source falls back to off). */
    val resolvedMod: SlotMod
        get() = SlotMod.of(
            source = ModSource.fromRaw(modSource) ?: ModSource.OFF,
            rate = ModRate.fromRaw(modRate) ?: ModRate.BAR,
            depth = modDepth ?: 0.5,
            shape = ModShape.fromRaw(modShape) ?: ModShape.SINE,
            phase = modPhase ?: 0.0,
        )

    /** The live slot this snapshot restores to; a malformed slot degrades to its family default. */
    fun toSlot(): FXSlot = FXSlot(
        effect = Effect.fromRaw(effect) ?: Effect.COMPRESSOR,
        variant = EffectVariant.fromRaw(variant),
        enabled = on, strength = strength, mod = resolvedMod,
    )

    companion object {
        fun from(slot: FXSlot) = FXSlotSnapshot(
            effect = slot.effect.raw, variant = slot.variant.raw, on = slot.enabled,
            strength = slot.strength, modSource = slot.mod.source.raw, modRate = slot.mod.rate.raw,
            modShape = slot.mod.shape.raw, modDepth = slot.mod.depth, modPhase = slot.mod.phase,
        )
    }
}

/**
 * One deck's restorable state: the track plus every plain-value control. Post-v1 fields are
 * OPTIONAL — the loader demands an exact schema match, so optionality is what lets older
 * sessions keep restoring.
 */
@Serializable
data class DeckSnapshot(
    val track: TrackRef,
    /** Playhead, ms from the song's own 0:00. */
    val positionMs: Int,
    val volume: Double,
    val rate: Double,
    val pitch: Double,
    val compressor: Boolean,
    val reverb: Boolean,
    val flanger: Boolean,
    val filter: Boolean,
    val compStrength: Double,
    val reverbStrength: Double,
    val flangerStrength: Double,
    val filterStrength: Double,
    val stemMode: Boolean,
    val stemMuted: List<String>,
    val stemVol: Map<String, Double>,
    val loopOn: Boolean? = null,
    val loopUnits: Double? = null,
    val eqLow: Double? = null,
    val eqMid: Double? = null,
    val eqHigh: Double? = null,
    /** SUPERSEDED by [fxSlots]; still written for rollback and read when migrating a pre-rack session. */
    val filterMode: String? = null,
    val fxSlots: List<FXSlotSnapshot>? = null,
) {
    /**
     * The rack layout a restore should apply: the lossless [fxSlots] when present and
     * well-formed, else the pre-rack flat fields mapped onto the default layout.
     * Never fails, never empty.
     */
    val resolvedSlots: List<FXSlotSnapshot>
        get() {
            val s = fxSlots
            if (s != null && s.size == FxRack.SLOT_COUNT && s.all { it.isWellFormed }) return s
            return listOf(
                FXSlotSnapshot("compressor", "punch", compressor, compStrength),
                FXSlotSnapshot("reverb", "hall", reverb, reverbStrength),
                FXSlotSnapshot("flanger", "flange", flanger, flangerStrength),
                FXSlotSnapshot(
                    "filter", if (filterMode == "highPass") "highPass" else "lowPass",
                    filter, filterStrength,
                ),
            )
        }
}

/** One Auto-DJ queue row. */
@Serializable
data class AutoRow(
    val track: TrackRef,
    val durationMs: Int,
    /** Crate provenance; null for legacy rows. */
    val sourceLabel: String? = null,
)

/** The Auto-DJ machine's restorable state (queue in FINAL order; restore is always suspended). */
@Serializable
data class AutoSnapshot(
    val queue: List<AutoRow>,
    val livePos: Int,
    val nextToLoad: Int,
    /** "A"/"B". */
    val liveDeck: String,
    val sourceLabel: String? = null,
    val leadSeconds: Double,
    val fadeSeconds: Double,
    val fxGlide: Boolean,
    val mixGlide: Boolean,
    /** AutoRepeatMode raw — absent/legacy means off. */
    val repeatMode: String? = null,
)

@Serializable
data class MixDeckSnapshot(
    val schemaVersion: Int = MIX_DECK_SESSION_SCHEMA_VERSION,
    val deckA: DeckSnapshot? = null,
    val deckB: DeckSnapshot? = null,
    val crossfader: Double,
    /** "A"/"B", null = none. */
    val leadDeck: String? = null,
    val auto: AutoSnapshot? = null,
    /** Whether any deck was audibly playing at the last write (also the position throttle's transition detector). */
    val wasRunning: Boolean,
    /** Epoch ms of the last write. */
    val updatedAt: Double,
) {
    /** Nothing to restore (no deck, no auto queue). */
    val isEmpty: Boolean get() = deckA == null && deckB == null && (auto?.queue?.isEmpty() ?: true)

    /**
     * A FINISHED mix: the live deck sits at end-of-file and nothing can follow (standby holds
     * nothing playable, Auto-DJ cursor can't advance, repeat off). No wall-clock expiry.
     */
    val isExhausted: Boolean
        get() {
            fun atEnd(d: DeckSnapshot?): Boolean {
                val len = d?.track?.lengthMs ?: return false
                return len > 0 && d.positionMs >= len - 500
            }
            val liveRaw = auto?.liveDeck ?: leadDeck ?: (if (deckA != null) "A" else "B")
            val live = if (liveRaw == "B") deckB else deckA
            val other = if (liveRaw == "B") deckA else deckB
            if (live == null || !atEnd(live)) return false
            if (other != null && !atEnd(other)) return false
            val a = auto
            if (a != null && a.queue.isNotEmpty() &&
                (a.nextToLoad < a.queue.size || (a.repeatMode != null && a.repeatMode != "off"))
            ) return false
            return true
        }
}

/**
 * Durable Mix deck session: the single overwrite-in-place snapshot of the live mix
 * (`pocketdj-mix-decks.json`, schema 1, shape-identical to iOS). Structural changes write
 * immediately ([save]); slider-y changes are trailing-edge debounced ([saveDebounced]);
 * playhead refreshes are throttled while running and immediate on a run/pause transition
 * ([updatePosition]). All disk work rides the shared [VersionedJsonWriter], so a stale write
 * can never clobber a newer one, including [clear]'s delete. NO disk I/O in the constructor;
 * [load] is lenient (any failure -> null).
 */
class MixDeckSessionStore(
    private val file: File,
    private val writer: VersionedJsonWriter = VersionedJsonWriter(file),
    private val clock: () -> Long = System::currentTimeMillis,
    private val scheduler: StoreScheduler = StoreScheduler.DEFAULT,
    /** Test seam: the snapshot encoder (production = [encode]). */
    private val encoder: (MixDeckSnapshot) -> String = { encode(it) },
) {
    /** Min ms between position-only writes while running. */
    @Volatile var positionWriteIntervalMs: Long = 5_000
    /** Trailing-edge debounce for slider-y control writes. */
    @Volatile var controlDebounceIntervalMs: Long = 1_000

    private val lock = Any()
    private var current: MixDeckSnapshot? = null
    private var version = 0L
    private var lastWriteAt = 0L
    private var debounce: Cancellable? = null
    private var debounceArmed = false

    /** The on-disk document (cloud-sync registration reads the same file). */
    val syncFile: File get() = file

    /** STRUCTURAL change: persists immediately, superseding any pending debounce. */
    fun save(snapshot: MixDeckSnapshot, nowMs: Long = clock()) = synchronized(lock) {
        cancelDebounce()
        current = snapshot.copy(updatedAt = nowMs.toDouble())
        writeNow(nowMs)
    }

    /**
     * CONTROL change from a continuous surface: update memory now, land ONE write
     * [controlDebounceIntervalMs] after the burst ends (the drag's final value always persists).
     */
    fun saveDebounced(snapshot: MixDeckSnapshot, nowMs: Long = clock()) = synchronized(lock) {
        current = snapshot.copy(updatedAt = nowMs.toDouble())
        if (debounceArmed) return@synchronized   // an armed write picks up the latest state
        debounceArmed = true
        debounce = scheduler.schedule(controlDebounceIntervalMs) {
            synchronized(lock) {
                if (!debounceArmed) return@synchronized
                debounceArmed = false
                debounce = null
                writeNow(clock())
            }
        }
    }

    /**
     * Playhead refresh for the CURRENT mix: at most one write per [positionWriteIntervalMs]
     * while running; a run/pause TRANSITION writes immediately; steady paused writes nothing.
     * No-op when no mix is active.
     */
    fun updatePosition(aMs: Int?, bMs: Int?, isRunning: Boolean, nowMs: Long = clock()) = synchronized(lock) {
        val snap = current ?: return@synchronized
        val wasRunning = snap.wasRunning
        current = snap.copy(
            deckA = if (aMs != null) snap.deckA?.copy(positionMs = aMs) else snap.deckA,
            deckB = if (bMs != null) snap.deckB?.copy(positionMs = bMs) else snap.deckB,
            wasRunning = isRunning,
            updatedAt = nowMs.toDouble(),
        )
        if (isRunning != wasRunning) writeNow(nowMs)
        else if (isRunning && nowMs - lastWriteAt >= positionWriteIntervalMs) writeNow(nowMs)
    }

    /** The mix is genuinely over: forget it and delete the file (version-ordered). */
    /** Block until queued writes (this store's and the sibling session store's, same executor) have run. */
    fun awaitWrites() = writer.awaitIdle()

    fun clear() = synchronized(lock) {
        cancelDebounce()
        current = null
        version += 1
        writer.delete(version)
    }

    /**
     * The persisted snapshot or null. LENIENT: unreadable/undecodable, schema mismatch,
     * empty, or exhausted -> null.
     */
    fun load(): MixDeckSnapshot? {
        return try {
            if (!file.exists()) return null
            val text = file.readText()
            val obj = PdjJson.lenient.parseToJsonElement(text).jsonObject
            if (!obj.hasExactSchema()) return null
            val snap = PdjJson.lenient.decodeFromString<MixDeckSnapshot>(text)
            if (snap.isEmpty || snap.isExhausted) null else snap
        } catch (_: Exception) {
            null
        }
    }

    /** Force-persist now (scene -> background), SYNCHRONOUSLY, beating any queued write. */
    fun flush(nowMs: Long = clock()) {
        // Snapshot + version under the lock; the (possibly large) encode and the disk write run OUTSIDE it,
        // so a position tick / save never waits behind a flush.
        val snap: MixDeckSnapshot
        val v: Long
        synchronized(lock) {
            val cur = current ?: return
            cancelDebounce()
            version += 1
            lastWriteAt = nowMs
            snap = cur.copy(updatedAt = nowMs.toDouble())
            current = snap
            v = version
        }
        writer.flushNow(v) { encoder(snap) }
    }

    private fun writeNow(nowMs: Long) {
        val snap = current ?: return
        version += 1
        lastWriteAt = nowMs
        writer.write(version) { encoder(snap) }
    }

    private fun cancelDebounce() {
        debounce?.cancel()
        debounce = null
        debounceArmed = false
    }

    private fun JsonObject.hasExactSchema(): Boolean {
        val v = this["schemaVersion"] as? JsonPrimitive ?: return false
        return runCatching { v.int }.getOrNull() == MIX_DECK_SESSION_SCHEMA_VERSION
    }

    companion object {
        const val FILE_NAME = "pocketdj-mix-decks.json"
        const val SLOT_COUNT = FxRack.SLOT_COUNT

        fun encode(snap: MixDeckSnapshot): String = PdjJson.lenient.encodeToString(snap)
    }
}
