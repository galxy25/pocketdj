package com.levi.pocketdj.data.collections

import java.util.UUID
import kotlin.math.abs
import kotlin.math.floor
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonPrimitive

/**
 * Collections document models — pockets / playlists / setlists / folders — the
 * Android mirror of iOS `Models/CollectionsSchema.swift` (specs/collections-schema.md).
 *
 * SHAPE-COMPATIBILITY LAW: field NAMES + semantics are verbatim iOS so a future
 * S3 cross-device sync can merge Android and iOS documents; ids travel verbatim.
 * Iron law (additive-optional): every non-identity field decodes leniently with a
 * default; adding a field later must never wipe a saved doc.
 *
 * The two structural insurances (spec §4) live in [CollectionsCodec] /
 * [PlaylistSerializer] / [PlaylistNodeSerializer]: lossy per-element decode for
 * playlists/nodes, and required-`kind`/`nodeId` with NO defaults so an unknown
 * node kind FAILS (and drops) instead of silently coercing to a known kind.
 */

/** Current document schema version (iOS `collectionsSchemaVersion`). */
const val COLLECTIONS_SCHEMA_VERSION = 7

/**
 * Reserved "Now Playing" identifiers — the single reusable ▶ Play / 🔀 Shuffle
 * setlist (upserted last-writer-wins, hidden from all listings, purged at launch).
 */
const val NOW_PLAYING_SETLIST_ID = "set_now_playing"
const val NOW_PLAYING_PLAYLIST_ID = "pls_now_playing"

/**
 * Epoch-ms timestamps ride JSON as plain numbers (iOS encodes `Double`). Encode
 * integral values as integers (`1750000000000`, matching iOS output) instead of
 * Kotlin's `1.75E12` exponent form; decode accepts any JSON number.
 */
object EpochMsSerializer : KSerializer<Double> {
    override val descriptor = PrimitiveSerialDescriptor("EpochMs", PrimitiveKind.DOUBLE)
    override fun deserialize(decoder: Decoder): Double = decoder.decodeDouble()
    override fun serialize(encoder: Encoder, value: Double) {
        val json = encoder as? JsonEncoder
        if (json != null && value.isFinite() && value == floor(value) && abs(value) < MAX_SAFE_INTEGER) {
            json.encodeJsonElement(JsonPrimitive(value.toLong()))
        } else {
            encoder.encodeDouble(value)
        }
    }

    /** JS Number.MAX_SAFE_INTEGER — the PWA reads these documents too. */
    private const val MAX_SAFE_INTEGER = 9_007_199_254_740_991.0
}

/** Integral epoch-ms JsonPrimitive for the hand-written serializers. */
internal fun epochMsPrimitive(value: Double): JsonPrimitive =
    if (value.isFinite() && value == floor(value) && abs(value) < 9_007_199_254_740_991.0) {
        JsonPrimitive(value.toLong())
    } else {
        JsonPrimitive(value)
    }

/** Pocket kind — raw tokens are persisted, never rename. Unknown coerces to harmonic. */
@Serializable
enum class PocketKind {
    @SerialName("harmonic")
    HARMONIC,

    @SerialName("performance")
    PERFORMANCE,
}

/**
 * A free-text item inside a pocket. `position` is the note's slot in the pocket's
 * UNIFIED member ordering (children, albums, songs, notes as one list).
 */
@Serializable
data class PocketNote(
    val id: String = CollectionsFactory.newPocketNoteId(),
    val text: String = "",
    val position: Int = 0,
)

/**
 * A reusable, nestable grouping — membership is type-agnostic (songs + albums +
 * child pockets + free-text notes), forming a cycle-guarded DAG. All fields
 * lenient with defaults (a missing `id` mints a fresh one), like iOS.
 */
