package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.AllInclusive
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.mix.engine.LoopController
import com.levi.pocketdj.mix.engine.LoopEdge
import com.levi.pocketdj.mix.engine.MixEngine
import com.levi.pocketdj.mix.model.Deck

/**
 * ∞ loop chip. TAP loops 2 units (beats with a grid, else seconds) off the previous boundary;
 * LONG-PRESS opens the length slider + per-edge nudges. Adjusting anything ENGAGES the loop first
 * (dialling a length you cannot hear is a dead control).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LoopChip(engine: MixEngine, loops: LoopController, deck: Deck, enabled: Boolean, tag: String, modifier: Modifier = Modifier) {
    val ui by engine.ui.collectAsState()
    val ds = ui.deck(deck)
    val on = ds.loopOn
    val usesBeats = com.levi.pocketdj.mix.engine.LoopMath.usesBeats(ds.loaded)
    var show by remember { mutableStateOf(false) }
    Box(modifier) {
        Box(
            Modifier
                .deckChip(on)
                .combinedClickable(
                    enabled = enabled,
                    onClick = { loops.setLoop(deck, !on) },
                    onLongClick = { show = true },
                )
                .padding(vertical = 6.dp, horizontal = 9.dp)
                .testTag(tag)
                .semantics {
                    contentDescription = "Loop"
                    stateDescription = DeckControlMath.loopSpokenValue(on, ds.loopUnits, usesBeats)
                },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.AllInclusive, null, modifier = Modifier.size(20.dp),
                tint = if (!enabled) DeckColors.dim.copy(alpha = 0.4f) else if (on) DeckColors.accent else DeckColors.dim,
            )
        }
        if (show) {
            LoopLengthPopover(engine, loops, deck, usesBeats, tag) { show = false }
        }
    }
}

@Composable
private fun LoopLengthPopover(engine: MixEngine, loops: LoopController, deck: Deck, usesBeats: Boolean, tag: String, onDismiss: () -> Unit) {
    val ui by engine.ui.collectAsState()
    val units = ui.deck(deck).loopUnits
    var interaction by remember { mutableIntStateOf(0) }
    var editing by remember { mutableStateOf(false) }
    fun engage() { if (!engine.deckState(deck).loopOn) loops.setLoop(deck, true) }
    DeckPopover(onDismiss = onDismiss, interaction = interaction, holding = editing, width = 320) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Filled.AllInclusive, null, tint = DeckColors.accent, modifier = Modifier.size(16.dp))
                Text("Loop length", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = DeckColors.accent)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Nudge(Icons.AutoMirrored.Filled.ArrowBack, "Loop in back one ${DeckControlMath.loopUnitName(usesBeats)}", "$tag-start-back") {
                    engage(); loops.nudgeLoop(deck, LoopEdge.START, -1.0); interaction++
                }
                Nudge(Icons.AutoMirrored.Filled.ArrowForward, "Loop in forward one ${DeckControlMath.loopUnitName(usesBeats)}", "$tag-start-fwd") {
                    engage(); loops.nudgeLoop(deck, LoopEdge.START, 1.0); interaction++
                }
                Slider(
                    value = units.toFloat().coerceIn(1f, 32f),
                    onValueChange = {
                        editing = true
                        engage(); loops.setLoopUnits(deck, Math.round(it).toDouble()); interaction++
                    },
                    onValueChangeFinished = { editing = false; interaction++ },
                    valueRange = 1f..32f, steps = 30,
                    colors = SliderDefaults.colors(thumbColor = DeckColors.accent, activeTrackColor = DeckColors.accent, inactiveTrackColor = DeckColors.border),
                    modifier = Modifier.weight(1f).testTag("$tag-length"),
                )
                Nudge(Icons.AutoMirrored.Filled.ArrowBack, "Loop out back one ${DeckControlMath.loopUnitName(usesBeats)}", "$tag-end-back") {
                    engage(); loops.nudgeLoop(deck, LoopEdge.END, -1.0); interaction++
                }
                Nudge(Icons.AutoMirrored.Filled.ArrowForward, "Loop out forward one ${DeckControlMath.loopUnitName(usesBeats)}", "$tag-end-fwd") {
                    engage(); loops.nudgeLoop(deck, LoopEdge.END, 1.0); interaction++
                }
            }
            Text(DeckControlMath.loopLengthLabel(units, usesBeats), fontSize = 12.sp, color = DeckColors.fg, fontFamily = FontFamily.Monospace)
        }
    }
}

@Composable
private fun Nudge(icon: ImageVector, desc: String, tag: String, onClick: () -> Unit) {
    Box(
        Modifier
            .size(26.dp)
            .background(DeckColors.overlay, RoundedCornerShape(6.dp))
            .clickable(onClick = onClick)
            .testTag(tag)
            .semantics { contentDescription = desc },
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, tint = DeckColors.dim, modifier = Modifier.size(14.dp)) }
}
