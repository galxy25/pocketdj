package com.levi.pocketdj.data.games.inthepocket

import com.levi.pocketdj.data.pockets.ListeningContextTag
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.UUID
import kotlin.math.floor

// ─────────────────────────────────────────────────────────────────────────────────────────────
// IN THE POCKET — the game's value types (port of InThePocketModels.swift). A ROUND is a
// prediction ("these 3–4 songs, right now, here, will play through without a skip") plus what
// happened and the player's optional rating / feedback. Context is OPAQUE: a time-of-day bucket,
// weekday/weekend and — only while places & trips is on — a `plc_`/`trp_` id.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/** Swift `.rounded()` (half away from zero). */
internal fun roundHalfAway(x: Double): Double = if (x >= 0) floor(x + 0.5) else -floor(-x + 0.5)

/** `(x * 1000).rounded() / 1000`. */
internal fun round3(x: Double): Double = roundHalfAway(x * 1000) / 1000

/** The context a round is built for: the SAME buckets the cloud analysis uses (params.mjs). */
@Serializable
data class InThePocketContext(
    /** night | morning | midday | afternoon | evening */
    val timeBucket: String,
    /** weekday | weekend */
    val dayType: String,
    /** 0 = Sunday … 6 = Saturday (local). */
    val dow: Int,
    /** Current place or trip (a guess), only while places & trips is on. null = time only. */
    val ctx: ListeningContextTag? = null,
) {
    /** `place:<id>` / `trip:<id>` / null — the cloud's `ctxKeyOf`. */
    val ctxKey: String?
        get() {
            val c = ctx ?: return null
            if (c.isTrip) c.tripId?.let { return "trip:$it" }
            if (c.isPlace) c.placeId?.let { return "place:$it" }
            return null
        }

    /** The round-learning context keys, most specific first (`learnFromRounds`). */
    val learningKeys: List<String>
        get() {
            val relaxed = "$dayType|$timeBucket|*"
            ctxKey?.let { return listOf("$dayType|$timeBucket|$it", relaxed) }
            return listOf(relaxed)
        }

    /** "Weekday evening". */
    val timePhrase: String get() = dayType.replaceFirstChar { it.uppercase() } + " " + timeBucket

    companion object {
        /** [name, startHour, endHour) in LOCAL time; a start after the end wraps midnight. */
        val timeBuckets: List<Triple<String, Double, Double>> = listOf(
            Triple("night", 22.0, 5.0), Triple("morning", 5.0, 10.0), Triple("midday", 10.0, 14.0),
            Triple("afternoon", 14.0, 18.0), Triple("evening", 18.0, 22.0),
        )

        fun timeBucket(hour: Double): String {
            for ((name, start, end) in timeBuckets) {
                val inside = if (start < end) hour >= start && hour < end else hour >= start || hour < end
                if (inside) return name
            }
            return "night"
        }

        /** Local calendar facts for an instant in a UTC offset (minutes) — the cloud's `localTimeOf`. */
        fun make(atMs: Double, tzOffsetMin: Int, ctx: ListeningContextTag?): InThePocketContext {
            val localSec = atMs / 1000 + tzOffsetMin * 60.0
            val daySec = localSec.rem(86_400.0)
            val secOfDay = if (daySec < 0) daySec + 86_400 else daySec
            val hour = secOfDay / 3600
            // 1970-01-01 was a Thursday (4).
            val days = floor(localSec / 86_400).toLong()
            val dow = (((days % 7) + 7 + 4) % 7).toInt()
            return InThePocketContext(
                timeBucket = timeBucket(hour),
                dayType = if (dow == 0 || dow == 6) "weekend" else "weekday",
                dow = dow,
                ctx = ctx?.takeIf { it.isPlace || it.isTrip },
            )
        }
    }
}

/** One thing the scorer aimed at: a categorical feature value or a numeric band. */
@Serializable
data class InThePocketTarget(
    val dim: String,
    val value: String,
    /** Display text ("Funk", "118–126 BPM"). Never uploaded. */
    val label: String,
    val weight: Double,
)

