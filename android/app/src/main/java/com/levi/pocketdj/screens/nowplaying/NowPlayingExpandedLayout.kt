package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Wide / landscape Now Playing: the platter column is centered, the played flank sits to its left,
 * the up-next flank to its right. Each flank scrolls independently so a 200-row queue never stretches the deck.
 */
@Composable
fun NowPlayingExpandedLayout(
    played: @Composable () -> Unit,
    center: @Composable () -> Unit,
    upNext: @Composable () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(modifier.fillMaxSize().padding(horizontal = 12.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState())) { played() }
        Column(
            Modifier.weight(1.4f).fillMaxHeight().verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) { center() }
        Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState())) { upNext() }
    }
}
