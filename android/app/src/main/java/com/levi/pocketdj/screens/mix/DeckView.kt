package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.Eject
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.data.burns.BurnFileNames
import com.levi.pocketdj.mix.engine.LoopController
import com.levi.pocketdj.mix.engine.MixEngine
import com.levi.pocketdj.mix.engine.StemController
import com.levi.pocketdj.mix.engine.StemHandover
import com.levi.pocketdj.mix.engine.StreamDecks
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.EQBand
import com.levi.pocketdj.mix.model.FxRack
import com.levi.pocketdj.mix.model.LoadedTrack
import com.levi.pocketdj.mix.model.MixRanges
import com.levi.pocketdj.screens.browse.KeyChip

/**
 * Everything a deck needs from the app, bundled so the composables never reach for globals and the
 * Mix screen (MIX-14) wires it once. [art] draws the album cover; [peaksFor] decodes the waveform;
 * [isStemmed] says whether a track has server stems (the stem-mode toggle only shows for those).
 */
class DeckHost(
    val engine: MixEngine,
    val stems: StemController,
    val loops: LoopController,
    val streams: StreamDecks? = null,
    val cues: CuePointsProvider = CuePointsProvider.None,
    val isStemmed: (String) -> Boolean = { false },
    val peaksFor: suspend (LoadedTrack) -> FloatArray = { FloatArray(0) },
    val art: @Composable (albumId: String?, modifier: Modifier) -> Unit = { _, m -> ArtPlaceholder(m) },
    /** MIX-17 seam: open the slot-modulation sheet. null = the MOD chip is an inert placeholder. */
    val onMod: ((Deck, Int) -> Unit)? = null,
)

@Composable
fun ArtPlaceholder(modifier: Modifier = Modifier) {
    Box(modifier.clip(RoundedCornerShape(6.dp)).background(DeckColors.overlay), contentAlignment = Alignment.Center) {
        Icon(Icons.Filled.Album, null, tint = DeckColors.dim, modifier = Modifier.size(24.dp))
    }
}

