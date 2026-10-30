package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.Density
import com.levi.pocketdj.mix.model.LoadedTrack
import kotlinx.coroutines.delay
import java.util.Locale
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** iOS `Theme` colors the deck needs beyond the Material scheme (apple/PocketDJ/Support/Theme.swift). */
object DeckColors {
    val accent = Color(0xFF6EA8FF)
    val gold = Color(0xFFFFCE6E)
    val danger = Color(0xFFFF6E8A)
    val raised = Color(0xFF131A2B)
    val overlay = Color(0xFF1B2540)
    val border = Color(0xFF283250)
    val fg = Color(0xFFE8ECF6)
    val dim = Color(0xFF97A2C0)

    val stemRed = Color(0xFFFF453A)
    val stemYellow = Color(0xFFFFD60A)
    val stemGreen = Color(0xFF30D158)
    val stemPurple = Color(0xFFBF5AF2)

    /** bass red · drums yellow · other green · vocals purple. */
    fun stem(name: String): Color = when (name) {
        "bass" -> stemRed
        "drums" -> stemYellow
        "other" -> stemGreen
        "vocals" -> stemPurple
        else -> accent
    }
}

/**
 * Pure formatting + control math for the deck (iOS `DeckView` / `DeckSlider` / `MixKnob` /
 * `DeckVUMeter`). Everything a JVM test can pin lives here, never in a composable.
 */
object DeckControlMath {
    // ---- labels --------------------------------------------------------------------------

    /** Measured grid BPM (one decimal) when present, else rounded catalog BPM, else null. */
    fun bpmLabel(t: LoadedTrack): String? {
        t.gridBpm?.takeIf { it > 0 }?.let { return String.format(Locale.US, "%.1f BPM", it) }
        t.bpm?.takeIf { it > 0 }?.let { return "${it.roundToInt()} BPM" }
        return null
    }

    fun tempoLabel(rate: Double): String = String.format(Locale.US, "%.2f×", rate)

    fun pitchLabel(semitones: Double): String =
        if (semitones == 0.0) "0" else String.format(Locale.US, "%+.1f", semitones)

    fun eqLabel(db: Double): String = if (db == 0.0) "0" else String.format(Locale.US, "%+.0f", db)

    /** Above this the Vol readout is a boost (gold + "+N dB"). */
    const val UNITY_EPS = 0.0001
    const val UNITY_SNAP = 0.03

    data class VolReadout(val percent: Int, val boosted: Boolean, val dB: Double, val text: String, val spoken: String)

    /** "100%" at/below unity; "150% · +3.5dB" above. */
    fun volReadout(v: Double): VolReadout {
        val pct = (v * 100).roundToInt()
        val boosted = v > 1.0 + UNITY_EPS
        val dB = 20 * log10(max(v, 0.0001))
        val dbStr = String.format(Locale.US, "%.1f", dB)
        return VolReadout(
            pct, boosted, dB,
            text = if (boosted) "$pct% · +${dbStr}dB" else "$pct%",
            spoken = if (boosted) "$pct percent, plus $dbStr decibels" else "$pct percent",
        )
    }

    /** A Vol drag within [UNITY_SNAP] of 100% lands on exactly unity. */
    fun snapVolume(v: Double): Double = if (abs(v - 1.0) < UNITY_SNAP) 1.0 else v

    /** m:ss for a playhead / duration in seconds. */
    fun clock(s: Double): String {
        if (!s.isFinite() || s < 0) return "0:00"
        val t = s.roundToInt()
        return String.format(Locale.US, "%d:%02d", t / 60, t % 60)
    }

    /** m:ss for a cue chip (ms, truncating like iOS integer division). */
    fun cueClock(ms: Int): String {
        val s = max(0, ms) / 1000
        return String.format(Locale.US, "%d:%02d", s / 60, s % 60)
    }

    fun percentLabel(v: Double): String = "${(v * 100).roundToInt()}%"

