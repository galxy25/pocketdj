package com.levi.pocketdj.playback.durable

import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/** iOS `NPMixModeState`: the flag only (buffers are per device). */
@Serializable
data class SessionNpMixMode(
    val enabled: Boolean = false,
    @Transient val unknownKeys: JsonObject = JsonObject(emptyMap()),
)

/** iOS `FXLockState.Setting`: one carried effect. */
@Serializable
data class SessionFxSetting(
    val on: Boolean = false,
    val strength: Double = 0.0,
    @Transient val unknownKeys: JsonObject = JsonObject(emptyMap()),
)

/** iOS `FXLockState`: [effects] is keyed by the raw effect name; keys a newer build added are kept verbatim. */
@Serializable
data class SessionFxLock(
    val enabled: Boolean = false,
    val effects: Map<String, SessionFxSetting> = emptyMap(),
    @Transient val unknownKeys: JsonObject = JsonObject(emptyMap()),
)

/**
 * iOS `DJModeState`. [planner] stays a raw [JsonObject] until the planner decodes it (P2-DJ-10), so its
 * UInt64 `seed` (>= 2^63) survives as the original JSON number literal.
 */
@Serializable
data class SessionDjMode(
    val enabled: Boolean = false,
    val planner: JsonObject? = null,
    @Transient val unknownKeys: JsonObject = JsonObject(emptyMap()),
)

/** iOS `SetlistPlayer.PlanTag` (Pocket Wheel run provenance on a row). [runId] is the UUID string. */
@Serializable
data class SessionPlanTag(
    val runId: String,
    val slot: Int,
    val collectionId: String? = null,
    val score: Double = 0.0,
    val pinned: Boolean = false,
    @Transient val unknownKeys: JsonObject = JsonObject(emptyMap()),
)

/**
 * The session-scoped optional state the store carries between writes: the typed iOS fields plus every
 * top-level key this build does not know. A later package reads/writes it through
 * [PlaybackSessionStore.extras]; a snapshot saved without these fields inherits them, so an Android write
 * never erases what iOS put there. Nothing here is armed or applied by the store (restore is HELD).
 */
data class SnapshotExtras(
    val npMixMode: SessionNpMixMode? = null,
    val fxLock: SessionFxLock? = null,
    val djMode: SessionDjMode? = null,
    val unknownKeys: JsonObject = JsonObject(emptyMap()),
    /** The session these extras came from; extras never overlay a different session. */
    val sessionId: String? = null,
    /** The previous rows, whose iOS-only row fields (plan, appleMusicId, djUserNext, djPlaced, unknown keys) are carried. */
    val rows: List<SessionRow> = emptyList(),
    val sourceUnknownKeys: JsonObject = JsonObject(emptyMap()),
    val stemLockUnknownKeys: JsonObject = JsonObject(emptyMap()),
) {
    /**
     * [snap] with every absent field filled from this (the snapshot's own non-null value wins). Rows are
     * matched by songId (the n-th occurrence of an id takes the n-th previous row with that id), so a
     * reorder or edit of the queue cannot hand one row another row's keys.
     */
    fun overlay(snap: SessionSnapshot): SessionSnapshot {
        val prev = HashMap<String, ArrayDeque<SessionRow>>()
        rows.forEach { prev.getOrPut(it.songId) { ArrayDeque() }.addLast(it) }
        val queue = snap.queue.map { r ->
            val p = prev[r.songId]?.removeFirstOrNull() ?: return@map r
            r.copy(
                plan = r.plan ?: p.plan,
                appleMusicId = r.appleMusicId ?: p.appleMusicId,
                djUserNext = r.djUserNext ?: p.djUserNext,
                djPlaced = r.djPlaced ?: p.djPlaced,
                unknownKeys = JsonObject(p.unknownKeys + r.unknownKeys),
            )
        }
        return snap.copy(
            queue = queue,
            source = snap.source.copy(unknownKeys = JsonObject(sourceUnknownKeys + snap.source.unknownKeys)),
            stemLock = snap.stemLock?.let { it.copy(unknownKeys = JsonObject(stemLockUnknownKeys + it.unknownKeys)) },
            npMixMode = snap.npMixMode ?: npMixMode,
            fxLock = snap.fxLock ?: fxLock,
            djMode = snap.djMode ?: djMode,
            unknownKeys = JsonObject(unknownKeys + snap.unknownKeys),
        )
    }

    companion object {
        fun of(snap: SessionSnapshot) = SnapshotExtras(
            snap.npMixMode, snap.fxLock, snap.djMode, snap.unknownKeys, snap.sessionId, snap.queue,
            snap.source.unknownKeys, snap.stemLock?.unknownKeys ?: JsonObject(emptyMap()),
        )
    }
}

/** Keys of [this] that are not in [known]. */
internal fun JsonObject.unknownTo(known: Set<String>): JsonObject =
    JsonObject(filterKeys { it !in known })

/** [this] plus [extra]'s keys appended; keys already present win (a passthrough never overrides a typed value). */
internal fun JsonObject.mergedAfter(extra: JsonObject): JsonObject =
    if (extra.isEmpty()) this else JsonObject(LinkedHashMap<String, JsonElement>(this).also { m ->
        extra.forEach { (k, v) -> m.putIfAbsent(k, v) }
    })

