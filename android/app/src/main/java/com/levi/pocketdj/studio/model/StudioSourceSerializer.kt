package com.levi.pocketdj.studio.model

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Where a sample's audio came from — provenance ONLY (playback always reads the sample's own
 * file). Port of iOS `StudioSource`, with the same `type` discriminator JSON
 * (`track|mic|take|file|lineIn`).
 */
sealed class StudioSource {
    /** Carved out of an indexed track: song + region (ms from the SONG's 0:00). */
    data class Track(val songId: String, val startMs: Int, val endMs: Int) : StudioSource()
    /** Recorded from the microphone. */
    data object Mic : StudioSource()
    /** Copied from an instrument take's rendered audio (`tk_…`, provenance only). */
    data class Take(val takeId: String) : StudioSource()
    /** Imported from an arbitrary audio file; only the name is kept for the "from <name>" label. */
    data class File(val originalName: String) : StudioSource()
    /** Captured from an EXTERNAL audio input; [inputName] is the port name for the label. */
    data class LineIn(val inputName: String?) : StudioSource()
}

/** JSON codec for [StudioSource] (kept apart from the models so the discriminator is one file). */
object StudioSourceSerializer {
    /**
     * Lenient: a non-object, or an unknown/missing `type` (a future source kind) degrades to
     * [StudioSource.Mic] — generic "recorded audio" provenance; the sample's FILE still plays.
     */
    fun decode(el: JsonElement?): StudioSource {
        val o = el as? JsonObject ?: return StudioSource.Mic
        return when (o.str("type") ?: "mic") {
            "track" -> StudioSource.Track(o.str("songId") ?: "", o.int("startMs") ?: 0, o.int("endMs") ?: 0)
            "take" -> StudioSource.Take(o.str("takeId") ?: "")
            "file" -> StudioSource.File(o.str("originalName") ?: "")
            "lineIn" -> StudioSource.LineIn(o.str("inputName"))
            else -> StudioSource.Mic
        }
    }

    fun encode(s: StudioSource): JsonObject = when (s) {
        is StudioSource.Track -> jsonObj(
            "type" to JsonPrimitive("track"), "songId" to JsonPrimitive(s.songId),
            "startMs" to JsonPrimitive(s.startMs), "endMs" to JsonPrimitive(s.endMs),
        )
        StudioSource.Mic -> jsonObj("type" to JsonPrimitive("mic"))
        is StudioSource.Take -> jsonObj("type" to JsonPrimitive("take"), "takeId" to JsonPrimitive(s.takeId))
        is StudioSource.File -> jsonObj("type" to JsonPrimitive("file"), "originalName" to JsonPrimitive(s.originalName))
        is StudioSource.LineIn -> jsonObj("type" to JsonPrimitive("lineIn"), "inputName" to jsonStr(s.inputName))
    }
}
