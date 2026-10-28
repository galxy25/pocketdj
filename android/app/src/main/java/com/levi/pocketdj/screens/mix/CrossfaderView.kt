package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.mix.engine.MixEngine

/** The single equal-power crossfader spanning both decks (A ◀ ▶ B), 0…1. */
@Composable
fun CrossfaderView(engine: MixEngine, modifier: Modifier = Modifier) {
    val ui by engine.ui.collectAsState()
    Surface(
        modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp), color = DeckColors.raised,
        border = BorderStroke(1.dp, DeckColors.border),
    ) {
        Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Crossfader", fontSize = 12.sp, color = DeckColors.dim)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("A", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = DeckColors.accent)
                Slider(
                    value = ui.crossfader.toFloat().coerceIn(0f, 1f),
                    onValueChange = { engine.setCrossfader(it.toDouble()) },
                    modifier = Modifier.weight(1f).testTag("crossfader"),
                    colors = SliderDefaults.colors(thumbColor = DeckColors.gold, activeTrackColor = DeckColors.gold, inactiveTrackColor = DeckColors.border),
                )
                Text("B", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = DeckColors.accent)
            }
        }
    }
}
