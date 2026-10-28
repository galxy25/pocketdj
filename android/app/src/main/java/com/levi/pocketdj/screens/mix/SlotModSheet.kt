package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.mix.engine.MixEngine
import com.levi.pocketdj.mix.engine.ModMath
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.FxParams
import com.levi.pocketdj.mix.model.LoadedTrack
import com.levi.pocketdj.mix.model.ModRate
import com.levi.pocketdj.mix.model.ModShape
import com.levi.pocketdj.mix.model.ModSource
import com.levi.pocketdj.mix.model.SlotMod
import kotlin.math.floor
import kotlin.math.roundToInt

/** Copy + small rules for the MOD sheet (pure, JVM-tested). */
object SlotModSheetRules {
    const val PHASE_STEP = 0.25

    /** Reverb / Compressor are scoped out; the sheet says so instead of hiding the button. */
    fun unsupportedNote(effect: Effect): String? =
        if (FxParams.modulates(effect) == null) "Modulation isn't available for ${effect.label} yet." else null

    /** Rate chip label: "1 bar", with " est." when the grid is the catalog-BPM lattice. */
    fun rateLabel(rate: ModRate, track: LoadedTrack?): String =
        rate.label + if (ModMath.isEstimated(track)) " est." else ""

    /** Grid honesty hint under the LFO row: warning with no BPM at all, note when only estimated. */
    fun gridHint(track: LoadedTrack?): String? = when {
        ModMath.hasNoGrid(track) -> "No BPM for this track — the LFO has nothing to lock to."
        ModMath.isEstimated(track) -> "No measured beat grid — locked to the catalog BPM (est.)."
        else -> null
    }

    fun envelopeNote(depth: Double): String =
        if (depth >= 0) "Louder passages push the effect harder." else "Louder passages DUCK the effect."

    fun depthLabel(depth: Double): String {
        val pct = (depth * 100).roundToInt()
        return (if (pct >= 0) "+" else "") + "$pct%"
    }

    fun phaseLabel(phase: Double): String = "φ ${(phase * 100).roundToInt()}%"

    /** Tap steps the cycle-phase offset by a quarter cycle, wrapping into 0..<1. */
    fun nextPhase(phase: Double): Double {
        val n = phase + PHASE_STEP
        return n - floor(n)
    }

    fun withSource(m: SlotMod, s: ModSource) = m.copy(source = s)
}

/**
 * The modulation sheet for one rack slot: source (Off / LFO / Env), then the LFO's musical rate,
 * shape and phase offset, and the signed depth. Closes on an outside tap (no idle timer: it hosts menus).
 */
