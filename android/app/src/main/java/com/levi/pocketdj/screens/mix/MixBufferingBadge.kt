package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Streaming mode's "Buffering…" capsule; the same capsule says "Loading stems…" during a stem handover. */
@Composable
fun MixBufferingBadge(
    modifier: Modifier = Modifier,
    text: String = "Buffering…",
    tag: String = "mix-buffering",
) {
    Row(
        modifier
            .background(DeckColors.overlay, CircleShape)
            .padding(horizontal = 8.dp, vertical = 3.dp)
            .testTag(tag)
            .semantics(mergeDescendants = true) { contentDescription = text.replace("…", "") },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp, color = DeckColors.dim)
        Text(text, fontSize = 12.sp, color = DeckColors.dim)
    }
}