@Serializable
data class Pocket(
    val id: String = CollectionsFactory.newPocketId(),
    override val name: String = "",
    val kind: PocketKind = PocketKind.HARMONIC,
    val description: String? = null,
    /** Ordered, SET-LIKE (adds dedupe). Studio ids ride here verbatim. */
    val songIds: List<String> = emptyList(),
    val albumIds: List<String> = emptyList(),
    /** The DAG edges — cycle-guarded on add. */
    val childPocketIds: List<String> = emptyList(),
    /** v2: ordered free-text items (never counted as members). */
    val notes: List<PocketNote> = emptyList(),
    /** v4: nil = top level. */
    val folderId: String? = null,
    /** Per-song loop-count sidecar, keyed by songId (membership is set-like). */
    val songRepeats: Map<String, Int> = emptyMap(),
    // v6 source provenance — all nil ⇒ hand-made.
    val sourcePlaylistId: String? = null,
    val sourceName: String? = null,
    /** Three-way-merge base snapshot of the source membership. */
    val sourceSongIds: List<String>? = null,
    /** nil ⇒ enabled. */
    val sourceSyncEnabled: Boolean? = null,
    @Serializable(with = EpochMsSerializer::class)
    val sourceSyncedAt: Double? = null,
    /** v7: stamped by markPlayed OUTSIDE mutate — never disturbs updatedAt. */
    @Serializable(with = EpochMsSerializer::class)
    override val lastPlayedAt: Double? = null,
    @Serializable(with = EpochMsSerializer::class)
    val createdAt: Double = 0.0,
    @Serializable(with = EpochMsSerializer::class)
    override val updatedAt: Double = 0.0,
) : CollectionSortable {
    /** Notes never count toward members (count/runtime). */
    val memberCount: Int get() = songIds.size + albumIds.size + childPocketIds.size
    val isEmptyPocket: Boolean
        get() = songIds.isEmpty() && albumIds.isEmpty() && childPocketIds.isEmpty() && notes.isEmpty()
    val hasSource: Boolean get() = sourcePlaylistId != null
    val syncsWithSource: Boolean get() = hasSource && (sourceSyncEnabled ?: true)
}

/**
 * The one place the repeat-count convention lives (iOS `CollectionMembership`):
 * a `repeatCount` is the TOTAL number of plays before advance.
 */
object CollectionMembership {
    const val MAX_REPEAT = 99

    /** Normalize a stored (optional, possibly out-of-range) repeat to a play count ≥ 1. */
    fun normalizedRepeat(raw: Int?): Int {
        if (raw == null) return 1
        return raw.coerceIn(1, MAX_REPEAT)
    }

    /** The value to PERSIST: null for ≤ 1 (keeps the key off the wire), else clamped. */
    fun storedRepeat(count: Int): Int? {
        val n = count.coerceIn(1, MAX_REPEAT)
        return if (n <= 1) null else n
    }
}

/**
 * A node in a playlist template — flat, `kind`-discriminated, recursive.
 * Decoded by [PlaylistNodeSerializer]: `nodeId` + `kind` are REQUIRED (a missing
 * one, or an UNKNOWN `kind` string, throws so the enclosing lossy array drops
 * just this node — never map an unknown kind to a default).
 */
@Serializable(with = PlaylistNodeSerializer::class)
data class PlaylistNode(
    val nodeId: String,
    val kind: Kind,
    // Leaf refs — exactly one set, per kind.
    val songId: String? = null,
    val albumId: String? = null,
    val pocketId: String? = null,
    val text: String? = null,
    // Sequence (chapter) fields.
    val name: String? = null,
    /** Realize budget for this chapter (ms). */
    val targetMs: Long? = null,
    val children: List<PlaylistNode>? = null,
    // Shared.
    /** Performer cue. */
    val note: String? = null,
    /** Total plays before advance; null/absent ⇒ once. */
    val repeatCount: Int? = null,
) {
    /** Raw tokens are persisted — never rename. */
    enum class Kind(val token: String) {
        SONG("song"),
        ALBUM("album"),
        POCKET("pocket"),
        TEXT("text"),
        SEQUENCE("sequence"),
        ;

        companion object {
            fun fromToken(token: String): Kind? = entries.firstOrNull { it.token == token }
        }
    }
}

