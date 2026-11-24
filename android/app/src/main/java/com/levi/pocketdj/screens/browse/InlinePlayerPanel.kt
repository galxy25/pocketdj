package com.levi.pocketdj.screens.browse

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.rememberAsyncImagePainter
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.data.config.Endpoints
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Pure rules for the inline slide-out player (iOS `InlinePlayerSlot` / `InlinePlayerPanel` / `AppleMusicInlinePanel`,
 * P2-LIB-5 / vinyl G14). The panel is KEYED on the sequencer's current song: it shows under the one row whose song
 * is the audible/current one, and nowhere else.
 */
internal object InlinePlayerState {
    /** Which body the expanded panel shows. */
    enum class Body {
        /** Live HLS (unseekable): "Streaming live as it rips" instead of a scrubber. */
        LIVE,

        /** Apple Music streaming: no waveform (none exists), a position slider only. */
        APPLE_MUSIC,

        /** Waveform strip (tap/drag to seek) over the scrubber. */
        WAVEFORM,

        /** A rip with no waveform PNG yet: scrubber only. */
        SCRUBBER,
    }

    /** iOS `PlaybackBackend.appleMusic.viaLabel`. */
    const val AM_VIA_LABEL = "via Apple Music"
    const val LIVE_BADGE = "● live"
    const val LIVE_CAPTION = "Streaming live as it rips"

    /** Live wins over everything; AM has no waveform; otherwise the waveform when its PNG is known. */
    fun body(isLive: Boolean, isAppleMusic: Boolean, hasWaveform: Boolean): Body = when {
        isLive -> Body.LIVE
        isAppleMusic -> Body.APPLE_MUSIC
        hasWaveform -> Body.WAVEFORM
        else -> Body.SCRUBBER
    }

    /**
     * The panel shows under [rowSongId]'s row iff that song is the sequencer's current one (else the audible one),
     * compared on the base id so an edition/variant of the row's song still matches.
     */
    fun matches(rowSongId: String, sequencerCurrentId: String?, audibleId: String?): Boolean {
        val key = sequencerCurrentId ?: audibleId ?: return false
        return SongVariant.baseId(key) == SongVariant.baseId(rowSongId)
    }

    /** Fractions [from, to] of the album PNG that make up one song's window. */
    data class Crop(val from: Float, val to: Float) {
        val span: Float get() = to - from
    }

    /**
     * Analog waveform crop (iOS: the album PNG shown under the song = its window of the side). [startMs]/[endMs] are
     * the song's window inside the shared album file, [totalMs] the file length. null when the song is not an analog
     * slice (own waveform: draw whole) or the window is unusable. Clamped into 0..1; a window past the file end clips.
     */
    fun analogCrop(startMs: Long?, endMs: Long?, totalMs: Long?): Crop? {
        if (startMs == null || endMs == null || totalMs == null || totalMs <= 0) return null
        val from = (startMs.coerceAtLeast(0L).toDouble() / totalMs).coerceIn(0.0, 1.0)
        val to = (endMs.toDouble() / totalMs).coerceIn(0.0, 1.0)
        if (to - from < MIN_SPAN) return null
        return Crop(from.toFloat(), to.toFloat())
    }

    private const val MIN_SPAN = 0.0005

    /** Tap/drag x (0..width) on the strip -> song-relative position, or null when it cannot seek (live / no duration). */
    fun seekMs(x: Float, width: Float, durationMs: Long?, isLive: Boolean): Long? {
        if (isLive || durationMs == null || durationMs <= 0 || width <= 0f) return null
        return (x / width).coerceIn(0f, 1f).let { (it.toDouble() * durationMs).toLong() }
    }

    /** The scrubber's range: the engine's duration, else the catalog length, never 0 (iOS `max(player, catalog, 0.01)`). */
    fun scrubberDurationMs(engineMs: Long?, catalogMs: Long?): Long =
        maxOf(engineMs ?: 0L, catalogMs ?: 0L, 10L)

