package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.audio.dsp.LoudnessLeveling
import com.levi.pocketdj.mix.nowplaying.DjLevelingReadout
import com.levi.pocketdj.mix.nowplaying.DjLevelingText
import kotlin.math.abs

/**
 * P2-DJ-12 (iOS `DJLevelingReadoutRow`): "Leveling +3.2 dB" with a -12..+6 dB meter (0 dB tick) - the automatic trim DJ Mode
 * puts on the playing song. During a crossfade "-4.5 dB -> +3.2 dB": the outgoing's trim fading out as the incoming's comes
 * in (equal-power). Says "measuring..." / "off" / "unavailable" instead of a 0 dB that was never measured. Read-only;
 * hidden when DJ is not leveling.
 */
@Composable
fun DjLevelingReadoutRow(readout: DjLevelingReadout, modifier: Modifier = Modifier) {
    if (!readout.visible) return
    val out = readout.outgoing
    Column(
        modifier.fillMaxWidth().testTag("np-mix-leveling").semantics(mergeDescendants = true) {
            contentDescription = "Volume leveling"
            stateDescription = DjLevelingText.a11y(readout)
        },
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Leveling", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
            if (out != null) {
                Text(DjLevelingText.words(out), fontSize = 11.sp, fontFamily = FontFamily.Monospace, maxLines = 1,
                    modifier = Modifier.alpha((0.35 + 0.65 * readout.outGain).toFloat()))
                Text("→", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(DjLevelingText.words(readout.current), fontSize = 11.sp, fontFamily = FontFamily.Monospace, maxLines = 1,
                    modifier = Modifier.alpha((0.35 + 0.65 * readout.inGain).toFloat()))
            } else {
                Text(DjLevelingText.words(readout.current), fontSize = 11.sp, fontFamily = FontFamily.Monospace, maxLines = 1)
            }
        }
        LevelMeter(readout)
    }
}

/** A -12..+6 dB trim meter: bars grow from the 0 dB tick (up = turned up, down = turned down); weight scales thickness + opacity. */
@Composable
private fun LevelMeter(readout: DjLevelingReadout) {
    val track = MaterialTheme.colorScheme.surfaceVariant
    val up = MaterialTheme.colorScheme.tertiary
    val down = MaterialTheme.colorScheme.primary
    val tick = MaterialTheme.colorScheme.onSurfaceVariant
    val bars = DjLevelingText.bars(readout)
    val lo = LoudnessLeveling.MIN_GAIN_DB
    val hi = LoudnessLeveling.MAX_GAIN_DB
    Canvas(Modifier.fillMaxWidth().height(4.dp).clearAndSetSemantics { }) {
        val w = size.width
        val h = size.height
        val zero = (w * (-lo / (hi - lo))).toFloat()
        drawRoundRect(track, size = Size(w, h), cornerRadius = androidx.compose.ui.geometry.CornerRadius(h / 2))
        for (b in bars) {
            val x = (w * ((b.db.coerceIn(lo, hi) - lo) / (hi - lo))).toFloat()
            val bh = (h * (0.4 + 0.6 * b.weight)).toFloat()
            val a = if (b.live) 1f else (0.35 + 0.65 * b.weight).toFloat()
            drawRect(
                (if (b.db >= 0) up else down).copy(alpha = a),
                topLeft = Offset(minOf(x, zero), (h - bh) / 2), size = Size(maxOf(1f, abs(x - zero)), bh),
            )
        }
        drawRect(tick, topLeft = Offset(zero, 0f), size = Size(1f, h))
    }
}