/**
 * One deck. Reads ONLY the structural [MixEngine.ui] flow; the playhead, VU and beat pulse are polled
 * by their own composables, so a position tick never recomposes this function.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun DeckView(
    host: DeckHost,
    deck: Deck,
    onLoad: () -> Unit,
    modifier: Modifier = Modifier,
    beatPulseEnabled: Boolean = false,
    compactControls: Boolean = false,
    sourceMenu: @Composable () -> Unit = {},
) {
    val engine = host.engine
    val ui by engine.ui.collectAsState()
    val handovers by host.stems.handovers.collectAsState()
    val bufferingSet by (host.streams?.buffering ?: remember { kotlinx.coroutines.flow.MutableStateFlow(emptySet<Deck>()) }).collectAsState()
    val streamingSet by (host.streams?.streaming ?: remember { kotlinx.coroutines.flow.MutableStateFlow(emptySet<Deck>()) }).collectAsState()

    val ds = ui.deck(deck)
    val loaded = ds.loaded
    val a11y = "deck-${deck.label}"
    val handover = handovers[deck]
    val buffering = deck in bufferingSet
    val stemmed = loaded?.let { host.isStemmed(it.songId) } == true
    val stemActive = ds.stemMode && host.stems.active(deck)

    // Waveform: once per loaded track, and once more when a STREAMING track finishes (the burn file exists then).
    var peaks by remember(deck) { mutableStateOf(FloatArray(0)) }
    LaunchedEffect(loaded?.songId, deck in streamingSet) {
        peaks = if (loaded == null) FloatArray(0) else host.peaksFor(loaded)
    }

    Box(modifier.fillMaxWidth()) {
        Surface(
            shape = RoundedCornerShape(12.dp), color = DeckColors.raised,
            border = BorderStroke(1.dp, DeckColors.border),
            modifier = Modifier.fillMaxWidth().testTag(a11y),
        ) {
            Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                // Deck label + status badge + source menu
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Deck ${deck.label}", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = DeckColors.fg)
                    if (buffering) {
                        MixBufferingBadge(tag = "$a11y-buffering")
                    } else if (handover != null) {
                        MixBufferingBadge(
                            text = if (handover == StemHandover.TO_STEMS) "Loading stems…" else "Loading full mix…",
                            tag = "$a11y-stems-pending",
                        )
                    }
                    Box(Modifier.weight(1f))
                    sourceMenu()
                }
                DeckHeader(host, deck, loaded, peaks, a11y, onLoad)
                DeckSeekSlider(engine, deck)
                CueJumpRow(host, deck, loaded, a11y)
                TransportRow(host, deck, ds.loaded != null, stemmed, handover != null, ds.stemMode, compactControls, a11y)
                DeckSlider(
                    title = "Tempo", display = DeckControlMath.tempoLabel(ds.rate), value = ds.rate,
                    range = MixRanges.rate, step = 0.01, tag = "$a11y-tempo",
                ) { engine.setRate(it, deck) }
                DeckSlider(
                    title = "Pitch", display = DeckControlMath.pitchLabel(ds.pitch), value = ds.pitch,
                    range = MixRanges.pitch, step = 0.1, tag = "$a11y-pitch",
                ) { engine.setPitch(it, deck) }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    EQBand.entries.forEach { band ->
                        val v = ds.eqGain(band)
                        MixKnob(
                            title = band.label, display = DeckControlMath.eqLabel(v), value = v,
                            range = MixRanges.eq, tag = "$a11y-eq-${band.label.lowercase()}",
                        ) { engine.setEqGain(band, it, deck) }
                    }
                }
                FxGrid(host, deck, a11y)
                if (stemActive) StemGrid(host, deck, a11y)
                DeckVuMeter(engine, deck)
                VolSlider(engine, deck, ds.volume, a11y)
                PlayButton(engine, deck, loaded != null, ds.isPlaying, buffering, a11y)
            }
        }
        // Opt-in beat pulse: never composed when the setting is off.
        if (beatPulseEnabled) BeatPulse(engine, deck, Modifier.matchParentSize())
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DeckHeader(host: DeckHost, deck: Deck, loaded: LoadedTrack?, peaks: FloatArray, a11y: String, onLoad: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Column(
            Modifier
                .fillMaxWidth()
                .combinedClickable(onClick = onLoad, onLongClick = { menu = true })
                .testTag("$a11y-load"),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            MixWaveformView(peaks)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                host.art(loaded?.albumId, Modifier.size(46.dp).clip(RoundedCornerShape(6.dp)))
                if (loaded != null) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(loaded.title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = DeckColors.fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(loaded.artist, fontSize = 12.sp, color = DeckColors.dim, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        KeyOrBpm(loaded, a11y)
                    }
                } else {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("Load a track", fontSize = 14.sp, color = DeckColors.fg)
                        Text("Tap, or long-press", fontSize = 11.sp, color = DeckColors.dim)
                    }
                }
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Load track…") }, onClick = { menu = false; onLoad() })
        }
    }
}

/** Camelot chip (when known) PLUS the beat-grid BPM; a placeholder chip only when neither is known. */
@Composable
private fun KeyOrBpm(t: LoadedTrack, a11y: String) {
    val bpm = DeckControlMath.bpmLabel(t)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (!t.camelot.isNullOrEmpty()) KeyChip(t.key, t.camelot)
        if (bpm != null) {
            Text(bpm, fontSize = 11.sp, color = DeckColors.dim, fontFamily = FontFamily.Monospace, modifier = Modifier.testTag("$a11y-gridbpm"))
        }
        if (t.camelot.isNullOrEmpty() && bpm == null) KeyChip(null, null)
    }
}

