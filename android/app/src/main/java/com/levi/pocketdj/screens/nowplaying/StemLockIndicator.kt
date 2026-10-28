package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.mix.nowplaying.StemLock

/** Copy for each indicator state (pure, unit-testable). */
object StemLockIndicatorText {
    fun label(i: StemLock.Indicator): String? = when (i) {
        StemLock.Indicator.OFF -> null
        StemLock.Indicator.IDLE -> "Stem Lock: full mix"
        StemLock.Indicator.LOADING -> "Stem Lock: loading stems"
        StemLock.Indicator.ACTIVE -> "Stem Lock: stems on"
        StemLock.Indicator.UNAVAILABLE -> "Stem Lock: no stems for this track"
    }
}

/** The small status row for the lock on the CURRENT track (iOS `StemLockStatusRow`). Renders nothing when off. */
@Composable
fun StemLockIndicator(indicator: StemLock.Indicator, modifier: Modifier = Modifier) {
    val text = StemLockIndicatorText.label(indicator) ?: return
    val tint = when (indicator) {
        StemLock.Indicator.ACTIVE -> MaterialTheme.colorScheme.primary
        StemLock.Indicator.UNAVAILABLE -> MaterialTheme.colorScheme.error
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Row(
        modifier.testTag("np-stemlock-${indicator.name.lowercase()}").semantics(mergeDescendants = true) { contentDescription = text },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (indicator == StemLock.Indicator.LOADING) CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp, color = tint)
        else Icon(Icons.Filled.Lock, null, Modifier.size(12.dp), tint = tint)
        Text(text, fontSize = 12.sp, color = tint)
    }
}
