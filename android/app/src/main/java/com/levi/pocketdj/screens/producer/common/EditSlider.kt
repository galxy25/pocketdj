package com.levi.pocketdj.screens.producer.common

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/** Formatting shared by the Producer screens (iOS StudioFmt). */
object StudioFmt {
    /** 83_400 ms -> "1:23.4". */
    fun mmssTenths(ms: Int): String {
        val t = (ms.coerceAtLeast(0) / 100)
        val tenths = t % 10; val s = (t / 10) % 60; val m = t / 600
        return "$m:${s.toString().padStart(2, '0')}.$tenths"
    }

    /** 83_400 ms -> "1:23". */
    fun mmss(ms: Int): String {
        val s = ms.coerceAtLeast(0) / 1000
        return "${s / 60}:${(s % 60).toString().padStart(2, '0')}"
    }

    /** 120.0 -> "120", 120.5 -> "120.5". */
    fun trim(v: Double): String = if (v == Math.rint(v)) v.toLong().toString() else "%.1f".format(java.util.Locale.US, v)

    /** Snap a slider value to [step] from [min]. */
    fun snap(v: Double, min: Double, step: Double): Double =
        if (step <= 0) v else min + Math.round((v - min) / step) * step
}

/**
 * One labelled slider row with a live value readout (iOS StudioEditSlider). [step] snaps the value;
 * [onChange] fires continuously while dragging (the host applies it live AND persists, debounced).
 */
@Composable
fun EditSlider(
    title: String,
    range: ClosedFloatingPointRange<Double>,
    value: Double,
    format: (Double) -> String,
    tag: String,
    modifier: Modifier = Modifier,
    step: Double = 0.0,
    onChange: (Double) -> Unit,
) {
    Column(modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = MaterialTheme.typography.labelLarge)
            Text(format(value), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.width(88.dp), maxLines = 1)
        }
        Slider(
            value = value.coerceIn(range.start, range.endInclusive).toFloat(),
            onValueChange = { raw -> onChange(StudioFmt.snap(raw.toDouble(), range.start, step).coerceIn(range.start, range.endInclusive)) },
            valueRange = range.start.toFloat()..range.endInclusive.toFloat(),
            modifier = Modifier.testTag(tag).semantics { contentDescription = "$title ${format(value)}" },
        )
    }
}

@Suppress("unused")
private fun Double.pct() = "${(this * 100).roundToInt()}%"
