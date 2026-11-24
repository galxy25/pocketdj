package com.levi.pocketdj.screens.settings.storage

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.burns.TemporaryHold
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.mix.nowplaying.NpMixSettings
import com.levi.pocketdj.mix.nowplaying.NpMixSettingsRules
import com.levi.pocketdj.mix.nowplaying.npMixSettingsFlow
import com.levi.pocketdj.mix.nowplaying.setNpMixBufferCapGb
import com.levi.pocketdj.mix.nowplaying.setNpMixBufferTtlHours
import com.levi.pocketdj.mix.nowplaying.setNpMixKeepPickedFolderBuffers
import kotlinx.coroutines.launch
import java.util.Locale

/**
 * Pure state + copy for Settings ▸ Storage ▸ "Mix Mode buffer" (iOS `StorageView.mixBufferSection`),
 * JVM-tested in MixModeBufferSectionStateTest. The Keep sentinel is [NpMixSettings.KEEP_SENTINEL] (0).
 */
object MixModeBufferState {
    const val ROW_LIMIT = 25
    const val HOUR_MS = 3_600_000.0

    /** Reasons passed to `BurnStore.pin` (iOS-verbatim where the row is iOS's). */
    const val REASON_KEEP_ALL = "storage-keep-all"
    const val REASON_ROW_KEEP = "row-keep"
    const val REASON_DEMUX = "demux"
    const val REASON_TRACKS_STEMS = "tracks-stems"
    const val REASON_SAMPLE = "sample"
    const val REASON_TAKE = "take"

    /** Holds, soonest expiry first (the order the sweep removes them in); ties by song id. */
    fun sortedHolds(holds: Collection<TemporaryHold>): List<TemporaryHold> =
        holds.sortedWith(compareBy<TemporaryHold> { it.expiresAtMs }.thenBy { it.songId })

    fun visibleRows(holds: List<TemporaryHold>, showAll: Boolean): List<TemporaryHold> =
        if (showAll || holds.size <= ROW_LIMIT) holds else holds.take(ROW_LIMIT)

    fun showAllVisible(count: Int, showAll: Boolean) = count > ROW_LIMIT && !showAll

    /** Decimal bytes, iOS ByteCountFormatter-ish: "0 KB", "812 KB", "1.4 GB". */
    fun formatBytes(bytes: Long): String {
        val b = bytes.coerceAtLeast(0)
        return when {
            b < 1_000_000 -> "${b / 1_000} KB"
            b < 1_000_000_000 -> String.format(Locale.US, "%.1f MB", b / 1e6).replace(".0 MB", " MB")
            else -> String.format(Locale.US, "%.2f GB", b / 1e9)
        }
    }

    fun usageLine(count: Int, bytes: Long) = "$count song${if (count == 1) "" else "s"} · ${formatBytes(bytes)}"

    /** "in 31 h" / "in 2 days" / "in 12 min" / "now". */
    fun expiryPhrase(expiresAtMs: Double, nowMs: Double): String {
        val hours = (expiresAtMs - nowMs) / HOUR_MS
        return when {
            hours <= 0 -> "now"
            hours < 1 -> "in ${maxOf(1, Math.round(hours * 60).toInt())} min"
            hours < 48 -> "in ${Math.round(hours).toInt()} h"
            else -> "in ${Math.round(hours / 24).toInt()} days"
        }
    }

    fun nextExpiryLine(sorted: List<TemporaryHold>, nowMs: Double): String? =
        sorted.firstOrNull()?.let { "Next expiry ${expiryPhrase(it.expiresAtMs, nowMs)}." }

    /** Song row / detail badge: "Buffered · expires in 31 h". */
    fun badgeText(expiresAtMs: Double, nowMs: Double) = "Buffered · expires ${expiryPhrase(expiresAtMs, nowMs)}"

    fun ttlLabel(hours: Double): String = when {
        hours == NpMixSettings.KEEP_SENTINEL -> "Keep (treat as downloads)"
        hours >= 72 && hours % 24.0 == 0.0 -> "${(hours / 24).toInt()} days"
        else -> "${hours.toInt()} h"
    }

    fun capLabel(gb: Double): String = if (gb < 1) "${(gb * 1000).toInt()} MB" else "${gb.toInt()} GB"