/** A flat, named group; membership lives on the member's `folderId`. */
@Serializable
data class PlaylistFolder(
    val id: String = CollectionsFactory.newFolderId(),
    val name: String = "",
    @Serializable(with = EpochMsSerializer::class)
    val createdAt: Double = 0.0,
    @Serializable(with = EpochMsSerializer::class)
    val updatedAt: Double = 0.0,
)

/**
 * A playlist template: ordered chapters (every entry a `.sequence` node);
 * `sequences[0]` is the default chapter. Decoded by [PlaylistSerializer]:
 * `id`/`name`/`sequences`/`createdAt`/`updatedAt` are REQUIRED — a playlist
 * missing one is dropped by the document's lossy `[Playlist]` (that playlist
 * only, never the list).
 */
@Serializable(with = PlaylistSerializer::class)
data class Playlist(
    val id: String,
    override val name: String,
    val description: String? = null,
    val sequences: List<PlaylistNode>,
    val targetMs: Long? = null,
    /** v3: nil = top level. */
    val folderId: String? = null,
    // v6 source provenance — same names + semantics as Pocket's.
    val sourcePlaylistId: String? = null,
    val sourceName: String? = null,
    val sourceSongIds: List<String>? = null,
    val sourceSyncEnabled: Boolean? = null,
    val sourceSyncedAt: Double? = null,
    /** v7 "Recently played" key — stamped OUTSIDE mutate. */
    override val lastPlayedAt: Double? = null,
    val createdAt: Double = 0.0,
    override val updatedAt: Double = 0.0,
) : CollectionSortable {
    val hasSource: Boolean get() = sourcePlaylistId != null
    val syncsWithSource: Boolean get() = hasSource && (sourceSyncEnabled ?: true)
}

/** How a track ended up in a setlist. Raw tokens persisted — never rename. */
@Serializable
enum class TrackSource {
    @SerialName("explicit")
    EXPLICIT,

    @SerialName("pocket")
    POCKET,

    @SerialName("autofill")
    AUTOFILL,
}

/**
 * DEFERRED / reserved seam (carried-but-inert on Android): a ranked "mix it
 * with" candidate. The shape exists so lighting it up needs no migration.
 */
@Serializable
data class MixSuggestion(
    val songId: String = "",
    val artist: String = "",
    val name: String = "",
    val bpm: Double? = null,
    val camelot: String? = null,
    val lengthMs: Long? = null,
    /** "pocket" | "bpm-key" */
    val basis: String? = null,
    val pocketId: String? = null,
    val score: Double? = null,
)

/**
 * One frozen track in a setlist — SNAPSHOTTED (artist/name/bpm/camelot/length
 * inline) so the setlist reads standalone after catalog/pocket changes.
 */
@Serializable
data class SetlistTrack(
    /** `""` for pure text (cue) rows. */
    val songId: String = "",
    val artist: String = "",
    val name: String = "",
    val bpm: Double? = null,
    val camelot: String? = null,
    val lengthMs: Long? = null,
    val source: TrackSource = TrackSource.EXPLICIT,
    val sequenceName: String? = null,
    val note: String? = null,
    /** true = free-text cue, no backing item / audio. */
    val isText: Boolean? = null,
    /** Set when [source] == [TrackSource.POCKET]. */
    val pocketId: String? = null,
    /** DEFERRED — carried through untouched. */
    val mixSuggestions: List<MixSuggestion>? = null,
    /** Frozen loop count; null ⇒ once. */
    val repeatCount: Int? = null,
) {
    /**
     * Length of ONE play (the player's per-track end boundary): 0 for text rows,
     * else lengthMs when > 0, else the engine's 210 s default.
     */
    val perPlayMs: Long
        get() {
            if (isText == true) return 0
            val l = lengthMs
            return if (l != null && l > 0) l else RealizeEngine.DEFAULT_TRACK_MS
        }

    /** Duration a row contributes to TOTALS — one play × the repeat count. */
    val shownMs: Long get() = perPlayMs * CollectionMembership.normalizedRepeat(repeatCount)

    /** Row identity for UI lists — songId may repeat (cues/blanks). */
    val rowId: String get() = "$songId#$name"
}