@Composable
fun SlotModSheet(engine: MixEngine, deck: Deck, index: Int, tag: String, onDismiss: () -> Unit) {
    val ui by engine.ui.collectAsState()
    val d = ui.deck(deck)
    val slot = d.slots.getOrNull(index)
    if (slot == null) {
        androidx.compose.runtime.LaunchedEffect(Unit) { onDismiss() }
        return
    }
    val mod = slot.mod
    val track = d.loaded
    val set = { m: SlotMod -> engine.setSlotMod(m, index, deck) }
    DeckPopover(onDismiss = onDismiss, idleDismissMs = 0, width = 300, tag = "$tag-mod-sheet") {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Icon(Icons.Filled.Timeline, null, tint = DeckColors.accent, modifier = Modifier.size(14.dp))
                Text("Slot ${index + 1} · Modulation", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = DeckColors.accent)
            }
            val unsupported = SlotModSheetRules.unsupportedNote(slot.effect)
            if (unsupported != null) {
                Text(unsupported, fontSize = 12.sp, color = DeckColors.dim, modifier = Modifier.testTag("$tag-mod-unsupported"))
                return@Column
            }
            SourceRow(mod.source, tag) { set(SlotModSheetRules.withSource(mod, it)) }
            if (mod.source == ModSource.LFO) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PickerChip(SlotModSheetRules.rateLabel(mod.rate, track), "$tag-mod-rate", "Rate") { close ->
                        ModRate.entries.forEach { r ->
                            DropdownMenuItem(
                                text = { Text(r.label) },
                                leadingIcon = { if (r == mod.rate) Icon(Icons.Filled.Check, null) },
                                onClick = { set(mod.copy(rate = r)); close() },
                                modifier = Modifier.testTag("$tag-mod-rate-${r.raw}"),
                            )
                        }
                    }
                    PickerChip(mod.shape.label, "$tag-mod-shape", "Shape") { close ->
                        ModShape.entries.forEach { sh ->
                            DropdownMenuItem(
                                text = { Text(sh.label) },
                                leadingIcon = { if (sh == mod.shape) Icon(Icons.Filled.Check, null) },
                                onClick = { set(mod.copy(shape = sh)); close() },
                                modifier = Modifier.testTag("$tag-mod-shape-${sh.raw}"),
                            )
                        }
                    }
                    Box(Modifier.weight(1f))
                    val shape = RoundedCornerShape(5.dp)
                    Text(
                        SlotModSheetRules.phaseLabel(mod.phase), fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
                        color = DeckColors.accent,
                        modifier = Modifier
                            .background(DeckColors.overlay, shape).border(1.dp, DeckColors.border, shape)
                            .clickable { set(mod.copy(phase = SlotModSheetRules.nextPhase(mod.phase))) }
                            .padding(horizontal = 6.dp, vertical = 4.dp)
                            .testTag("$tag-mod-phase")
                            .semantics { contentDescription = "Cycle phase offset — tap to step by a quarter cycle" },
                    )
                }
                SlotModSheetRules.gridHint(track)?.let {
                    Text(it, fontSize = 11.sp, color = DeckColors.dim, modifier = Modifier.testTag("$tag-mod-grid-hint"))
                }
            }
            if (mod.source != ModSource.OFF) {
                DeckSlider(
                    title = "Depth", display = SlotModSheetRules.depthLabel(mod.depth), value = mod.depth,
                    range = -1.0..1.0, step = 0.05, tag = "$tag-mod-depth",
                ) { set(mod.copy(depth = it)) }
                if (mod.source == ModSource.ENVELOPE) {
                    Text(SlotModSheetRules.envelopeNote(mod.depth), fontSize = 11.sp, color = DeckColors.dim,
                        modifier = Modifier.testTag("$tag-mod-env-note"))
                }
            }
        }
    }
}

@Composable
private fun SourceRow(source: ModSource, tag: String, onPick: (ModSource) -> Unit) {
    val shape = RoundedCornerShape(7.dp)
    Row(Modifier.fillMaxWidth().border(BorderStroke(1.dp, DeckColors.border), shape)) {
        ModSource.entries.forEach { s ->
            val on = s == source
            Box(
                Modifier.weight(1f)
                    .background(if (on) DeckColors.accent.copy(alpha = 0.3f) else DeckColors.overlay, shape)
                    .clickable { onPick(s) }
                    .padding(vertical = 7.dp)
                    .testTag("$tag-mod-source-${s.raw}")
                    .semantics { contentDescription = "${s.label} modulation source"; stateDescription = if (on) "selected" else "" },
                contentAlignment = Alignment.Center,
            ) { Text(s.label, fontSize = 12.sp, color = if (on) DeckColors.accent else DeckColors.dim, fontWeight = FontWeight.Medium) }
        }
    }
}

@Composable
private fun PickerChip(
    text: String, tag: String, description: String,
    items: @Composable (close: () -> Unit) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(5.dp)
    Box {
        Row(
            Modifier.background(DeckColors.overlay, shape).border(1.dp, DeckColors.border, shape)
                .clickable { open = true }.padding(horizontal = 6.dp, vertical = 4.dp)
                .testTag(tag).semantics { contentDescription = description; stateDescription = text },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(text, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = DeckColors.accent, maxLines = 1)
            Icon(Icons.Filled.ArrowDropDown, null, tint = DeckColors.accent, modifier = Modifier.size(12.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) { items { open = false } }
    }
}