/** Drop-cue button + color-coded jump buttons (up to 8, a 4-wide grid). Absent without a loaded track. */
@Composable
private fun CueJumpRow(host: DeckHost, deck: Deck, loaded: LoadedTrack?, a11y: String) {
    val songId = loaded?.songId ?: return
    var rev by remember(songId) { mutableIntStateOf(0) }
    val cues = remember(songId, rev) { host.cues.cues(songId) }
    val free = DeckControlMath.nextFreeCueSlot(cues.map { it.slot }.toSet())
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row {
            Row(
                Modifier
                    .clip(RoundedCornerShape(50))
                    .background(DeckColors.gold.copy(alpha = 0.18f))
                    .clickable(enabled = free != null) {
                        val slot = free ?: return@clickable
                        val ms = (((host.engine.truePlayhead(deck) ?: host.engine.position(deck)) * 1000).toLong()).toInt()
                        if (host.cues.setCue(songId, slot, maxOf(0, ms))) rev++
                    }
                    .padding(horizontal = 8.dp, vertical = 4.dp)
                    .testTag("$a11y-drop-cue"),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(Icons.Filled.Flag, null, tint = DeckColors.gold.copy(alpha = if (free == null) 0.4f else 1f), modifier = Modifier.size(12.dp))
                Text("Cue", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = DeckColors.gold.copy(alpha = if (free == null) 0.4f else 1f))
            }
        }
        // NO testTag on the grid container: a tag on a container would hide each `deck-X-cue-N`.
        cues.chunked(4).forEach { rowCues ->
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                rowCues.forEach { cue ->
                    val color = Color(CueSlotColors.argb(cue.slot))
                    Column(
                        Modifier
                            .weight(1f)
                            .heightIn(min = 26.dp)
                            .clip(RoundedCornerShape(6.dp))
                            .background(color.copy(alpha = 0.22f))
                            .border(1.dp, color, RoundedCornerShape(6.dp))
                            .clickable { host.engine.seek(deck, cue.positionMs / 1000.0) }
                            .padding(vertical = 3.dp, horizontal = 2.dp)
                            .testTag("$a11y-cue-${cue.slot}")
                            .semantics { contentDescription = "Jump to cue ${cue.slot + 1}${cue.name?.let { ", $it" } ?: ""}, ${DeckControlMath.cueClock(cue.positionMs)}" },
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text(cue.name ?: "${cue.slot + 1}", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = color, maxLines = 1)
                        Text(DeckControlMath.cueClock(cue.positionMs), fontSize = 9.sp, color = color.copy(alpha = 0.85f), fontFamily = FontFamily.Monospace)
                    }
                }
                repeat(4 - rowCues.size) { Box(Modifier.weight(1f)) }
            }
        }
    }
}

/** Lead · Sync · Stems · ∞ · (space) · Cue · ↺ (tap reset, long-press eject). */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TransportRow(
    host: DeckHost, deck: Deck, hasTrack: Boolean, stemmed: Boolean, loadingStems: Boolean, stemModeOn: Boolean,
    compact: Boolean, a11y: String,
) {
    val engine = host.engine
    val ui by engine.ui.collectAsState()
    val isLead = ui.leadDeck == deck
    val canSync = remember(ui) { engine.canSync(deck) }
    var ejectMenu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ChipButton(
            label = if (compact) null else "Lead", icon = if (isLead) Icons.Filled.Star else Icons.Filled.StarBorder,
            on = isLead, tint = DeckColors.accent, tag = "$a11y-lead", desc = "Lead",
            stateText = if (isLead) "selected" else null,
        ) { engine.setLead(deck) }
        ChipButton(
            label = if (compact) null else "Sync", icon = Icons.Filled.Sync, on = false, enabled = canSync,
            tint = DeckColors.gold, tag = "$a11y-sync", desc = "Sync",
        ) { engine.syncToLead(deck) }
        if (stemmed) {
            ChipButton(
                label = if (compact || loadingStems) null else "Stems", icon = Icons.Filled.GridView, on = stemModeOn,
                tint = DeckColors.accent, tag = "$a11y-stemmode", desc = "Stems", spinner = loadingStems,
            ) { host.stems.setStemMode(!stemModeOn, deck) }
        }
        LoopChip(engine, host.loops, deck, hasTrack, "$a11y-loop")
        Box(Modifier.weight(1f))
        CueButton(engine, deck, hasTrack, "$a11y-cue")
        Box {
            Box(
                Modifier
                    .clip(RoundedCornerShape(7.dp))
                    .border(1.dp, DeckColors.accent.copy(alpha = if (hasTrack) 1f else 0.3f), RoundedCornerShape(7.dp))
                    .combinedClickable(enabled = hasTrack, onClick = { engine.resetDeck(deck) }, onLongClick = { ejectMenu = true })
                    .padding(vertical = 6.dp, horizontal = 9.dp)
                    .testTag("$a11y-restart")
                    .semantics { contentDescription = "Reset deck" },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.Refresh, null, tint = DeckColors.accent.copy(alpha = if (hasTrack) 1f else 0.3f), modifier = Modifier.size(20.dp)) }
            DropdownMenu(expanded = ejectMenu, onDismissRequest = { ejectMenu = false }) {
                DropdownMenuItem(
                    text = { Text("Clear deck (eject track)") },
                    leadingIcon = { Icon(Icons.Filled.Eject, null) },
                    onClick = { ejectMenu = false; engine.clearDeck(deck) },
                    modifier = Modifier.testTag("$a11y-clear"),
                )
            }
        }
    }
}

