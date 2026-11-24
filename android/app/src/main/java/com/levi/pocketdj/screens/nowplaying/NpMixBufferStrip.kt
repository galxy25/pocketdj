package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.mix.nowplaying.NpMixMode

/** What the dot of one upcoming row is a pure function of (iOS `mixModeBufferStrip`). */
data class NpMixDotFacts(
    /** The file this row WILL play (edition ladder included) is on the device. */
    val willPlayLocally: Boolean,
    val fetching: Boolean,
    val planned: Boolean,
    val ripped: Boolean,
    val deviceMode: Boolean,
    val failedRecently: Boolean,
    /** A rip is in flight for the row (owner-gated; always false on Android until Levi decides). */
    val ripInFlight: Boolean = false,
)

object NpMixBufferStripModel {
    /** ● local only when the file the row WILL play is local; then fetching / planned / ripped-queued / unavailable. */
    fun dot(f: NpMixDotFacts): NpMixMode.BufferDot = when {
        f.willPlayLocally -> NpMixMode.BufferDot.LOCAL
        f.fetching -> NpMixMode.BufferDot.BUFFERING
        f.planned -> NpMixMode.BufferDot.QUEUED
        f.ripped && !f.deviceMode && !f.failedRecently -> NpMixMode.BufferDot.QUEUED
        f.ripInFlight -> NpMixMode.BufferDot.QUEUED
        else -> NpMixMode.BufferDot.UNAVAILABLE
    }

    /** iOS `MixModeBufferStrip.word`. */
    fun word(d: NpMixMode.BufferDot): String = when (d) {
        NpMixMode.BufferDot.LOCAL -> "on device"
        NpMixMode.BufferDot.BUFFERING -> "buffering"
        NpMixMode.BufferDot.QUEUED -> "queued"
        NpMixMode.BufferDot.UNAVAILABLE -> "unavailable"
    }

    /** TalkBack value of the whole strip: "on device, buffering, queued". */
    fun spoken(rows: List<NpMixMode.BufferRow>): String = rows.joinToString(", ") { word(it.dot) }

    /** The next [ahead] rows after [index] (clamped; never negative). */
    fun window(queueSize: Int, index: Int, ahead: Int): IntRange {
        val from = index + 1
        val to = minOf(queueSize, from + maxOf(0, ahead)) - 1
        return if (from > to) IntRange.EMPTY else from..to
    }
}

/** Production reader of the strip rows (cheap ledger lookups, no disk; <= 10 rows). */
object NpMixBufferRows {
    fun read(app: AppGraph, deviceMode: Boolean): List<NpMixMode.BufferRow> {
        val mix = app.playbackGraph.npMix
        if (!mix.coordinator.enabled) return emptyList()
        val st = app.playbackGraph.sequencer.state.value
        if (!st.isRunning || st.index >= st.queue.size) return emptyList()
        val burns = app.servicesGraph.burnStore
        val loader = app.mixGraph.mixStreamLoader
        val pf = app.mixGraph.stemLockPrefetcher
        return NpMixBufferStripModel.window(st.queue.size, st.index, mix.settings().bufferAhead).map { i ->
            val q = st.queue[i]
            val id = q.resolveId
            val local = burns.isReadyInLedger(id) || loader.stream(id)?.isComplete == true
            NpMixMode.BufferRow(
                id = q.uid, title = q.title,
                dot = NpMixBufferStripModel.dot(
                    NpMixDotFacts(
                        willPlayLocally = local, fetching = pf.isFetchingSong(id), planned = pf.isPlannedSong(id),
                        ripped = loader.canStream(id), deviceMode = deviceMode, failedRecently = pf.songFailedRecently(id),
                    ),
                ),
            )
        }
    }
}

/** The one-line "Up next" dot strip under the controls (`np-mix-buffer-strip`). Nothing while there are no rows. */
@Composable
fun NpMixBufferStrip(rows: List<NpMixMode.BufferRow>, modifier: Modifier = Modifier) {
    if (rows.isEmpty()) return
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        modifier.fillMaxWidth().testTag("np-mix-buffer-strip").clearAndSetSemantics {
            contentDescription = "Buffer"
            stateDescription = NpMixBufferStripModel.spoken(rows)
        },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text("Up next", fontSize = 11.sp, color = dim)
        rows.forEach { r ->
            Text(
                r.dot.glyph, fontSize = 12.sp,
                color = if (r.dot == NpMixMode.BufferDot.LOCAL) MaterialTheme.colorScheme.primary else dim,
                modifier = Modifier.testTag("np-mix-dot-${r.dot.raw}"),
            )
        }
    }
}
