package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.AlbumEdit
import com.levi.pocketdj.data.catalog.AudioTrack
import com.levi.pocketdj.data.catalog.AudioTrackEdit
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.SongEdit
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.launch

/**
 * Pure delta math for the metadata edit sheets (iOS `EditDelta` in `Views/EditAlbumView.swift`): an entered value
 * becomes an override ONLY when it differs from the RAW (pre-overlay) index value, so unchanged fields are never
 * stored. No Compose, no Android types: JVM-testable.
 */
internal object EditDelta {
    fun string(entered: String, original: String?): String? {
        val v = entered.trim()
        return if (v == (original ?: "")) null else v
    }

    fun optional(entered: String, original: String?): String? {
        val v = entered.trim().ifEmpty { null }
        return if (v == original) null else v
    }

    fun int(entered: String, original: Int?): Int? {
        val v = entered.trim().toIntOrNull()
        return if (v == original) null else v
    }

    fun long(entered: String, original: Long?): Long? {
        val v = entered.trim().toLongOrNull()
        return if (v == original) null else v
    }

    fun double(entered: String, original: Double?): Double? {
        val v = entered.trim().toDoubleOrNull()
        return if (v == original) null else v
    }

    fun bool(entered: Boolean, original: Boolean?): Boolean? =
        if (entered == (original ?: false)) null else entered

    fun tags(entered: String, original: List<String>?): List<String>? {
        val list = entered.split(',').map { it.trim() }.filter { it.isNotEmpty() }
        val v = list.ifEmpty { null }
        return if (v == original) null else v
    }

    /** True when [entered] is non-blank but does not parse as the number type (blank = "no value", valid). */
    fun badInt(entered: String) = entered.isNotBlank() && entered.trim().toIntOrNull() == null
    fun badLong(entered: String) = entered.isNotBlank() && entered.trim().toLongOrNull() == null
    fun badDouble(entered: String) = entered.isNotBlank() && entered.trim().toDoubleOrNull() == null

    fun albumInvalid(year: String) = badInt(year)
    fun songInvalid(year: String, track: String, bpm: String) = badInt(year) || badInt(track) || badDouble(bpm)
    fun audioInvalid(rows: List<AudioRow>) = rows.any { badDouble(it.bpm) || badLong(it.startMs) || badLong(it.endMs) }

    /** iOS `Fmt.trim`: a whole number prints without ".0". */
    fun trim(d: Double): String = if (d == Math.rint(d) && Math.abs(d) < 1e15) d.toLong().toString() else d.toString()

    /**
     * The album's metadata delta against [raw]. Fields the sheet doesn't show (the audio-analysis / boundary
     * overrides in [existing]) are CARRIED so saving a title never wipes them (iOS rebuilds a bare AlbumEdit here).
     */
    fun albumEdit(
        existing: AlbumEdit?, raw: IndexAlbum?,
        name: String, artist: String, genre: String, year: String, country: String,
    ): AlbumEdit = AlbumEdit(
        name = string(name, raw?.name),
        artist = string(artist, raw?.artist),
        genre = optional(genre, raw?.genre),
        year = int(year, raw?.year),
        country = optional(country, raw?.country),
        audioTracks = existing?.audioTracks,
    )

    fun songEdit(
        raw: IndexSong?,
        name: String, artist: String, year: String, track: String, bpm: String,
        key: String, camelot: String, explicit: Boolean, sentiment: String,
    ): SongEdit = SongEdit(
        name = string(name, raw?.name),
        artist = string(artist, raw?.artist),
        year = int(year, raw?.year),
        trackNumber = int(track, raw?.trackNumber),
        bpm = double(bpm, raw?.bpm),
        key = optional(key, raw?.key),
        camelot = optional(camelot, raw?.camelot),
        explicit = bool(explicit, raw?.explicit),
        sentimentKeywords = tags(sentiment, raw?.sentimentKeywords),
    )

    /** One audio-analysis row's editable text, seeded from the (overlaid) album. */
    data class AudioRow(
        val index: Int,
        val trackNumber: Int?,
        val bpm: String,
        val key: String,
        val camelot: String,
        val startMs: String,
        val endMs: String,
    )

    fun audioRows(segments: List<AudioTrack>?): List<AudioRow> = segments.orEmpty().mapIndexed { i, s ->
        AudioRow(i, s.trackNumber, s.bpm?.let(::trim).orEmpty(), s.key.orEmpty(), s.camelot.orEmpty(),
            s.startMs?.toString().orEmpty(), s.endMs?.toString().orEmpty())
    }