@Composable
private fun ChipButton(
    label: String?, icon: androidx.compose.ui.graphics.vector.ImageVector, on: Boolean, tint: Color, tag: String, desc: String,
    enabled: Boolean = true, spinner: Boolean = false, stateText: String? = null, onClick: () -> Unit,
) {
    val c = if (!enabled) DeckColors.dim.copy(alpha = 0.4f) else if (on) tint else DeckColors.dim
    Row(
        Modifier
            .deckChip(on, tint)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp)
            .testTag(tag)
            .semantics { contentDescription = desc; if (stateText != null) stateDescription = stateText else if (on) stateDescription = "On" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (spinner) CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = c)
        else Icon(icon, null, tint = c, modifier = Modifier.size(16.dp))
        if (label != null) Text(label, fontSize = 12.sp, fontWeight = FontWeight.Medium, color = c)
    }
}

/** The FX RACK: 2×2 slot chips, any effect per slot, duplicates allowed. */
@Composable
private fun FxGrid(host: DeckHost, deck: Deck, a11y: String) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        (0 until FxRack.SLOT_COUNT).chunked(2).forEach { rowIdx ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                rowIdx.forEach { i ->
                    FxSlotChip(host.engine, deck, i, "$a11y-fx-slot-$i", Modifier.weight(1f), host.onMod)
                }
            }
        }
    }
}

/** 2×2 stem grid — only composed in stem mode. */
@Composable
private fun StemGrid(host: DeckHost, deck: Deck, a11y: String) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        BurnFileNames.STEM_NAMES.chunked(2).forEach { names ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                names.forEach { n -> StemPad(host.engine, host.stems, deck, n, "$a11y-stem-$n", Modifier.weight(1f)) }
            }
        }
    }
}

/** Vol 0–200%; gold "+N dB" above unity; a drag within 0.03 of unity snaps to exactly 100%. */
@Composable
private fun VolSlider(engine: MixEngine, deck: Deck, v: Double, a11y: String) {
    val r = DeckControlMath.volReadout(v)
    DeckSlider(
        title = "Vol", display = r.text, value = v, range = MixRanges.volume, step = 0.05, tag = "$a11y-vol",
        tint = if (r.boosted) DeckColors.gold else DeckColors.accent,
        valueColor = if (r.boosted) DeckColors.gold else DeckColors.fg,
        spokenValue = r.spoken,
    ) { engine.setVolume(DeckControlMath.snapVolume(it), deck) }
}

@Composable
private fun PlayButton(engine: MixEngine, deck: Deck, enabled: Boolean, playing: Boolean, buffering: Boolean, a11y: String) {
    val c = DeckColors.accent.copy(alpha = if (enabled) 1f else 0.3f)
    Box(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .border(1.dp, c, RoundedCornerShape(8.dp))
            .clickable(enabled = enabled) { engine.togglePlay(deck) }
            .padding(vertical = 6.dp)
            .heightIn(min = 22.dp)
            .testTag("$a11y-play")
            .semantics { contentDescription = if (playing) "Pause" else "Play" },
        contentAlignment = Alignment.Center,
    ) {
        if (playing && buffering) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = c)
        else Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, null, tint = c, modifier = Modifier.size(24.dp))
    }
}