    /** The picker's stored value for the effective settings: null TTL (Keep) maps to the sentinel. */
    fun ttlPickerValue(s: NpMixSettings): Double = s.bufferTtlHours ?: NpMixSettings.KEEP_SENTINEL

    /** Picker options; a stored value not in the list (e.g. another build's) is appended so it stays selectable. */
    fun ttlOptions(current: Double): List<Double> =
        NpMixSettings.TTL_OPTIONS.let { if (current in it || !(current > 0)) it else it + current }

    fun capOptions(current: Double): List<Double> =
        NpMixSettings.CAP_OPTIONS.let { if (current in it || !(current > 0)) it else (it + current).sorted() }

    /** Picker value -> persisted raw TTL (Keep stays the 0 sentinel, never null: absent means the 48 h default). */
    fun ttlToStore(picked: Double): Double = if (picked == NpMixSettings.KEEP_SENTINEL) NpMixSettings.KEEP_SENTINEL else picked

    /** Persisted raw -> picker value, through the same corrupt-value normalisation the readers use. */
    fun ttlFromStore(raw: Double?): Double = NpMixSettingsRules.effectiveTtlHours(raw) ?: NpMixSettings.KEEP_SENTINEL

    fun footer(ttlHours: Double?, keepPicked: Boolean): String =
        (if (ttlHours == null) {
            "Songs and stems Now Playing downloads ahead on its own (Mix Mode, Stem Lock) are kept like downloads. " +
                "Songs already buffered still expire on schedule - tap Keep all to keep them."
        } else {
            "Songs and stems Now Playing downloads ahead on its own (Mix Mode, Stem Lock) are temporary: they're removed " +
                "after the time above unless you download or mix them first - then they're yours to keep. Nothing playing " +
                "or coming up next is ever removed, and downloads you asked for are never temporary."
        }) + if (keepPicked) {
            " Songs buffered into a burn folder you picked are kept like downloads."
        } else {
            " Songs buffered into a burn folder you picked are removed on the same schedule - if that folder is shared " +
                "with another device (Drive, an external disk), it loses them too. Turn on Keep buffered files in picked " +
                "folders to keep them. Files you downloaded, and files that were already there, are never removed."
        }

    /** "song · drums · bass · 12 MB · expires in 3 h". */
    fun rowDetail(h: TemporaryHold, nowMs: Double): String {
        val parts = (if (h.audio) listOf("song") else emptyList()) + h.stemParts
        return "${parts.joinToString(" · ")} · ${formatBytes(h.bytes)} · expires ${expiryPhrase(h.expiresAtMs, nowMs)}"
    }

    fun rowTitle(title: String?, artist: String?, songId: String): String {
        val t = title?.takeIf { it.isNotBlank() } ?: songId
        return if (artist.isNullOrBlank()) t else "$artist - $t"
    }
}

/**
 * Explicit Studio use of a catalog song (np-mix-mode 3.3): a buffered (temporary) copy becomes a download so the
 * sweep can never pull the source out from under a demux, take, sample or imported stems. No hold = no-op.
 */
object StudioPins {
    fun pin(graph: AppGraph, songId: String, reason: String): Int =
        graph.servicesGraph.burnStore.pin(listOf(songId), reason)
}