    /** "m:ss" like iOS `clock`. */
    fun clock(ms: Long): String {
        val total = (ms.coerceAtLeast(0L) / 1000).toInt()
        return "${total / 60}:${(total % 60).toString().padStart(2, '0')}"
    }

    /** Subtitle under the title: the artist (the "via" tag renders on its own line-end). */
    fun viaLabel(isAppleMusic: Boolean): String? = if (isAppleMusic) AM_VIA_LABEL else null
}

/**
 * Renders under a track row: nothing unless this row's song is the current one. [album] supplies the analog window
 * (the album PNG is cropped to this song's slice via [InlinePlayerState.analogCrop]).
 */
@Composable
internal fun InlinePlayerSlot(song: IndexSong, album: IndexAlbum?, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val seqState by graph.playbackGraph.sequencer.state.collectAsState()
    val nowPlaying by graph.playbackController.nowPlaying.collectAsState()
    val np = nowPlaying
    val show = np != null && InlinePlayerState.matches(song.id, seqState.current?.id, np.songId)
    AnimatedVisibility(
        visible = show,
        enter = fadeIn() + expandVertically(),
        exit = fadeOut() + shrinkVertically(),
        modifier = modifier,
    ) {
        // Keep the last non-null np for the exit animation.
        val info = np ?: return@AnimatedVisibility
        InlinePlayerPanel(song, album, info)
    }
}