    // ---- steppers ------------------------------------------------------------------------

    fun stepTarget(inc: Boolean, value: Double, range: ClosedFloatingPointRange<Double>, step: Double): Double =
        if (inc) min(range.endInclusive, value + step) else max(range.start, value - step)

    fun stepEnabled(inc: Boolean, value: Double, range: ClosedFloatingPointRange<Double>): Boolean =
        if (inc) value < range.endInclusive - 1e-9 else value > range.start + 1e-9

    // ---- knob ----------------------------------------------------------------------------

    const val KNOB_SWEEP_DEG = 270.0
    const val KNOB_PIXELS_FULL_SWEEP = 120.0

    fun normalized(value: Double, range: ClosedFloatingPointRange<Double>): Double {
        val span = range.endInclusive - range.start
        return if (span > 0) ((value - range.start) / span).coerceIn(0.0, 1.0) else 0.5
    }

    /** Needle angle in degrees from straight up, -135 … +135. */
    fun knobAngle(value: Double, range: ClosedFloatingPointRange<Double>): Double =
        -KNOB_SWEEP_DEG / 2 + normalized(value, range) * KNOB_SWEEP_DEG

    /** Vertical drag (up = negative dy px) from the gesture's ORIGIN value; never compounds. */
    fun knobValue(origin: Double, totalDy: Double, range: ClosedFloatingPointRange<Double>): Double {
        val span = range.endInclusive - range.start
        return (origin + (-totalDy / KNOB_PIXELS_FULL_SWEEP) * span).coerceIn(range.start, range.endInclusive)
    }

    /** TalkBack increment/decrement: 1/20 of the span. */
    /** iOS `engine.stemModeOn`: a pending handover decides (TO_STEMS on, TO_FULL_MIX off), else the committed mode. */
    fun stemChipOn(handover: com.levi.pocketdj.mix.engine.StemHandover?, committed: Boolean): Boolean = when (handover) {
        com.levi.pocketdj.mix.engine.StemHandover.TO_STEMS -> true
        com.levi.pocketdj.mix.engine.StemHandover.TO_FULL_MIX -> false
        null -> committed
    }

    /** Seek step for TalkBack increase/decrease: max(1, duration/20) seconds (iOS). */
    fun seekStep(duration: Double): Double = max(1.0, duration / 20)

    fun knobAdjust(value: Double, up: Boolean, range: ClosedFloatingPointRange<Double>): Double {
        val step = (range.endInclusive - range.start) / 20
        return if (up) min(value + step, range.endInclusive) else max(value - step, range.start)
    }

    // ---- seek slider ---------------------------------------------------------------------

    fun liveFraction(position: Double, duration: Double): Double =
        if (duration > 0) (position / duration).coerceIn(0.0, 1.0) else 0.0

    /** The finger while dragging, else the live playhead. */
    fun shownFraction(drag: Double?, position: Double, duration: Double): Double =
        drag ?: liveFraction(position, duration)

    fun fractionAt(x: Float, width: Float): Double = if (width > 0) (x / width).toDouble().coerceIn(0.0, 1.0) else 0.0

    // ---- VU meter ------------------------------------------------------------------------

    const val VU_FLOOR_DB = -48f
    const val VU_TOP_DB = 3f
    const val VU_BLUE_END = 0.706f
    const val VU_GOLD_START = 0.716f
    const val VU_GOLD_END = 0.882f
    const val VU_PINK_START = 0.892f

    fun amplitudeDb(amp: Float): Float = 20f * log10(max(amp, 1e-6f))

    /** Linear amplitude -> 0..1 bar position on the -48..+3 dBFS window. */
    fun vuNorm(amp: Float): Float = ((amplitudeDb(amp) - VU_FLOOR_DB) / (VU_TOP_DB - VU_FLOOR_DB)).coerceIn(0f, 1f)

