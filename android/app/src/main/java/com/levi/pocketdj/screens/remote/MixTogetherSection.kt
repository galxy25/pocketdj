package com.levi.pocketdj.screens.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.ParityFlags
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.remote.mix.MixSyncUi

/** The words of Mix Together's UI (iOS `MixSyncViews` + `RemoteView.mixTogetherSection`), pure so the copy is unit-tested. */
object MixTogetherCopy {
    const val HEADER = "Mix Together"
    const val BANNER_TITLE = "Mixing together"
    const val START = "Mix Together"
    const val END = "End Mix Together"
    const val CLAIM = "Claim"
    const val RELEASE = "Release"
    const val REJOIN = "Rejoin"
    const val PAUSED_HERE = "Paused on this device"
    const val NO_DECK_CLAIM = "No deck — claim one"
    const val NO_DECK_IN_MIX = "None — claim a free deck in Mix"

    fun yourDeckBanner(mine: List<Deck>): String =
        if (mine.isEmpty()) NO_DECK_CLAIM else "Your deck: " + mine.joinToString(" + ") { it.label }

    fun yourDeckSection(mine: List<Deck>): String =
        if (mine.isEmpty()) NO_DECK_IN_MIX else mine.joinToString(" + ") { "Deck ${it.label}" }

    fun footer(blockedReason: String?, active: Boolean): String = blockedReason ?: if (active) {
        "Open the Mix tab. Every device plays both decks from its own library — you drive the deck you own; anyone can move the crossfader."
    } else {
        "Two DJs, two decks: you take Deck A, the first person who joined takes Deck B. Each device plays the mix from its own library — no audio is sent between devices."
    }

    fun unavailableHere(title: String): String = "“$title” isn’t available on this device — this deck stays silent here."
    fun silentOn(devices: List<String>): String = "Silent on ${devices.joinToString(", ")}"

    /** The note under a deck: this device can't mix the song, else which OTHER devices can't, else nothing. */
    fun deckNote(ui: MixSyncUi, deck: Deck): String? {
        if (!ui.active) return null
        ui.unavailable[deck]?.let { return unavailableHere(it) }
        val others = ui.unavailableOn[deck].orEmpty()
        return if (others.isEmpty()) null else silentOn(others)
    }
}

/** The Remote screen's Mix Together section for the live session's driver; renders nothing while [ParityFlags.MIX_TOGETHER] is off. */
@Composable
fun MixTogetherSectionHost(graph: AppGraph) {
    if (!ParityFlags.MIX_TOGETHER) return
    val controller = graph.remoteGraph.controller
    val live by controller.isActive.collectAsState()
    if (!live) return
    val sync = remember(controller) { graph.remoteGraph.mixSync }
    val ui by sync.ui.collectAsState()
    MixTogetherSection(ui, onStart = { sync.start() }, onEnd = { sync.end() })
}

/** iOS `RemoteView.mixTogetherSection`: DJs + your deck + End (host) while mixing, else a Start button gated on [MixSyncUi.canStart]. */
@Composable
fun MixTogetherSection(ui: MixSyncUi, onStart: () -> Unit, onEnd: () -> Unit, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().testTag("remote-mix-section")) {
        RemoteSectionHeader(MixTogetherCopy.HEADER)
        if (ui.active) {
            LabeledRow("DJs", ui.participantNames.joinToString(", "), "remote-mix-djs")
            LabeledRow("Your deck", MixTogetherCopy.yourDeckSection(ui.myDecks), "remote-mix-your-deck")
            if (ui.isHost) {
                OutlinedButton(onEnd, Modifier.testTag("remote-mix-end")) {
                    Text(MixTogetherCopy.END, color = MaterialTheme.colorScheme.error)
                }
            }
        } else {
            Button(onStart, enabled = ui.canStart, modifier = Modifier.testTag("remote-mix-start")) { Text(MixTogetherCopy.START) }
        }
        Text(
            MixTogetherCopy.footer(ui.startBlockedReason, ui.active),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 6.dp).testTag("remote-mix-footer"),
        )
    }
}

@Composable
private fun LabeledRow(label: String, value: String, tag: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp).testTag(tag), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
