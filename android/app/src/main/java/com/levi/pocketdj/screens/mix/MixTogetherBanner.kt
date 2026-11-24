package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.ParityFlags
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.remote.MixTogetherBlock
import com.levi.pocketdj.remote.mix.MixSyncUi
import com.levi.pocketdj.screens.remote.MixTogetherCopy

/**
 * The slim banner atop the Mix tab while mixing together (iOS `MixTogetherBanner` + `MixDeckOwnerBadge` +
 * `MixDeckUnavailableNote`): who's in, which deck is yours, why Auto is off, Rejoin after a system pause, and per deck its
 * owner + Claim / Release and the "isn't available on this device" note. Nothing while no mix is live.
 */
@Composable
fun MixTogetherBannerHost(graph: AppGraph) {
    if (!ParityFlags.MIX_TOGETHER) return
    val controller = graph.remoteGraph.controller
    val live by controller.isActive.collectAsState()
    if (!live) return
    val sync = remember(controller) { graph.remoteGraph.mixSync }
    val ui by sync.ui.collectAsState()
    if (!ui.active) return
    MixTogetherBanner(
        ui = ui, autoDjReason = MixTogetherBlock.reason,
        onRejoin = { sync.rejoin() }, onClaim = { sync.claim(it) }, onRelease = { sync.release(it) },
    )
}

@Composable
fun MixTogetherBanner(
    ui: MixSyncUi,
    autoDjReason: String?,
    onRejoin: () -> Unit,
    onClaim: (Deck) -> Unit,
    onRelease: (Deck) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (!ui.active) return
    Surface(
        modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).testTag("mix-together-banner"),
        shape = RoundedCornerShape(12.dp), color = DeckColors.raised,
        border = BorderStroke(1.dp, DeckColors.accent.copy(alpha = 0.5f)),
    ) {
        Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(MixTogetherCopy.BANNER_TITLE, color = DeckColors.fg, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, modifier = Modifier.weight(1f))
                Text(
                    MixTogetherCopy.yourDeckBanner(ui.myDecks), color = DeckColors.accent, fontSize = 12.sp,
                    fontWeight = FontWeight.Medium, modifier = Modifier.testTag("mix-together-your-deck"),
                )
            }
            Text(ui.participantNames.joinToString(" · "), color = DeckColors.dim, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            autoDjReason?.let { Text(it, color = DeckColors.dim, fontSize = 11.sp, modifier = Modifier.testTag("mix-together-auto-off")) }
            ui.statusMessage?.let { Text(it, color = DeckColors.gold, fontSize = 11.sp, modifier = Modifier.testTag("mix-together-status")) }
            if (ui.systemHeld.isNotEmpty()) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(MixTogetherCopy.PAUSED_HERE, color = DeckColors.gold, fontSize = 12.sp, modifier = Modifier.weight(1f))
                    Button(onRejoin, modifier = Modifier.testTag("mix-together-rejoin")) { Text(MixTogetherCopy.REJOIN) }
                }
            }
            for (d in Deck.entries) DeckOwnerRow(ui, d, onClaim, onRelease)
        }
    }
}

@Composable
private fun DeckOwnerRow(ui: MixSyncUi, deck: Deck, onClaim: (Deck) -> Unit, onRelease: (Deck) -> Unit) {
    val owner = ui.owners[deck]
    val mine = deck in ui.controllable
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Deck ${deck.label} · ${ui.ownerLabels[deck] ?: "Free"}",
                color = if (mine) DeckColors.accent else DeckColors.dim, fontSize = 12.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.weight(1f).testTag("deck-${deck.label}-owner"),
            )
            if (owner == null) {
                TextButton({ onClaim(deck) }, modifier = Modifier.testTag("deck-${deck.label}-claim")) { Text(MixTogetherCopy.CLAIM) }
            } else if (mine) {
                TextButton({ onRelease(deck) }, modifier = Modifier.testTag("deck-${deck.label}-release")) { Text(MixTogetherCopy.RELEASE, color = DeckColors.dim) }
            }
        }
        MixTogetherCopy.deckNote(ui, deck)?.let {
            val unavailableHere = ui.unavailable[deck] != null
            Text(
                it, color = if (unavailableHere) Color(0xFFFFB04A) else DeckColors.dim, fontSize = 11.sp,
                modifier = Modifier.testTag("deck-${deck.label}-unavailable"),
            )
        }
    }
}