    /** "−∞" at/below the floor, else "+N dB" (iOS "%+.0f dB" with a true minus). */
    fun peakDbLabel(peakDb: Float): String =
        if (peakDb <= VU_FLOOR_DB) "−∞" else String.format(Locale.US, "%+.0f dB", peakDb.toDouble())

    fun vuHot(peakDb: Float): Boolean = peakDb >= -1f

    /** A tap older than 0.3 s reads as silence. */
    fun vuLive(updatedAtNanos: Long, nowNanos: Long): Boolean =
        updatedAtNanos != 0L && (nowNanos - updatedAtNanos) < 300_000_000L

    /** Reveal width: nothing at silence, a 3 px minimum once there is signal. */
    fun vuFillWidth(fillPx: Float): Float = if (fillPx < 1f) 0f else max(3f, fillPx)

    // ---- loop ----------------------------------------------------------------------------

    fun loopUnitName(usesBeats: Boolean) = if (usesBeats) "beat" else "sec"

    fun loopLengthLabel(units: Double, usesBeats: Boolean): String {
        val n = units.toInt()
        return "$n ${loopUnitName(usesBeats)}${if (n == 1) "" else "s"}" + if (usesBeats) "" else " — no beat grid on this track"
    }

    fun loopSpokenValue(on: Boolean, units: Double, usesBeats: Boolean): String =
        if (on) "On, ${units.toInt()} ${if (usesBeats) "beats" else "seconds"}" else "Off"

    // ---- cue points ----------------------------------------------------------------------

    const val MAX_CUES = 8

    fun nextFreeCueSlot(used: Set<Int>): Int? = (0 until MAX_CUES).firstOrNull { it !in used }
}

// ============================================================================================
// Composables
// ============================================================================================

private val ChipShape = RoundedCornerShape(7.dp)

/** Filled/outlined chip surface shared by Lead / Stems / Loop / Cue / FX chips. */
fun Modifier.deckChip(on: Boolean, tint: Color = DeckColors.accent, fill: Float = 0.25f): Modifier =
    this
        .clip(ChipShape)
        .background(if (on) tint.copy(alpha = fill) else DeckColors.overlay, ChipShape)
        .border(BorderStroke(1.dp, if (on) tint else DeckColors.border), ChipShape)