/** How a round's songs were chosen. Raw values are the persisted/wire tokens. */
@Serializable
enum class InThePocketMode {
    @kotlinx.serialization.SerialName("cloud") CLOUD,
    @kotlinx.serialization.SerialName("history") HISTORY,
    @kotlinx.serialization.SerialName("cold") COLD;

    val raw: String get() = name.lowercase()
}

/** What happened to one song of a round (persisted tokens match iOS case names). */
@Serializable
enum class InThePocketSongState {
    @kotlinx.serialization.SerialName("pending") PENDING,
    @kotlinx.serialization.SerialName("playing") PLAYING,
    @kotlinx.serialization.SerialName("completed") COMPLETED,
    @kotlinx.serialization.SerialName("skipped") SKIPPED,
    @kotlinx.serialization.SerialName("notPlayed") NOT_PLAYED,
}

/** The round's verdict. Persisted as `{"outcome":"broke","brokeAt":2}` (the iOS Codable shape). */
@Serializable(with = InThePocketOutcomeSerializer::class)
sealed class InThePocketOutcome {
    abstract val token: String
    open val brokeAt: Int? get() = null

    /** Every song played through, no skip. */
    data object Pocket : InThePocketOutcome() { override val token get() = "pocket" }

    /** The first skip, 1-based ("Broke at song 2"). */
    data class Broke(val at: Int) : InThePocketOutcome() {
        override val token get() = "broke"
        override val brokeAt: Int get() = at
    }

    /** The player moved on (something else played, the set stopped, or it timed out). */
    data object Abandoned : InThePocketOutcome() { override val token get() = "abandoned" }

    fun toJson(): JsonObject = JsonObject(buildMap {
        put("outcome", JsonPrimitive(token))
        brokeAt?.let { put("brokeAt", JsonPrimitive(it)) }
    })

    companion object {
        /** Unknown tokens read as abandoned; a `broke` without a usable `brokeAt` is song 1. */
        fun fromJson(e: JsonElement): InThePocketOutcome {
            val o = e as? JsonObject ?: return Abandoned
            return when ((o["outcome"] as? JsonPrimitive)?.takeIf { it.isString }?.content) {
                "pocket" -> Pocket
                "broke" -> Broke(
                    (o["brokeAt"] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toDoubleOrNull()
                        ?.takeIf { it == Math.floor(it) && it >= Int.MIN_VALUE && it <= Int.MAX_VALUE }?.toInt() ?: 1,
                )
                else -> Abandoned
            }
        }
    }
}

object InThePocketOutcomeSerializer : KSerializer<InThePocketOutcome> {
    override val descriptor: SerialDescriptor =
        kotlinx.serialization.json.JsonElement.serializer().descriptor
    override fun serialize(encoder: Encoder, value: InThePocketOutcome) {
        encoder.encodeSerializableValue(JsonElement.serializer(), value.toJson())
    }
    override fun deserialize(decoder: Decoder): InThePocketOutcome =
        InThePocketOutcome.fromJson(decoder.decodeSerializableValue(JsonElement.serializer()))
}

/** `UUID` as the uppercase string Swift writes; reads either case. */
object UuidStringSerializer : KSerializer<UUID> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("UUID", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: UUID) = encoder.encodeString(value.toString().uppercase())
    override fun deserialize(decoder: Decoder): UUID = UUID.fromString(decoder.decodeString())
}

/** One song as the round holds it. */
@Serializable
data class InThePocketSong(
    /** song id (base) */
    val id: String,
    val title: String,
    val artist: String,
    val lengthMs: Int? = null,
    /** The scorer's score for it (uploaded — "how sure was the prediction"). */
    val score: Double,
    /** Why it was picked ("Funk · 121 BPM"). */
    val why: List<String> = emptyList(),
    val state: InThePocketSongState = InThePocketSongState.PENDING,
    @Serializable(with = UuidStringSerializer::class) val eventId: UUID? = null,
    val fraction: Double? = null,
)

