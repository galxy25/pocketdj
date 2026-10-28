package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.studio.model.StudioFactory
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Demuxer value types (port of Studio/Demux/DemuxModels.swift). [DemuxDocument] is persisted as
 * `demux-cache/<key>.json` with the SAME keys as iOS so an iOS-cached document decodes here (optional
 * fields are the migration — decode via PdjJson.lenient).
 */
const val DEMUX_SCHEMA_VERSION = 1

/** What the Demuxer is looking at; [key] is the persistence identity. */
sealed class DemuxSource {
    abstract val key: String
    abstract val displayName: String

    data class Song(val id: String, val title: String, val artist: String) : DemuxSource() {
        override val key get() = id
        override val displayName get() = if (artist.isEmpty()) title else "$artist — $title"
    }
    data class Studio(val id: String, val name: String) : DemuxSource() {
        override val key get() = id
        override val displayName get() = name
    }
    data class ImportedFile(val id: String, val name: String) : DemuxSource() {
        override val key get() = id
        override val displayName get() = name
    }

    /** Only catalog songs can have server-side stems keyed by song id. */
    val songId: String? get() = (this as? Song)?.id

    companion object {
        /** A bare key is a CATALOG song unless it is a studio id or an imported `dmx_` file. */
        fun isSongKey(key: String): Boolean = !StudioFactory.isStudioId(key) && !key.startsWith("dmx_")

        /** Custom-audio ids the server's /stemify-custom accepts (dmx_/smp_/lp_/ptn_/tk_/slc_ + safe tail). */
        private val CUSTOM_ID = Regex("^(dmx|smp|lp|ptn|tk|slc)_[A-Za-z0-9-]{1,80}$")
        fun isCustomStemId(id: String): Boolean = CUSTOM_ID.matches(id)
    }
}

@Serializable
data class DemuxWord(val text: String, val startMs: Int, val endMs: Int)

@Serializable
data class DemuxChordSegment(
    /** Root pitch class, 0 = C ... 11 = B. */
    val rootPC: Int,
    val minor: Boolean,
    val startMs: Int,
    val endMs: Int,
    /** Mean template-match score over the segment's frames, 0...1. */
    val confidence: Double = 0.0,
) {
    private val pc: Int get() = ((rootPC % 12) + 12) % 12

    /** Chord symbol: "C", "F♯m", "B♭" ... */
    val name: String get() = NOTE_NAMES[pc] + if (minor) "m" else ""

    /** Triad pitch classes (root, third, fifth). */
    val pitchClasses: List<Int> get() = listOf(pc, (pc + if (minor) 3 else 4) % 12, (pc + 7) % 12)

    /** Close-position triad rooted in the octave starting at [base] (treble C4 = 60; 48 for bass). */
    fun midiNotes(base: Int = 60): List<Int> {
        val r = base + (((rootPC - base) % 12) + 12) % 12
        return listOf(r, r + if (minor) 3 else 4, r + 7)
    }

    /** Guitar voicing, low-E to high-e, movable E-form (major) / Em-form (minor) barre. */
    val guitarFrets: List<Int?>
        get() {
            val barre = (((rootPC - 4) % 12) + 12) % 12
            val shape = if (minor) listOf(0, 2, 2, 0, 0, 0) else listOf(0, 2, 2, 1, 0, 0)
            return shape.map { it + barre }
        }

    val tabText: String get() = guitarFrets.joinToString("-") { it?.toString() ?: "x" }

    companion object {
        val NOTE_NAMES = listOf("C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B")
    }
}

@Serializable
enum class DemuxDrumKind {
    @SerialName("kick") KICK,
    @SerialName("snare") SNARE,
    @SerialName("percussive") PERCUSSIVE,
    @SerialName("other") OTHER,
    @SerialName("bass") BASS,
}

@Serializable
data class DemuxDrumHit(val ms: Int, val kind: DemuxDrumKind, val strength: Double)

@Serializable
data class DemuxMelodyNote(val midi: Int, val startMs: Int, val endMs: Int)

@Serializable
enum class DemuxArtifactStatus {
    @SerialName("none") NONE,
    @SerialName("done") DONE,
    @SerialName("failed") FAILED,
    @SerialName("unavailable") UNAVAILABLE,
    @SerialName("running") RUNNING,
}

/** Everything the Demuxer derived for one audio source. One JSON file per source key. */
@Serializable
data class DemuxDocument(
    val schemaVersion: Int = DEMUX_SCHEMA_VERSION,
    val sourceKey: String,
    val displayName: String,
    val durationMs: Int = 0,
    val transcriptStatus: DemuxArtifactStatus = DemuxArtifactStatus.NONE,
    val words: List<DemuxWord> = emptyList(),
    val transcriptCoveredMs: Int? = null,
    val transcriptDiag: String? = null,
    val transcriptEngine: String? = null,
    val chordStatus: DemuxArtifactStatus = DemuxArtifactStatus.NONE,
    val chords: List<DemuxChordSegment> = emptyList(),
    val drumStatus: DemuxArtifactStatus? = null,
    val drumHits: List<DemuxDrumHit>? = null,
    val melodyStatus: DemuxArtifactStatus? = null,
    val melodyNotes: List<DemuxMelodyNote>? = null,
    val importedFileName: String? = null,
)