/** Settings ▸ Storage ▸ Mix Mode buffer. */
@Composable
fun MixModeBufferSection(graph: AppGraph, modifier: Modifier = Modifier) {
    val services = graph.servicesGraph
    val scope = rememberCoroutineScope()
    var status by remember { mutableStateOf<String?>(null) }
    val settings by remember { graph.settings.npMixSettingsFlow() }.collectAsState(initial = NpMixSettings())
    val holdsMap by services.burnStore.temporaryHolds.collectAsState()
    val items by services.burnStore.items.collectAsState()
    val catalog by graph.catalogRepository.state.collectAsState()
    var showAll by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    val now = System.currentTimeMillis().toDouble()
    val holds = MixModeBufferState.sortedHolds(holdsMap.values)
    val footprint = holds.sumOf { it.bytes }

    Column(modifier.fillMaxWidth().testTag("storage-buffer-section"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Mix Mode buffer", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Buffered")
            Text(MixModeBufferState.usageLine(holds.size, footprint), Modifier.testTag("storage-buffer-usage"),
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        MixModeBufferState.nextExpiryLine(holds, now)?.let {
            Text(it, Modifier.testTag("storage-buffer-next-expiry"), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        val ttl = MixModeBufferState.ttlPickerValue(settings)
        PickerRow("Keep buffered songs for", MixModeBufferState.ttlLabel(ttl), "storage-buffer-ttl",
            MixModeBufferState.ttlOptions(ttl).map { MixModeBufferState.ttlLabel(it) to it }) { v ->
            // A TTL change applies only to assets buffered AFTER it; existing holds keep their expiry.
            scope.launch { graph.settings.setNpMixBufferTtlHours(MixModeBufferState.ttlToStore(v)) }
        }
        PickerRow("Buffer limit", MixModeBufferState.capLabel(settings.bufferCapGb), "storage-buffer-cap",
            MixModeBufferState.capOptions(settings.bufferCapGb).map { MixModeBufferState.capLabel(it) to it }) { v ->
            scope.launch {
                graph.settings.setNpMixBufferCapGb(v)
                services.storageManager.scheduleCapSweepIfNeeded() // a lower cap applies right away (iOS)
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Keep buffered files in picked folders", Modifier.weight(1f))
            Switch(settings.keepPickedFolderBuffers, { on -> scope.launch { graph.settings.setNpMixKeepPickedFolderBuffers(on) } },
                Modifier.testTag("storage-buffer-keep-picked"))
        }
        for (h in MixModeBufferState.visibleRows(holds, showAll)) {
            val item = items[h.songId]
            val song = catalog.catalog?.songsById?.get(h.songId)
            Column(Modifier.fillMaxWidth().testTag("storage-buffer-row-${h.songId}")) {
                Text(MixModeBufferState.rowTitle(item?.title ?: song?.name, item?.artist ?: song?.artist, h.songId), maxLines = 1)
                Text(MixModeBufferState.rowDetail(h, now), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            }
        }
        if (MixModeBufferState.showAllVisible(holds.size, showAll)) {
            TextButton({ showAll = true }, Modifier.testTag("storage-buffer-show-all")) { Text("Show all ${holds.size}") }
        }
        if (holds.isNotEmpty()) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton({ services.burnStore.pinAllTemporary(MixModeBufferState.REASON_KEEP_ALL); status = "Kept all buffered songs." },
                    Modifier.testTag("storage-buffer-keep-all")) { Text("Keep all") }
                TextButton({ confirmClear = true }, Modifier.testTag("storage-buffer-clear")) {
                    Text("Clear now", color = MaterialTheme.colorScheme.error)
                }
            }
        }
        status?.let {
            Text(it, Modifier.testTag("storage-buffer-status"), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary)
        }
        Text(MixModeBufferState.footer(settings.bufferTtlHours, settings.keepPickedFolderBuffers),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(4.dp))
    }
    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Clear the Mix Mode buffer?") },
            text = { Text("Removes every buffered song and stem except what's playing or up next. Your downloads are not affected.") },
            confirmButton = {
                TextButton({
                    confirmClear = false
                    // Graph-level scope: leaving the screen mid-sweep must not cancel it.
                    graph.appScope.launch {
                        val r = services.storageManager.sweepTemporary(reason = "storage-clear", ignoreExpiry = true)
                        status = if (r == null) "Busy, try again in a moment." else "Buffer cleared."
                    }
                }, Modifier.testTag("storage-buffer-clear-confirm")) { Text("Clear buffered songs") }
            },
            dismissButton = { TextButton({ confirmClear = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun PickerRow(label: String, current: String, tag: String, options: List<Pair<String, Double>>, onPick: (Double) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clickable { open = true }.padding(vertical = 6.dp).testTag(tag),
        horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        Text(label)
        Text(current, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.primary)
        DropdownMenu(open, { open = false }) {
            for ((text, v) in options) DropdownMenuItem(text = { Text(text) }, onClick = { open = false; onPick(v) },
                modifier = Modifier.testTag("$tag-$text"))
        }
    }
}