/** A persisted performance instance produced by ▶ Play. All fields lenient. */
@Serializable
data class Setlist(
    val id: String = CollectionsFactory.newSetlistId(),
    val playlistId: String = "",
    val name: String? = null,
    /** Re-running realize with this seed reproduces the setlist. */
    val seed: String = playlistId,
    @Serializable(with = EpochMsSerializer::class)
    val generatedAt: Double = 0.0,
    val totalMs: Long = 0,
    val tracks: List<SetlistTrack> = emptyList(),
)

/**
 * A remembered "Add to…" target. `kind`/`id` are required (an undecodable target
 * is absorbed at the document level); `sequenceId` only for playlists.
 */
@Serializable
data class AddTarget(
    val kind: Kind,
    val id: String,
    val sequenceId: String? = null,
) {
    /** Raw tokens persisted — never rename. */
    @Serializable
    enum class Kind(val token: String) {
        @SerialName("pocket")
        POCKET("pocket"),

        @SerialName("playlist")
        PLAYLIST("playlist"),
    }
}

/**
 * The on-disk envelope (`pocketdj-collections.json`). Encoding uses this plain
 * serializable shape (PdjJson omits null optionals, matching iOS's absent-key
 * output); DECODING must go through [CollectionsCodec.decode] for field-level
 * leniency + the lossy playlist list + migration.
 */
@Serializable
data class CollectionsDocument(
    val schemaVersion: Int = COLLECTIONS_SCHEMA_VERSION,
    val pockets: List<Pocket> = emptyList(),
    val playlists: List<Playlist> = emptyList(),
    val setlists: List<Setlist> = emptyList(),
    val folders: List<PlaylistFolder> = emptyList(),
    val lastAddTarget: AddTarget? = null,
    /** MRU, most-recent first; absent (null) when empty. */
    val recentAddTargets: List<AddTarget>? = null,
)

/** Id factories — `prefix + lowercase UUID`, verbatim iOS prefixes. */
object CollectionsFactory {
    fun uid(): String = UUID.randomUUID().toString().lowercase()

    fun newPocketId(): String = "pkt_" + uid()
    fun newPlaylistId(): String = "pls_" + uid()
    fun newSetlistId(): String = "set_" + uid()
    fun newNodeId(): String = "nd_" + uid()
    fun newPocketNoteId(): String = "pnt_" + uid()
    fun newFolderId(): String = "fld_" + uid()

    fun makeSequence(name: String, targetMs: Long? = null): PlaylistNode =
        PlaylistNode(
            nodeId = newNodeId(),
            kind = PlaylistNode.Kind.SEQUENCE,
            name = name,
            targetMs = targetMs,
            children = emptyList(),
        )

    fun makePocket(name: String, kind: PocketKind = PocketKind.HARMONIC, now: Double): Pocket =
        Pocket(id = newPocketId(), name = name, kind = kind, createdAt = now, updatedAt = now)

    /** A new playlist gets ONE chapter named "Default" (`sequences[0]`). */
    fun makePlaylist(name: String, now: Double): Playlist =
        Playlist(
            id = newPlaylistId(),
            name = name,
            sequences = listOf(makeSequence("Default")),
            createdAt = now,
            updatedAt = now,
        )
}

/**
 * The fields the user-selectable collection sort needs from a listable
 * collection. Playlists + pockets conform directly; read-only source playlists
 * sort with neutral keys (see [CollectionSortOrder.sortedSourcePlaylists]).
 */
interface CollectionSortable {
    val name: String
    val updatedAt: Double
    val lastPlayedAt: Double?
}
