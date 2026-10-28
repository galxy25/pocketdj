package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.mix.engine.MixEngine
import com.levi.pocketdj.mix.engine.StemController
import com.levi.pocketdj.mix.model.Deck

object StemPadRules {
    fun icon(stem: String): ImageVector = when (stem) {
        "vocals" -> Icons.Filled.Mic
        "drums" -> Icons.Filled.Speed
        "bass" -> Icons.Filled.GraphicEq
        else -> Icons.Filled.MusicNote
    }

    fun title(stem: String) = stem.replaceFirstChar { it.uppercase() }
}

/** One pad of the 2×2 stem grid. TAP = mute (dims); LONG-PRESS = that stem's volume. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun StemPad(engine: MixEngine, stems: StemController, deck: Deck, stem: String, tag: String, modifier: Modifier = Modifier) {
    val ui by engine.ui.collectAsState()
    val ds = ui.deck(deck)
    val muted = stem in ds.stemMuted
    val vol = ds.stemVol[stem] ?: 1.0
    val color = DeckColors.stem(stem)
    var show by remember { mutableStateOf(false) }
    Box(modifier) {
        val shape = RoundedCornerShape(7.dp)
        Row(
            Modifier
                .fillMaxWidth()
                .background(if (muted) DeckColors.overlay else color.copy(alpha = 0.28f), shape)
                .border(1.dp, if (muted) DeckColors.border else color, shape)
                .combinedClickable(onClick = { stems.toggleStemMute(stem, deck) }, onLongClick = { show = true })
                .heightIn(min = 32.dp)
                .padding(vertical = 7.dp)
                .testTag(tag)
                .semantics { contentDescription = StemPadRules.title(stem); stateDescription = if (muted) "Muted" else "On" },
            horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(if (muted) Icons.Filled.VolumeOff else StemPadRules.icon(stem), null,
                tint = if (muted) DeckColors.dim else color, modifier = Modifier.size(16.dp))
            Text(StemPadRules.title(stem), fontSize = 12.sp, fontWeight = FontWeight.Medium, maxLines = 1,
                overflow = TextOverflow.Ellipsis, color = if (muted) DeckColors.dim else color)
        }
        if (show) {
            ChipStrengthPopover(
                title = StemPadRules.title(stem), tint = color, value = vol, step = 0.05,
                tag = "$tag-volume", onDismiss = { show = false },
            ) { stems.setStemVolume(stem, it, deck) }
        }
    }
}
