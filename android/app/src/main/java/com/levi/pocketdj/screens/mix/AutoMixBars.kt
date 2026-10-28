package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallSplit
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.mix.engine.AutoUiState

private val CARD = RoundedCornerShape(12.dp)

@Composable
private fun AutoCard(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Surface(
        modifier.fillMaxWidth(), shape = CARD, color = DeckColors.raised,
        border = BorderStroke(1.dp, DeckColors.accent.copy(alpha = 0.5f)),
    ) { Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) { content() } }
}

/**
 * Auto-mode setup row (before a mix starts): Crate A / Crate B pickers + Play / Shuffle, the error
 * line, and the FX / Mix Glide pills. In the content (not a top bar) so it is reachable on a phone.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AutoSetupBar(
    entries: MixCrateEntries,
    crateAName: String?,
    crateBName: String?,
    liveSourceLabel: String?,
    canPlay: Boolean,
    error: String?,
    fxGlide: Boolean,
    mixGlide: Boolean,
    onPickA: (com.levi.pocketdj.mix.model.MixSource?) -> Unit,
    onPickB: (com.levi.pocketdj.mix.model.MixSource?) -> Unit,
    onPlay: () -> Unit,
    onShuffle: () -> Unit,
    onFxGlide: (Boolean) -> Unit,
    onMixGlide: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    AutoCard(modifier.testTag("mix-auto-setup")) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.AutoFixHigh, null, tint = DeckColors.accent, modifier = Modifier.size(20.dp))
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            MixCrateMenu(
                entries = entries,
                labelText = MixCrateMenuState.label("A", crateAName ?: liveSourceLabel, "Pick a collection"),
                icon = Icons.Filled.Tune, onPick = onPickA, tag = "mix-auto-source",
            )
            MixCrateMenu(
                entries = entries,
                labelText = MixCrateMenuState.label("B", crateBName, "Same as A"),
                icon = Icons.AutoMirrored.Filled.CallSplit, onPick = onPickB,
                resetTitle = MixCrateMenuState.SAME_AS_A, tag = "mix-auto-source-b",
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Button(
                onClick = onPlay, enabled = canPlay,
                colors = ButtonDefaults.buttonColors(containerColor = DeckColors.accent, contentColor = Color(0xFF07101F)),
                modifier = Modifier.testTag("mix-auto-play"),
            ) {
                Icon(Icons.Filled.PlayArrow, null, Modifier.size(18.dp)); Text(" Play")
            }
            OutlinedButton(
                onClick = onShuffle, enabled = canPlay,
                modifier = Modifier.testTag("mix-auto-shuffle").semantics { contentDescription = "Shuffle" },
            ) { Icon(Icons.Filled.Shuffle, null, Modifier.size(18.dp)); Text(" Shuffle") }
        }
        if (error != null) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Filled.Warning, null, tint = DeckColors.danger, modifier = Modifier.size(16.dp))
            Text(error, color = DeckColors.danger, fontSize = 12.sp, modifier = Modifier.testTag("mix-auto-error"))
        }
        GlidePills(fxGlide, mixGlide, onFxGlide, onMixGlide)
    }
}

/** In-body banner so Stop + progress are reachable on a phone (status, Buffering badge, Pause/Resume, Stop, glide pills). */
@Composable
fun AutoMixBanner(
    auto: AutoUiState,
    buffering: Boolean,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onStop: () -> Unit,
    onFxGlide: (Boolean) -> Unit,
    onMixGlide: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    AutoCard(modifier.testTag("mix-auto-banner")) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(Icons.Filled.AutoFixHigh, null, tint = DeckColors.accent, modifier = Modifier.size(20.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        if (auto.paused) "Auto-mix paused" else "Auto-mixing",
                        color = DeckColors.fg, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                    )
                    if (buffering) MixBufferingBadge(tag = "mix-auto-buffering")
                }
                auto.status?.let { Text(it, color = DeckColors.dim, fontSize = 12.sp) }
            }
            if (auto.paused) OutlinedButton(onClick = onResume, modifier = Modifier.testTag("mix-auto-resume")) {
                Icon(Icons.Filled.PlayArrow, null, Modifier.size(16.dp)); Text(" Resume")
            } else OutlinedButton(onClick = onPause, modifier = Modifier.testTag("mix-auto-pause")) {
                Icon(Icons.Filled.Pause, null, Modifier.size(16.dp)); Text(" Pause")
            }
            OutlinedButton(onClick = onStop, modifier = Modifier.testTag("mix-auto-stop-banner")) {
                Icon(Icons.Filled.Stop, null, Modifier.size(16.dp), tint = DeckColors.danger); Text(" Stop")
            }
        }
        GlidePills(auto.fxGlide, auto.mixGlide, onFxGlide, onMixGlide)
    }
}

/** FX Glide · Mix Glide pills (arm before Play AND flip mid-mix). */
@Composable
fun GlidePills(fx: Boolean, mix: Boolean, onFx: (Boolean) -> Unit, onMix: (Boolean) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        GlidePill("FX Glide", Icons.Filled.Tune, fx, "mix-fx-glide") { onFx(!fx) }
        GlidePill("Mix Glide", Icons.Filled.AutoFixHigh, mix, "mix-mix-glide") { onMix(!mix) }
    }
}

@Composable
private fun GlidePill(title: String, icon: ImageVector, on: Boolean, tag: String, onClick: () -> Unit) {
    Row(
        Modifier
            .background(if (on) DeckColors.accent.copy(alpha = 0.22f) else DeckColors.overlay, CircleShape)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp)
            .testTag(tag)
            .semantics(mergeDescendants = true) { contentDescription = "$title ${if (on) "on" else "off"}" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(icon, null, tint = if (on) DeckColors.accent else DeckColors.dim, modifier = Modifier.size(14.dp))
        Text(title, color = if (on) DeckColors.accent else DeckColors.dim, fontSize = 12.sp, fontWeight = FontWeight.Medium)
    }
}

/**
 * Auto-Mix only: advance to the next queued track. SINGLE tap = the Settings skip fade, DOUBLE tap
 * = a fast 5 s sweep. A plain tappable surface (never a Button) counting taps through
 * `pointerInput`: [detectTapGestures] waits out the double-tap window before reporting a lone tap,
 * so a double tap fires ONLY the fast path (a Button would also fire the single on the first tap).
 */
@Composable
fun SkipButton(onSkip: (taps: Int) -> Unit, modifier: Modifier = Modifier) {
    Surface(
        modifier
            .fillMaxWidth()
            .testTag("mix-auto-skip")
            .pointerInput(onSkip) {
                detectTapGestures(onDoubleTap = { onSkip(2) }, onTap = { onSkip(1) })
            }
            .semantics(mergeDescendants = true) {
                contentDescription = "Skip to next track. Double-tap for a fast five second sweep"
                role = androidx.compose.ui.semantics.Role.Button
                onClick(label = "Skip to next") { onSkip(1); true }
                customActions = listOf(androidx.compose.ui.semantics.CustomAccessibilityAction("Fast skip") { onSkip(2); true })
            },
        shape = CARD, color = DeckColors.raised, border = BorderStroke(1.dp, DeckColors.border),
    ) {
        Row(Modifier.padding(vertical = 11.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.SkipNext, null, tint = DeckColors.accent, modifier = Modifier.size(20.dp))
            Text("  Skip to next", color = DeckColors.accent, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text("  · double-tap = fast", color = DeckColors.dim, fontSize = 12.sp)
        }
    }
}
