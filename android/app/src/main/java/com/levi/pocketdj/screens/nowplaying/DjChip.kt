package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.ParityFlags
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.dj.DjMode

/**
 * The DJ status words as pure data (JVM-tested). iOS appends the DJ indicator's `chipText` to the Mix Mode chip
 * (`[mix text, dj, note]` joined with " · ") and says "SharePlay session" for a Remote suspension; Android's
 * Remote session is not SharePlay, so the suspended words differ (roadmap P2-DJ-6).
 */
object DjChipText {
    const val PAUSED_REMOTE = "DJ — paused · Remote session"
    const val PAUSED_MIX_TAB = "DJ — paused · Mix tab"

    /** The DJ words for [indicator]; null when DJ shows nothing (off). */
    fun words(indicator: DjMode.Indicator): String? = when (indicator) {
        DjMode.Indicator.SuspendedRemote -> PAUSED_REMOTE
        DjMode.Indicator.Suspended -> PAUSED_MIX_TAB
        else -> indicator.chipText
    }

    /** The Mix Mode chip's trailing note: DJ words first, then the edition note (iOS `MixModeChipLabel.Content`). */
    fun mixChipNote(indicator: DjMode.Indicator, editionNote: String?): String? =
        listOfNotNull(words(indicator), editionNote).takeIf { it.isNotEmpty() }?.joinToString(" · ")

    /** TalkBack value of the DJ switch (iOS: "On, mixing N percent" while a transition runs). */
    fun switchValue(on: Boolean, crossfade: Float?): String = when {
        !on -> "Off"
        crossfade != null -> "On, mixing ${Math.round(crossfade.coerceIn(0f, 1f) * 100)} percent"
        else -> "On"
    }

    /** The chip floor's fill: 0..1 over the crossfade, never narrower than a sliver while it runs (iOS `max(0.04, x)`). */
    fun floorFraction(crossfade: Float): Float = crossfade.coerceIn(0f, 1f).coerceAtLeast(0.04f)
}

/**
 * The DJ MODE capsule switch (`np-dj-mode`), LEFT of the Mix Mode chip. Session state like Mix Mode (which it turns
 * on). [crossfade] is non-null while a transition runs: it fills the capsule's floor from 0 to 1. Renders nothing
 * until [ParityFlags.DJ_MODE].
 */
@Composable
fun NpDjModeSwitch(on: Boolean, enabled: Boolean, onToggle: (Boolean) -> Unit, modifier: Modifier = Modifier, crossfade: Float? = null) {
    if (!ParityFlags.DJ_MODE) return
    val accent = MaterialTheme.colorScheme.primary
    val tint = if (on) accent else MaterialTheme.colorScheme.onSurfaceVariant
    val mixing = on && crossfade != null
    Surface(
        shape = CircleShape,
        color = if (on) accent.copy(alpha = 0.18f) else MaterialTheme.colorScheme.surfaceVariant,
        border = BorderStroke(1.dp, if (on) accent else MaterialTheme.colorScheme.outlineVariant),
        modifier = modifier
            .testTag("np-dj-mode")
            .semantics {
                contentDescription = "DJ Mode"
                stateDescription = DjChipText.switchValue(on, if (mixing) crossfade else null)
                role = Role.Switch
            }
            .clip(CircleShape)
            .clickable(enabled = enabled) { onToggle(!on) },
    ) {
        Box {
            Text(
                "DJ", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = tint,
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            )
            if (mixing) {
                Surface(
                    Modifier.align(Alignment.BottomStart).padding(horizontal = 7.dp, vertical = 1.dp)
                        .fillMaxWidth(DjChipText.floorFraction(crossfade!!)).height(2.dp).testTag("np-dj-crossfade"),
                    shape = CircleShape, color = accent,
                ) {}
            }
        }
    }
}

/**
 * "DJ Mode" with a check: the Now Playing record menu and the mini bar's long-press menu (`np-menu-dj-mode`),
 * the sibling of [NpMixModeMenuItem]. Hidden until [ParityFlags.DJ_MODE]; disabled with no session.
 */
@Composable
fun NpDjModeMenuItem(app: AppGraph, onDone: () -> Unit) {
    if (!ParityFlags.DJ_MODE) return
    val controller = app.playbackGraph.djMode.controller
    val on by controller.state.collectAsState()
    val seq by app.playbackGraph.sequencer.state.collectAsState()
    DropdownMenuItem(
        text = { Text("DJ Mode") },
        leadingIcon = { if (on.enabled) Icon(Icons.Filled.Check, contentDescription = "On") },
        enabled = seq.isRunning,
        onClick = { controller.setDjMode(!on.enabled); onDone() },
        modifier = Modifier.testTag("np-menu-dj-mode").semantics { stateDescription = if (on.enabled) "On" else "Off" },
    )
}