/** −/＋ fine-adjust button flanking a slider. */
@Composable
fun StepButton(
    inc: Boolean,
    value: Double,
    range: ClosedFloatingPointRange<Double>,
    step: Double,
    tag: String,
    onChange: (Double) -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = DeckColors.accent,
    onInteract: () -> Unit = {},
) {
    val enabled = DeckControlMath.stepEnabled(inc, value, range)
    Box(
        modifier = modifier
            .size(24.dp)
            .clip(RoundedCornerShape(5.dp))
            .background(DeckColors.overlay)
            .combinedClickableSimple(enabled) {
                onChange(DeckControlMath.stepTarget(inc, value, range, step)); onInteract()
            }
            .testTag("$tag-${if (inc) "inc" else "dec"}")
            .semantics { contentDescription = if (inc) "Increase" else "Decrease" },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            if (inc) Icons.Filled.Add else Icons.Filled.Remove, null,
            tint = if (enabled) tint else DeckColors.dim, modifier = Modifier.size(14.dp),
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
fun Modifier.combinedClickableSimple(enabled: Boolean = true, onClick: () -> Unit): Modifier =
    this.combinedClickable(enabled = enabled, onClick = onClick)

/** A value <-> slider-position mapping for [DeckSlider]. */
interface SliderMapping {
    val sliderRange: ClosedFloatingPointRange<Double>
    fun toSlider(value: Double): Double
    fun fromSlider(position: Double): Double
}

/**
 * Tempo 0.5x..2.0x on a log2 track: 0.5x, 1.00x and 2.0x sit at left, centre and right (a linear
 * 0.5..2.0 track put 1.00x at a third, unlike Pitch 0 at centre). Near-centre drags snap to 1.00x.
 */
object TempoSliderMapping : SliderMapping {
    override val sliderRange: ClosedFloatingPointRange<Double> = -1.0..1.0
    const val SNAP = 0.015
    override fun toSlider(value: Double): Double = kotlin.math.ln(value.coerceAtLeast(1e-6)) / kotlin.math.ln(2.0)
    override fun fromSlider(position: Double): Double {
        if (kotlin.math.abs(position) < SNAP) return 1.0
        val v = Math.pow(2.0, position.coerceIn(-1.0, 1.0))
        return Math.round(v * 100) / 100.0
    }
}

/** Labelled slider (title + live value) flanked by −/＋ steppers. Pushes straight into the engine. */
@Composable
fun DeckSlider(
    title: String,
    display: String,
    value: Double,
    range: ClosedFloatingPointRange<Double>,
    step: Double,
    tag: String,
    modifier: Modifier = Modifier,
    tint: Color = DeckColors.accent,
    valueColor: Color = DeckColors.fg,
    spokenValue: String? = null,
    /** Optional value <-> slider-position mapping (Tempo: log2 so 1.00x sits mid-track like Pitch 0). */
    mapping: SliderMapping? = null,
    onChange: (Double) -> Unit,
) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(Modifier.fillMaxWidth()) {
            Text(title, fontSize = 12.sp, color = DeckColors.dim)
            Box(Modifier.weight(1f))
            Text(display, fontSize = 12.sp, color = valueColor, fontFamily = FontFamily.Monospace,
                maxLines = 1, overflow = TextOverflow.Clip)
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            StepButton(false, value, range, step, tag, onChange, tint = tint)
            val sRange = mapping?.sliderRange ?: range
            Slider(
                value = (mapping?.toSlider(value) ?: value).toFloat().coerceIn(sRange.start.toFloat(), sRange.endInclusive.toFloat()),
                onValueChange = { onChange(mapping?.fromSlider(it.toDouble()) ?: it.toDouble()) },
                valueRange = sRange.start.toFloat()..sRange.endInclusive.toFloat(),
                colors = SliderDefaults.colors(thumbColor = tint, activeTrackColor = tint, inactiveTrackColor = DeckColors.border),
                modifier = Modifier
                    .weight(1f)
                    .testTag(tag)
                    .semantics { stateDescription = spokenValue ?: display },
            )
            StepButton(true, value, range, step, tag, onChange, tint = tint)
        }
    }
}

