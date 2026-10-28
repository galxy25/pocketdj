package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.mix.engine.MixEngine
import com.levi.pocketdj.mix.model.Deck

/** CUE / PFL: tap monitors this deck on the cue channel; long-press dials the cue level. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun CueButton(engine: MixEngine, deck: Deck, enabled: Boolean, tag: String, modifier: Modifier = Modifier) {
    val ui by engine.ui.collectAsState()
    val ds = ui.deck(deck)
    val on = ds.cued
    var show by remember { mutableStateOf(false) }
    Box(modifier) {
        Box(
            Modifier
                .deckChip(on, DeckColors.gold)
                .combinedClickable(enabled = enabled, onClick = { engine.toggleCue(deck) }, onLongClick = { show = true })
                .padding(vertical = 6.dp, horizontal = 9.dp)
                .testTag(tag)
                .semantics { contentDescription = "Cue"; stateDescription = if (on) "On" else "Off" },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.Headphones, null, modifier = Modifier.size(20.dp),
                tint = if (!enabled) DeckColors.dim.copy(alpha = 0.4f) else if (on) DeckColors.gold else DeckColors.dim,
            )
        }
        if (show) {
            ChipStrengthPopover(
                title = "Cue level", tint = DeckColors.gold, value = ds.cueVol, step = 0.05,
                tag = "$tag-vol", onDismiss = { show = false },
            ) { engine.setCueVolume(it, deck) }
        }
    }
}