    /**
     * Per-segment deltas against the RAW detected segments, written onto [existing] (other album edits are kept).
     * The segment's trackNumber rides along as the overlay match key; when no row overrides anything the audio
     * override is dropped entirely (null), so an all-default save leaves no residue.
     */
    fun audioEdit(existing: AlbumEdit?, raw: IndexAlbum?, rows: List<AudioRow>): AlbumEdit {
        val segs = raw?.audioTracks.orEmpty()
        val deltas = rows.map { row ->
            val seg = segs.getOrNull(row.index)
            AudioTrackEdit(
                trackNumber = seg?.trackNumber ?: row.trackNumber,
                bpm = double(row.bpm, seg?.bpm),
                key = optional(row.key, seg?.key),
                camelot = optional(row.camelot, seg?.camelot),
                startMs = long(row.startMs, seg?.startMs),
                endMs = long(row.endMs, seg?.endMs),
            )
        }
        return (existing ?: AlbumEdit()).copy(audioTracks = deltas.takeIf { d -> d.any { !it.isEmpty } })
    }
}

/** A labelled single-line text field shared by the edit sheets (iOS `EditField`). */
@Composable
internal fun EditField(label: String, value: String, onChange: (String) -> Unit, numeric: Boolean = false, tag: String? = null, isError: Boolean = false) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = true,
        isError = isError,
        keyboardOptions = KeyboardOptions(
            keyboardType = if (numeric) KeyboardType.Decimal else KeyboardType.Text,
            capitalization = if (numeric) KeyboardCapitalization.None else KeyboardCapitalization.Sentences,
        ),
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp).let { if (tag != null) it.testTag(tag) else it },
    )
}

/** Shared sheet chrome: title, scrolling body, Cancel / Save row (+ optional destructive reset). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun EditSheetScaffold(
    title: String,
    saveTag: String,
    onDismiss: () -> Unit,
    onSave: () -> Unit,
    resetLabel: String? = null,
    resetTag: String = "reset-edit",
    onReset: (() -> Unit)? = null,
    saveEnabled: Boolean = true,
    content: @Composable () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).navigationBarsPadding().padding(bottom = 24.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                Button(onClick = onSave, enabled = saveEnabled, modifier = Modifier.testTag(saveTag)) { Text("Save") }
            }
            Spacer(Modifier.height(8.dp))
            content()
            if (resetLabel != null && onReset != null) {
                Spacer(Modifier.height(12.dp))
                OutlinedButton(onClick = onReset, modifier = Modifier.fillMaxWidth().testTag(resetTag)) {
                    Text(resetLabel, color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}

/** Edit an album's title / artist / genre / year / country. Stores only deltas against the RAW album. */
@Composable
fun EditAlbumSheet(album: IndexAlbum, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val store = graph.collectionsGraph.editsStore
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(album.name) }
    var artist by remember { mutableStateOf(album.artist) }
    var genre by remember { mutableStateOf(album.genre.orEmpty()) }
    var year by remember { mutableStateOf(album.year?.toString().orEmpty()) }
    var country by remember { mutableStateOf(album.country.orEmpty()) }
    val existing = remember { store.albumEdit(album.id) }
    // Reset only appears for a metadata edit (the audio override has its own reset in the audio sheet).
    val hasMetaEdit = existing?.let { it.copy(audioTracks = null).isEmpty.not() } == true

    EditSheetScaffold(
        title = "Edit Album",
        saveTag = "save-edit",
        onDismiss = onDismiss,
        saveEnabled = !EditDelta.albumInvalid(year),
        onSave = {
            // Without the raw row there is nothing to diff against: refuse rather than freeze every field.
            val raw = graph.catalogRepository.rawAlbum(album.id) ?: return@EditSheetScaffold onDismiss()
            val edit = EditDelta.albumEdit(store.albumEdit(album.id), raw, name, artist, genre, year, country)
            scope.launch { store.setAlbumEditIo(album.id, edit); onDismiss() }
        },
        resetLabel = if (hasMetaEdit) "Reset to original" else null,
        onReset = {
            scope.launch {
                val keep = store.albumEdit(album.id)?.audioTracks
                store.setAlbumEditIo(album.id, AlbumEdit(audioTracks = keep))
                onDismiss()
            }
        },
    ) {
        EditField("Title", name, { name = it }, tag = "edit-album-title")
        EditField("Artist", artist, { artist = it })
        EditField("Genre", genre, { genre = it })
        EditField("Year", year, { year = it }, numeric = true, tag = "edit-album-year", isError = EditDelta.badInt(year))
        EditField("Country", country, { country = it })
    }
}