/** Rotary knob: drag vertically (up = more). The drag is measured from the gesture's origin value. */
@Composable
fun MixKnob(
    title: String,
    display: String,
    value: Double,
    range: ClosedFloatingPointRange<Double>,
    tag: String,
    modifier: Modifier = Modifier,
    tint: Color = DeckColors.accent,
    onChange: (Double) -> Unit,
) {
    var origin by remember { mutableStateOf<Double?>(null) }
    var totalDy by remember { mutableStateOf(0.0) }
    val latest by rememberUpdatedValue(value)
    Column(
        modifier.semantics {
            contentDescription = title; stateDescription = display
            customActions = listOf(
                CustomAccessibilityAction("Increase $title") { onChange(DeckControlMath.knobAdjust(latest, true, range)); true },
                CustomAccessibilityAction("Decrease $title") { onChange(DeckControlMath.knobAdjust(latest, false, range)); true },
            )
        }.testTag(tag),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(title, fontSize = 12.sp, color = DeckColors.dim)
        Box(
            Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(DeckColors.overlay)
                .border(1.dp, DeckColors.border, CircleShape)
                .pointerInput(range) {
                    detectDragGestures(
                        onDragStart = { origin = latest; totalDy = 0.0 },
                        onDragEnd = { origin = null },
                        onDragCancel = { origin = null },
                    ) { change, drag ->
                        change.consume()
                        totalDy += drag.y
                        onChange(DeckControlMath.knobValue(origin ?: latest, totalDy, range))
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            Box(
                Modifier
                    .size(40.dp)
                    .rotate(DeckControlMath.knobAngle(value, range).toFloat()),
                contentAlignment = Alignment.TopCenter,
            ) {
                Box(Modifier.padding(top = 6.dp).size(width = 2.5.dp, height = 13.dp).background(tint, CircleShape))
            }
        }
        Text(display, fontSize = 11.sp, color = DeckColors.fg, fontFamily = FontFamily.Monospace)
    }
}

@Composable
private fun rememberUpdatedValue(v: Double) = androidx.compose.runtime.rememberUpdatedState(v)

/** Anchors a popup above its parent, centered, clamped on-screen. */
private class AboveCenterPositioner : PopupPositionProvider {
    override fun calculatePosition(anchorBounds: IntRect, windowSize: IntSize, layoutDirection: LayoutDirection, popupContentSize: IntSize): IntOffset {
        val x = (anchorBounds.center.x - popupContentSize.width / 2).coerceIn(0, max(0, windowSize.width - popupContentSize.width))
        val above = anchorBounds.top - popupContentSize.height - 8
        val y = if (above >= 0) above else anchorBounds.bottom + 8
        return IntOffset(x, y)
    }
}

/**
 * A raised popover anchored to the composable it is declared inside. [idleDismissMs] > 0 closes it
 * after that long with no [interaction] bump (iOS 3 s idle); [holding] defers the timer while a
 * drag is in flight. Outside-tap always dismisses.
 */
@Composable
fun DeckPopover(
    onDismiss: () -> Unit,
    interaction: Int = 0,
    idleDismissMs: Long = 3000,
    holding: Boolean = false,
    tag: String? = null,
    width: Int = 300,
    content: @Composable () -> Unit,
) {
    LaunchedEffect(interaction, holding, idleDismissMs) {
        if (idleDismissMs > 0 && !holding) {
            delay(idleDismissMs)
            onDismiss()
        }
    }
    Popup(
        popupPositionProvider = remember { AboveCenterPositioner() },
        onDismissRequest = onDismiss,
        properties = PopupProperties(focusable = true),
    ) {
        Surface(
            shape = RoundedCornerShape(10.dp),
            color = DeckColors.raised,
            border = BorderStroke(1.dp, DeckColors.border),
            shadowElevation = 8.dp,
            modifier = Modifier.width(width.dp).let { if (tag != null) it.testTag(tag) else it },
        ) { content() }
    }
}

/** Compact strength popover: title, [-] slider [+] and a live percent. Idle-dismiss unless [autoDismiss] is false. */
@Composable
fun ChipStrengthPopover(
    title: String,
    tint: Color,
    value: Double,
    step: Double,
    tag: String,
    onDismiss: () -> Unit,
    autoDismiss: Boolean = true,
    header: (@Composable () -> Unit)? = null,
    onChange: (Double) -> Unit,
) {
    var interaction by remember { mutableIntStateOf(0) }
    DeckPopover(onDismiss = onDismiss, interaction = interaction, idleDismissMs = if (autoDismiss) 3000 else 0, width = 290) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            header?.invoke()
            Text(title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = tint)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StepButton(false, value, 0.0..1.0, step, tag, onChange, tint = tint, onInteract = { interaction++ })
                Slider(
                    value = value.toFloat().coerceIn(0f, 1f),
                    onValueChange = { onChange(it.toDouble()); interaction++ },
                    modifier = Modifier.weight(1f).testTag(tag),
                    colors = SliderDefaults.colors(thumbColor = tint, activeTrackColor = tint, inactiveTrackColor = DeckColors.border),
                )
                StepButton(true, value, 0.0..1.0, step, tag, onChange, tint = tint, onInteract = { interaction++ })
                Text(DeckControlMath.percentLabel(value), fontSize = 12.sp, color = DeckColors.fg,
                    fontFamily = FontFamily.Monospace, modifier = Modifier.width(40.dp))
            }
        }
    }
}