/**
 * Unknown-key passthrough for the synced `playback-session` document. kotlinx cannot keep unknown keys
 * inside a typed class, so [attach] re-reads the raw JSON after the typed decode and records, per object,
 * the keys this build does not model; [merge] puts them back after the typed encode.
 */
internal object SnapshotCodec {
    private val TOP = setOf(
        "schemaVersion", "sessionId", "source", "queue", "index", "positionMs", "isPlaying", "repeatMode",
        "shuffleEnabled", "stemLock", "npMixMode", "fxLock", "djMode", "updatedAt",
    )
    private val ROW = setOf(
        "songId", "title", "artist", "lengthMs", "repeatCount", "variant", "editionLocked", "resolveId",
        "cleanOnlySkip", "plan", "appleMusicId", "djPlaced", "djUserNext",
    )
    private val SOURCE = setOf("kind", "id", "name", "originKind", "originId")
    private val STEM = setOf("enabled", "stemsOn", "muted", "volumes")
    private val PLAN = setOf("runId", "slot", "collectionId", "score", "pinned")
    private val ENABLED = setOf("enabled")
    private val FX = setOf("enabled", "effects")
    private val FX_SETTING = setOf("on", "strength")
    private val DJ = setOf("enabled", "planner")

    private fun JsonElement?.obj(): JsonObject? = this as? JsonObject

    fun attach(typed: SessionSnapshot, root: JsonObject): SessionSnapshot {
        val rawRows = (root["queue"] as? kotlinx.serialization.json.JsonArray) ?: emptyList<JsonElement>()
        return typed.copy(
            queue = typed.queue.mapIndexed { i, row ->
                val r = rawRows.getOrNull(i).obj() ?: return@mapIndexed row
                row.copy(
                    unknownKeys = r.unknownTo(ROW),
                    plan = row.plan?.copy(unknownKeys = r["plan"].obj()?.unknownTo(PLAN) ?: JsonObject(emptyMap())),
                )
            },
            source = typed.source.copy(unknownKeys = root["source"].obj()?.unknownTo(SOURCE) ?: JsonObject(emptyMap())),
            stemLock = typed.stemLock?.copy(unknownKeys = root["stemLock"].obj()?.unknownTo(STEM) ?: JsonObject(emptyMap())),
            npMixMode = typed.npMixMode?.copy(unknownKeys = root["npMixMode"].obj()?.unknownTo(ENABLED) ?: JsonObject(emptyMap())),
            fxLock = typed.fxLock?.let { fx ->
                val raw = root["fxLock"].obj()
                val rawEffects = raw?.get("effects").obj()
                fx.copy(
                    unknownKeys = raw?.unknownTo(FX) ?: JsonObject(emptyMap()),
                    effects = fx.effects.mapValues { (k, v) ->
                        v.copy(unknownKeys = rawEffects?.get(k).obj()?.unknownTo(FX_SETTING) ?: JsonObject(emptyMap()))
                    },
                )
            },
            djMode = typed.djMode?.copy(unknownKeys = root["djMode"].obj()?.unknownTo(DJ) ?: JsonObject(emptyMap())),
            unknownKeys = root.unknownTo(TOP),
        )
    }

    fun merge(typed: SessionSnapshot, encoded: JsonObject): JsonObject {
        val m = LinkedHashMap<String, JsonElement>(encoded)
        val rows = encoded["queue"] as? kotlinx.serialization.json.JsonArray
        if (rows != null && rows.size == typed.queue.size) {
            m["queue"] = kotlinx.serialization.json.JsonArray(rows.mapIndexed { i, e ->
                val row = typed.queue[i]
                var o = e as? JsonObject ?: return@mapIndexed e
                val plan = row.plan
                if (plan != null && plan.unknownKeys.isNotEmpty()) {
                    o = JsonObject(o + ("plan" to (o["plan"].obj()!!.mergedAfter(plan.unknownKeys))))
                }
                o.mergedAfter(row.unknownKeys)
            })
        }
        if (typed.source.unknownKeys.isNotEmpty()) {
            m["source"] = encoded["source"].obj()!!.mergedAfter(typed.source.unknownKeys)
        }
        typed.stemLock?.let { st ->
            if (st.unknownKeys.isNotEmpty()) m["stemLock"] = encoded["stemLock"].obj()!!.mergedAfter(st.unknownKeys)
        }
        typed.npMixMode?.let { n ->
            if (n.unknownKeys.isNotEmpty()) m["npMixMode"] = encoded["npMixMode"].obj()!!.mergedAfter(n.unknownKeys)
        }
        typed.fxLock?.let { fx ->
            val o = encoded["fxLock"].obj()!!
            val effects = o["effects"].obj()
            val mergedEffects = effects?.let { ef ->
                JsonObject(ef.mapValues { (k, v) -> v.obj()!!.mergedAfter(fx.effects[k]?.unknownKeys ?: JsonObject(emptyMap())) })
            }
            val base = if (mergedEffects != null) JsonObject(o + ("effects" to mergedEffects)) else o
            m["fxLock"] = base.mergedAfter(fx.unknownKeys)
        }
        typed.djMode?.let { d ->
            if (d.unknownKeys.isNotEmpty()) m["djMode"] = encoded["djMode"].obj()!!.mergedAfter(d.unknownKeys)
        }
        return JsonObject(m).mergedAfter(typed.unknownKeys)
    }
}
