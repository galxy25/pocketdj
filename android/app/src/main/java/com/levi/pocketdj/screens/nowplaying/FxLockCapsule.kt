package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.mix.nowplaying.FxLock

/** Copy for the capsule (pure, unit-testable). There is NO status line: the state shows in the capsule's tint (Levi 2026-11-03). */
object FxLockCapsuleText {
    fun label(enabled: Boolean): String = if (enabled) "Lock on" else "Lock"

    fun description(enabled: Boolean, indicator: FxLock.Indicator): String = when {
        !enabled -> "FX Lock off"
        indicator == FxLock.Indicator.APPLIED -> "FX Lock on, effects applied"
        indicator == FxLock.Indicator.WAITING -> "FX Lock on, effects waiting for a local track"
        indicator == FxLock.Indicator.DORMANT -> "FX Lock on, paused while the Mix tab is live"
        else -> "FX Lock on"
    }
}

/**
 * The FX Lock capsule (iOS `np-mix-fx-lock`): sits at the upper right of the Effects header, the same spot the Stem
 * Lock holds in the Stems header. Tap toggles; ON carries the current effects to every following track.
 */
@Composable
fun FxLockCapsule(enabled: Boolean, indicator: FxLock.Indicator, onToggle: () -> Unit, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    val tint = if (enabled) scheme.primary else scheme.onSurfaceVariant
    val desc = FxLockCapsuleText.description(enabled, indicator)
    Surface(
        modifier = modifier.testTag("np-mix-fx-lock").semantics { contentDescription = desc; role = Role.Switch }.clickable(onClick = onToggle),
        shape = RoundedCornerShape(50),
        color = if (enabled) scheme.primary.copy(alpha = 0.12f) else scheme.surface.copy(alpha = 0f),
        border = BorderStroke(1.dp, tint.copy(alpha = if (enabled) 0.6f else 0.35f)),
    ) {
        Row(
            Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(Icons.Filled.Lock, null, Modifier.size(12.dp), tint = tint)
            Text(FxLockCapsuleText.label(enabled), fontSize = 12.sp, color = tint)
        }
    }
}
