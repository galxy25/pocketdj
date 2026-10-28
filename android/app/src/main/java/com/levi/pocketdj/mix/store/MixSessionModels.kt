package com.levi.pocketdj.mix.store

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/** On-disk schema of `pocketdj-mix-sessions.json`. v2 added optional `MixSession.recordings`. */
const val MIX_SESSIONS_SCHEMA_VERSION = 2

/**
 * The kinds of recorded mix activity. [Unknown] is the lenient-decode sink: it CARRIES the
 * original string so a newer build's kind survives a load + re-save by this build.
 */
@Serializable(with = MixEventKindSerializer::class)
sealed class MixEventKind(val raw: String) {
    object Load : MixEventKind("load")
    object Play : MixEventKind("play")
    object Pause : MixEventKind("pause")
    object Seek : MixEventKind("seek")
    object Tempo : MixEventKind("tempo")
    object Pitch : MixEventKind("pitch")
    object Volume : MixEventKind("volume")
    object Crossfader : MixEventKind("crossfader")
    object EffectToggle : MixEventKind("effectToggle")
    object EffectStrength : MixEventKind("effectStrength")
    /** 3-band EQ move; `param` = "low"/"mid"/"high". */
    object Eq : MixEventKind("eq")
    /** Superseded by [EffectVariant]; decoded only. */
    object FilterMode : MixEventKind("filterMode")
    object EffectSlot : MixEventKind("effectSlot")
    object EffectVariant : MixEventKind("effectVariant")
    object EffectMod : MixEventKind("effectMod")
    object StemMode : MixEventKind("stemMode")
    object StemMute : MixEventKind("stemMute")
    object StemVolume : MixEventKind("stemVolume")
    object Lead : MixEventKind("lead")
    object Sync : MixEventKind("sync")
    object ResetDeck : MixEventKind("resetDeck")
    object AutoPause : MixEventKind("autoPause")
    object AutoResume : MixEventKind("autoResume")
    /** Machine ramp captured as from -> to + average rate. */
    object Glide : MixEventKind("glide")
    data class Unknown(val value: String) : MixEventKind(value)

    val isUnknown: Boolean get() = this is Unknown

    /** Slider-drag kinds: coalesced to ~one event per 120 ms bucket and saved on a debounce. */
    val isContinuous: Boolean
        get() = this === Tempo || this === Pitch || this === Volume || this === Crossfader ||
            this === EffectStrength || this === StemVolume || this === Eq

    override fun toString(): String = raw

    companion object {
        val known: Map<String, MixEventKind> by lazy {
            listOf(
                Load, Play, Pause, Seek, Tempo, Pitch, Volume, Crossfader, EffectToggle,
                EffectStrength, Eq, FilterMode, EffectSlot, EffectVariant, EffectMod, StemMode,
                StemMute, StemVolume, Lead, Sync, ResetDeck, AutoPause, AutoResume, Glide,
            ).associateBy { it.raw }
        }

        fun fromRaw(raw: String): MixEventKind = known[raw] ?: Unknown(raw)
    }
}

object MixEventKindSerializer : KSerializer<MixEventKind> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("MixEventKind", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): MixEventKind = MixEventKind.fromRaw(decoder.decodeString())
    override fun serialize(encoder: Encoder, value: MixEventKind) = encoder.encodeString(value.raw)
}

/** One recorded mix action, time-stamped RELATIVE to its session's (re-anchored) start. */
@Serializable
data class MixSessionEvent(
    /** Unique within its session ("e<seq>"). */
    val id: String,
    val tMs: Int,
    val kind: MixEventKind,
    /** "A"/"B"; null = global (crossfader). */
    val deck: String? = null,
    val songId: String? = null,
    val title: String? = null,
    val artist: String? = null,
    val bpm: Double? = null,
    val camelot: String? = null,
    val param: String? = null,
    val value: Double? = null,
    val flag: Boolean? = null,
    val posMs: Int? = null,
    /** glide only: the ramp's START value (value holds the END). */
    val fromValue: Double? = null,
    /** glide only: average rate of change per second. */
    val rate: Double? = null,
    /** FX-rack events only: which of the 4 slots. */
    val slot: Int? = null,
)

/** Metadata of one captured mix-audio take (the audio lives in the session folder). */
@Serializable
data class MixRecording(
    val id: String,
    val fileName: String,
    val startedAt: Double,
    val durationMs: Int,
    val wasUserFolder: Boolean = false,
)

@Serializable
data class MixSession(
    val id: String,
    val name: String,
    /** Epoch ms: the timeline's t0 (re-anchored to first activity). */
    val startedAt: Double,
    val endedAt: Double? = null,
    val events: List<MixSessionEvent> = emptyList(),
    /** Ordered, unique. */
    val playedSongIds: List<String> = emptyList(),
    val recordings: List<MixRecording>? = null,
) {
    val recordingsList: List<MixRecording> get() = recordings ?: emptyList()

    /** Finalized -> endedAt - startedAt; else the last event's tMs. */
    val durationMs: Int
        get() = if (endedAt != null) maxOf(0, (endedAt - startedAt).toInt()) else (events.lastOrNull()?.tMs ?: 0)
}

@Serializable
data class MixSessionsDocument(
    val schemaVersion: Int = MIX_SESSIONS_SCHEMA_VERSION,
    val sessions: List<MixSession> = emptyList(),
    val currentId: String? = null,
    /** Monotonic "Session N" allocator (survives rename/delete/relaunch). */
    val counter: Int = 0,
)

/** The narrow sink the Mix engine emits into; the store owns t0/tMs, coalescing, played-set, persistence. */
interface MixSessionRecorder {
    fun logEvent(
        kind: MixEventKind, deck: String?, songId: String?, title: String?, artist: String?,
        bpm: Double?, camelot: String?, param: String?, value: Double?, flag: Boolean?,
        posMs: Int?, slot: Int? = null,
    )

    fun logGlide(
        deck: String?, param: String, songId: String?, title: String?, artist: String?,
        from: Double, to: Double, rate: Double, posMs: Int?, slot: Int? = null,
    )

    fun notePlayed(songId: String)
    fun hasPlayed(songId: String): Boolean
}