@Composable
private fun InlinePlayerPanel(
    song: IndexSong,
    album: IndexAlbum?,
    np: com.levi.pocketdj.playback.PlaybackController.NowPlayingInfo,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val controller = graph.playbackController
    val scope = rememberCoroutineScope()
    val manifest by graph.ripsRepository.manifest.collectAsState()
    var collapsed by remember { mutableStateOf(false) }
    val isAm = controller.isAppleMusicActive
    val entry = manifest[song.id]
    val waveformUrl = entry?.waveform?.let { Endpoints.ripAudioUrl(it) }
    val body = InlinePlayerState.body(np.isLive, isAm, waveformUrl != null)

    val start = graph.ripsRepository.effectiveStartMs(song.id)
    val end = graph.ripsRepository.analogEndMs(song.id, start, song.length)
    val totalMs = album?.audioDurationSec?.takeIf { it > 0 }?.let { (it * 1000).toLong() }
    val crop = InlinePlayerState.analogCrop(start, end, totalMs)

    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp)
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(10.dp))
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(10.dp))
            .padding(10.dp)
            .testTag("inline-player"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(
                onClick = { scope.launch { if (np.isPlaying) controller.pause() else controller.resume() } },
                modifier = Modifier.size(36.dp).testTag("player-toggle"),
            ) {
                Icon(
                    if (np.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = if (np.isPlaying) "Pause" else "Play",
                    tint = MaterialTheme.colorScheme.primary,
                )
            }
            Column(Modifier.weight(1f).padding(horizontal = 6.dp)) {
                Text(
                    np.title ?: song.name,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                (np.artist ?: song.artist).let {
                    Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            if (np.isLive) {
                Text(InlinePlayerState.LIVE_BADGE, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.tertiary, modifier = Modifier.testTag("player-live"))
            }
            InlinePlayerState.viaLabel(isAm)?.let {
                Text(it, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.tertiary, modifier = Modifier.testTag("am-player-via"))
            }
            IconButton(onClick = { collapsed = !collapsed }, modifier = Modifier.size(36.dp).testTag("player-chevron")) {
                Icon(
                    if (collapsed) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                    contentDescription = if (collapsed) "Expand player" else "Collapse player",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            IconButton(onClick = { scope.launch { controller.stop() } }, modifier = Modifier.size(36.dp).testTag("player-close")) {
                Icon(Icons.Filled.Close, contentDescription = "Stop and close player", tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (!collapsed) {
            InlinePlayerExpanded(song, np, body, waveformUrl, crop)
        }
    }
}

/** Waveform + scrubber; polls the position at 4 Hz in THIS composable only so the header buttons never recompose. */
@Composable
private fun InlinePlayerExpanded(
    song: IndexSong,
    np: com.levi.pocketdj.playback.PlaybackController.NowPlayingInfo,
    body: InlinePlayerState.Body,
    waveformUrl: String?,
    crop: InlinePlayerState.Crop?,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val controller = graph.playbackController
    val scope = rememberCoroutineScope()
    var posMs by remember { mutableStateOf(0L) }
    var scrubbing by remember { mutableStateOf<Float?>(null) }
    LaunchedEffect(np.songId, body) {
        if (body == InlinePlayerState.Body.LIVE) return@LaunchedEffect
        while (true) {
            if (scrubbing == null) posMs = runCatching { controller.currentPositionMs() }.getOrDefault(posMs)
            delay(250)
        }
    }
    val duration = InlinePlayerState.scrubberDurationMs(np.durationMs, song.length)

    when (body) {
        InlinePlayerState.Body.LIVE -> Row(
            Modifier.fillMaxWidth().height(36.dp).testTag("player-wave-live"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(InlinePlayerState.LIVE_CAPTION, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        else -> {
            if (body == InlinePlayerState.Body.WAVEFORM && waveformUrl != null) {
                WaveformStrip(waveformUrl, crop, posMs, duration) { x, w ->
                    InlinePlayerState.seekMs(x, w, duration, np.isLive)?.let { ms ->
                        posMs = ms
                        scope.launch { controller.seekTo(ms) }
                    }
                }
            }
            Column {
                val shown = scrubbing ?: posMs.toFloat()
                Slider(
                    value = shown.coerceIn(0f, duration.toFloat()),
                    onValueChange = { scrubbing = it },
                    onValueChangeFinished = {
                        scrubbing?.let { t -> scope.launch { controller.seekTo(t.toLong()) }; posMs = t.toLong() }
                        scrubbing = null
                    },
                    valueRange = 0f..duration.toFloat(),
                    modifier = Modifier.fillMaxWidth().testTag("player-seek"),
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(InlinePlayerState.clock(shown.toLong()), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (body != InlinePlayerState.Body.APPLE_MUSIC) {
                        Text(InlinePlayerState.clock(duration), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

/** 36 dp waveform strip: the PNG (cropped to the song's window for analog), a playhead, tap/drag to seek. */
@Composable
private fun WaveformStrip(url: String, crop: InlinePlayerState.Crop?, posMs: Long, durationMs: Long, onSeek: (x: Float, width: Float) -> Unit) {
    val painter = rememberAsyncImagePainter(model = url)
    var width by remember { mutableStateOf(0f) }
    val playColor = MaterialTheme.colorScheme.primary
    Box(
        Modifier
            .fillMaxWidth()
            .height(36.dp)
            .clipToBounds()
            .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(4.dp))
            .onSizeChanged { width = it.width.toFloat() }
            .drawBehind {
                val span = crop?.span ?: 1f
                val from = crop?.from ?: 0f
                // Draw the full image scaled so the [from,to] slice fills the strip, clipped to the strip.
                clipRect {
                    translate(left = -from * (size.width / span)) {
                        with(painter) { draw(Size(size.width / span, size.height)) }
                    }
                }
                val frac = if (durationMs > 0) (posMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
                drawLine(playColor, Offset(frac * size.width, 0f), Offset(frac * size.width, size.height), strokeWidth = 2f)
            }
            .pointerInput(Unit) {
                // Tap or horizontal drag seeks; a vertical pan is left to the page's list scroll.
                detectTapGestures { onSeek(it.x, size.width.toFloat()) }
            }
            .pointerInput(Unit) {
                detectHorizontalDragGestures(
                    onDragEnd = {},
                    onHorizontalDrag = { change, _ -> change.consume(); onSeek(change.position.x, size.width.toFloat()) },
                )
            }
            .testTag("player-wave-seek"),
    )
}