/** A whole round — persisted locally (`pocketdj-in-the-pocket.json`) and uploaded as training data. */
@Serializable
data class InThePocketRound(
    @Serializable(with = UuidStringSerializer::class) val id: UUID,
    val createdAtMs: Double,
    /** When ▶ was pressed (null = built but not started). */
    val startedAtMs: Double? = null,
    val endedAtMs: Double? = null,
    /** Bumped on every change (feedback, rating, outcome) — the server keeps the newest copy. */
    val updatedAtMs: Double,
    val tzOffsetMin: Int,
    val context: InThePocketContext,
    /** Human label of `context.ctx` at build time. Never uploaded. */
    val contextLabel: String? = null,
    val mode: InThePocketMode,
    /** UInt64 seed, as a decimal string (JSON numbers can't carry 64 bits). */
    val seed: String,
    val algoVersion: Int? = null,
    val targets: List<InThePocketTarget>,
    val songs: List<InThePocketSong>,
    val outcome: InThePocketOutcome? = null,
    /** 1…5, optional. */
    val rating: Int? = null,
    /** Free text (typed or dictated), capped at [MAX_FEEDBACK_CHARS]. */
    val feedback: String? = null,
    val appVersion: String? = null,
) {
    val isFinished: Boolean get() = outcome != null
    val isActive: Boolean get() = startedAtMs != null && outcome == null

    /** The upload row (`POST /pockets/rounds`, rounds.v1). Only FINISHED, STARTED rounds upload. */
    fun wire(installId: String): InThePocketRoundWire? {
        val outcome = outcome ?: return null
        val started = startedAtMs ?: return null
        return InThePocketRoundWire(
            id = id.toString().uppercase(), originInstallId = installId,
            startedAtMs = flooredMinute(started), endedAtMs = endedAtMs?.let { flooredMinute(it) },
            updatedAtMs = updatedAtMs.toLong(), tzOffsetMin = tzOffsetMin,
            context = InThePocketRoundWire.Context(context.timeBucket, context.dayType, context.dow, context.ctx),
            mode = mode.raw, seed = seed, algoVersion = algoVersion,
            targets = targets.map { InThePocketRoundWire.Target(it.dim, it.value, round3(it.weight)) },
            songs = songs.map {
                InThePocketRoundWire.Song(it.id, it.artist, round3(it.score), wireSongOutcome(it), it.fraction?.let(::round3))
            },
            outcome = outcome.token, brokeAt = outcome.brokeAt, rating = rating,
            feedback = capFeedback(feedback), appVersion = appVersion,
        )
    }

    companion object {
        const val MAX_FEEDBACK_CHARS = 2000

        /**
         * Free text → stored: trimmed, capped at [MAX_FEEDBACK_CHARS] UTF-16 units without
         * splitting a surrogate pair (the server's `capText` applies the same cap), empty → null.
         */
        fun capFeedback(text: String?): String? {
            val trimmed = text?.trim() ?: return null
            if (trimmed.isEmpty()) return null
            if (trimmed.length <= MAX_FEEDBACK_CHARS) return trimmed
            var cut = MAX_FEEDBACK_CHARS
            if (Character.isHighSurrogate(trimmed[cut - 1])) cut -= 1
            return trimmed.substring(0, cut)
        }

        /** Coarse time on the wire (the `ListeningPocketsService.flooredMinute` rule). */
        fun flooredMinute(ms: Double): Long = floor(ms / 60_000).toLong() * 60_000

        private fun wireSongOutcome(s: InThePocketSong): String = when (s.state) {
            InThePocketSongState.COMPLETED -> "completed"
            InThePocketSongState.SKIPPED -> "skipped"
            InThePocketSongState.NOT_PLAYED, InThePocketSongState.PENDING -> "notPlayed"
            InThePocketSongState.PLAYING -> if ((s.fraction ?: 0.0) >= 0.5) "completed" else "partial"
        }
    }
}

