package com.levi.pocketdj.studio.midi

import com.levi.pocketdj.studio.engine.TakeFileException
import com.levi.pocketdj.studio.engine.TakeFiler
import com.levi.pocketdj.studio.engine.TakeResult
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.model.StudioTake
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import java.io.File

/** Why a MIDI import failed; [message] is user-facing (iOS copy). */
class MidiImportException(message: String) : Exception(message)

/**
 * `.mid` -> take on the current instrument (iOS `StudioMIDIImport` + `handleMIDIImport`). All note tracks merge into one stream (v1: one
 * instrument plays the whole file); channel 10 percussion is dropped. The take's AUDIO is rendered from the events through the
 * instrument's bank at import so reconcile keeps the file (iOS writes a silent placeholder and renders in the background).
 */
object MidiImport {
    const val CANNOT_OPEN = "That file isn’t a MIDI file we can read."
    const val NO_NOTES = "No playable notes were found in that MIDI file."

    data class Result(val events: List<StudioNoteEvent>, val bpm: Double, val durationMs: Int)

    fun parse(bytes: ByteArray): Result {
        val parsed = try { SmfParser.parse(bytes) } catch (e: SmfException) { throw MidiImportException(CANNOT_OPEN) }
        if (parsed.events.isEmpty()) throw MidiImportException(NO_NOTES)
        return Result(parsed.events, parsed.bpm, parsed.durationMs)
    }

    /** Display name from a file name: extension stripped, blank => null. */
    fun baseName(fileName: String?): String? =
        fileName?.substringBeforeLast('.', fileName)?.trim()?.takeIf { it.isNotEmpty() }

    /** Parse + file as a take on [instrument]. [bank] is that instrument's downloaded bank (null => pack-missing failure). */
    suspend fun importTake(bytes: ByteArray, fileName: String?, instrument: InstrumentKey, defaultName: String, filer: TakeFiler, bank: File?): StudioTake {
        val r = parse(bytes)
        val id = StudioFactory.newTakeId()
        val result = TakeResult(id, StudioFolders.fileName(StudioFamily.TAKES, id), r.durationMs, r.events, r.bpm, instrument)
        return try {
            filer.file(result, baseName(fileName) ?: defaultName, bank)
        } catch (e: TakeFileException) { throw MidiImportException(e.failure.message) }
    }
}
