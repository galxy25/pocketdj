package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.FilterChip
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.runtime.Composable
import com.levi.pocketdj.mix.CueChannel
import com.levi.pocketdj.mix.MixSettings
import com.levi.pocketdj.mix.MixSettingsRules
import com.levi.pocketdj.mix.mixSettingsFlow
import com.levi.pocketdj.mix.setMixAutoHidePlayed
import com.levi.pocketdj.mix.setMixBeatPulse
import com.levi.pocketdj.mix.setMixCueChannel
import com.levi.pocketdj.mix.setMixDeckLayout
import com.levi.pocketdj.mix.setMixFadeSeconds
import com.levi.pocketdj.mix.setMixGlideSeconds
import com.levi.pocketdj.mix.setMixLeadSeconds
import com.levi.pocketdj.mix.setMixSkipFadeSeconds
import com.levi.pocketdj.screens.mix.DeckLayout
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

internal const val MIX_SECTION_ID = "mix"

/** Footer copy (iOS `mixSectionFooter`, minus the macOS-only wording). */
internal const val MIX_SECTION_FOOTER =
    "In the Mix tab's Auto mode, the app plays a pocket or set list end-to-end, beginning each crossfade " +
        "this many seconds before a track ends and sweeping the volume from one deck to the next over the " +
        "fade length. Skip fade is how long the crossfade lasts when you tap the Skip button (double-tap " +
        "always uses a fast 5 s sweep).\n\nA mix session records what you play until you hit Reset. When " +
        "Auto-hide played tracks is on, the deck loader hides tracks you've already played this session; " +
        "off, they still show with a ✓.\n\nCue output channel routes a deck's pre-fade-listen (the " +
        "headphones button on each deck) to one side of the stereo output, leaving the house mix on the " +
        "other.\n\nBeat pulse flashes a ring around each deck on every beat (downbeats brighter) so you " +
        "can feel the groove and eyeball-align the two decks while beat-matching.\n\nDeck layout arranges " +
        "the two decks side by side, stacked, or one at a time (landscape always shows both side by side)."

/**
 * Settings ▸ Mix: lead / fade / skip-fade / glide steppers, auto-hide played, cue channel, beat
 * pulse, deck layout. Persisted through the generic DataStore keys with the iOS defaults; the Mix
 * screen pushes changed values into the engine immediately.
 */
internal fun mixSection() = SettingsSection(MIX_SECTION_ID, 520) { host ->
    val store = host.graph.settings
    val s by store.mixSettingsFlow().collectAsState(MixSettings())
    val scope = host.scope
    SettingsHeader("Mix")
    StepperRow("Crossfade lead", s.autoMixLeadSeconds, MixSettings.LEAD_RANGE, "settings-automix-lead") {
        scope.launch { store.setMixLeadSeconds(it) }
    }
    StepperRow("Crossfade length", s.autoMixFadeSeconds, MixSettings.FADE_RANGE, "settings-automix-fade") {
        scope.launch { store.setMixFadeSeconds(it) }
    }
    StepperRow("Skip fade", s.skipFadeSeconds, MixSettings.SKIP_FADE_RANGE, "settings-automix-skip-fade") {
        scope.launch { store.setMixSkipFadeSeconds(it) }
    }
    StepperRow("Mix Glide length", s.mixGlideSeconds, MixSettings.GLIDE_RANGE, "settings-mix-glide-length") {
        scope.launch { store.setMixGlideSeconds(it) }
    }
    SwitchRow("Auto-hide played tracks", s.mixAutoHidePlayed, "settings-mix-autohide") {
        scope.launch { store.setMixAutoHidePlayed(it) }
    }
    ChoiceRow("Cue output channel", "settings-mix-cue-channel", CueChannel.entries, s.cueOutputChannel, { it.label }) {
        scope.launch { store.setMixCueChannel(it) }
    }
    SwitchRow("Beat pulse", s.beatPulseEnabled, "settings-mix-beat-pulse") {
        scope.launch { store.setMixBeatPulse(it) }
    }
    ChoiceRow("Deck layout", "settings-mix-deck-layout", DeckLayout.entries, s.mixDeckLayout, ::deckLayoutLabel) {
        scope.launch { store.setMixDeckLayout(it) }
    }
    SettingsCaption(MIX_SECTION_FOOTER)
}

@Composable
private fun StepperRow(
    title: String, value: Double, range: ClosedFloatingPointRange<Double>, tag: String, onChange: (Double) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 2.dp).testTag(tag),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(title, modifier = Modifier.weight(1f))
        OutlinedButton(onClick = { onChange(value - 1) }, enabled = value > range.start, modifier = Modifier.testTag("$tag-minus")) { Text("−") }
        Text(MixSettingsRules.seconds(value), modifier = Modifier.testTag("$tag-value"))
        OutlinedButton(onClick = { onChange(value + 1) }, enabled = value < range.endInclusive, modifier = Modifier.testTag("$tag-plus")) { Text("+") }
    }
}

@Composable
private fun SwitchRow(title: String, checked: Boolean, tag: String, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Text(title, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange, modifier = Modifier.testTag(tag))
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun <T> ChoiceRow(
    title: String, tag: String, options: List<T>, selected: T, label: (T) -> String, onPick: (T) -> Unit,
) {
    Text(title, modifier = Modifier.padding(top = 6.dp))
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.testTag(tag)) {
        options.forEach { o ->
            FilterChip(selected = o == selected, onClick = { onPick(o) }, label = { Text(label(o)) })
        }
    }
}

internal fun deckLayoutLabel(l: DeckLayout): String = when (l) {
    DeckLayout.SIDE_BY_SIDE -> "Side by side"
    DeckLayout.STACKED -> "Stacked"
    DeckLayout.SINGLE -> "Single deck"
}