/** `POST /pockets/rounds` body. */
data class InThePocketRoundsBatch(
    val deviceId: String?,
    val installId: String,
    val sentAtMs: Long,
    val rounds: List<InThePocketRoundWire>,
    val v: Int = 1,
) {
    fun toJson(): JsonObject = JsonObject(buildMap {
        put("v", JsonPrimitive(v))
        deviceId?.let { put("deviceId", JsonPrimitive(it)) }
        put("installId", JsonPrimitive(installId))
        put("sentAtMs", JsonPrimitive(sentAtMs))
        put("rounds", JsonArray(rounds.map { it.toJson() }))
    })
}

/** One round on the wire (`cleanRound` on the server). Nullable fields encode explicit `null`. */
data class InThePocketRoundWire(
    val id: String,
    val originInstallId: String,
    val startedAtMs: Long,
    val endedAtMs: Long?,
    val updatedAtMs: Long,
    val tzOffsetMin: Int,
    val context: Context,
    val mode: String,
    val seed: String,
    val algoVersion: Int?,
    val targets: List<Target>,
    val songs: List<Song>,
    val outcome: String,
    val brokeAt: Int?,
    val rating: Int?,
    val feedback: String?,
    val appVersion: String?,
) {
    data class Context(val timeBucket: String, val dayType: String, val dow: Int, val ctx: ListeningContextTag?) {
        fun toJson() = JsonObject(mapOf(
            "timeBucket" to JsonPrimitive(timeBucket), "dayType" to JsonPrimitive(dayType),
            "dow" to JsonPrimitive(dow), "ctx" to (ctx?.toJson() ?: JsonNull),
        ))
    }

    data class Target(val dim: String, val value: String, val weight: Double) {
        fun toJson() = JsonObject(mapOf(
            "dim" to JsonPrimitive(dim), "value" to JsonPrimitive(value), "weight" to JsonPrimitive(weight),
        ))
    }

    data class Song(val songId: String, val artist: String?, val score: Double, val outcome: String, val fraction: Double?) {
        fun toJson() = JsonObject(mapOf(
            "songId" to JsonPrimitive(songId), "artist" to nullable(artist), "score" to JsonPrimitive(score),
            "outcome" to JsonPrimitive(outcome), "fraction" to nullable(fraction),
        ))
    }

    /** Explicit nulls present, in the server's `cleanRound` field order. */
    fun toJson(): JsonObject = JsonObject(linkedMapOf(
        "id" to JsonPrimitive(id),
        "originInstallId" to JsonPrimitive(originInstallId),
        "startedAtMs" to JsonPrimitive(startedAtMs),
        "endedAtMs" to nullable(endedAtMs),
        "updatedAtMs" to JsonPrimitive(updatedAtMs),
        "tzOffsetMin" to JsonPrimitive(tzOffsetMin),
        "context" to context.toJson(),
        "mode" to JsonPrimitive(mode),
        "seed" to JsonPrimitive(seed),
        "algoVersion" to nullable(algoVersion),
        "targets" to JsonArray(targets.map { it.toJson() }),
        "songs" to JsonArray(songs.map { it.toJson() }),
        "outcome" to JsonPrimitive(outcome),
        "brokeAt" to nullable(brokeAt),
        "rating" to nullable(rating),
        "feedback" to nullable(feedback),
        "appVersion" to nullable(appVersion),
    ))

    /** Everything that can CHANGE after the first upload — a moved fingerprint re-sends. */
    val fingerprint: String
        get() = "$updatedAtMs|$outcome|${brokeAt ?: 0}|${rating ?: 0}|" +
            "${feedback?.let { it.codePointCount(0, it.length) } ?: 0}|" +
            songs.joinToString(",") { "${it.outcome}${roundHalfAway((it.fraction ?: 0.0) * 100).toInt()}" }
}

private fun nullable(v: Any?): JsonElement = when (v) {
    null -> JsonNull
    is String -> JsonPrimitive(v)
    is Number -> JsonPrimitive(v)
    is Boolean -> JsonPrimitive(v)
    else -> error("unsupported wire value")
}
