package com.levi.pocketdj.screens.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.FilterChip
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.mix.CueChannel
import com.levi.pocketdj.mix.MixSettings
import com.levi.pocketdj.mix.MixSettingsRules
import com.levi.pocketdj.mix.mixSettingsFlow
import com.levi.pocketdj.mix.setDjEffectSweeps
import com.levi.pocketdj.mix.setDjKeyMatch
import com.levi.pocketdj.mix.setDjPockets
import com.levi.pocketdj.mix.setDjTempoMatch
import com.levi.pocketdj.mix.setDjTempoWaves
import com.levi.pocketdj.mix.setDjTransitions
import com.levi.pocketdj.mix.setDjVolumeLeveling
import com.levi.pocketdj.mix.setMixAutoHidePlayed
import com.levi.pocketdj.mix.setMixBeatPulse
import com.levi.pocketdj.mix.setMixCueChannel
import com.levi.pocketdj.mix.setMixDeckLayout
import com.levi.pocketdj.mix.setMixFadeSeconds
import com.levi.pocketdj.mix.setMixGlideSeconds
import com.levi.pocketdj.mix.setMixLeadSeconds
import com.levi.pocketdj.mix.setMixSkipFadeSeconds
import com.levi.pocketdj.mix.setMixVolumeGlide
import com.levi.pocketdj.screens.mix.DeckLayout
import kotlinx.coroutines.launch

internal const val CROSSFADES_FOOTER =
    "These lengths drive both the Mix tab's Auto mode and Now Playing DJ Mode. Each crossfade may begin up to " +
        "the lead before a song ends and sweeps from one song to the next over the crossfade length; Mix Glide " +
        "is how long the tempo / key / effect glide eases in before the fade and back out after it.\n\nSkip " +
        "fade is how long the crossfade lasts when you skip. A double-tap (and skip on the lock screen, Android " +
        "Auto or a widget) is always a fast 5 s sweep."

internal const val DJ_FOOTER =
    "DJ Mode (the DJ chip beside Mix Mode in Now Playing) mixes each song into the next once both are on this " +
        "device, using the crossfades above.\n\nTransitions crossfades songs (off: songs end and start as usual, " +
        "the ordering below still applies). Effect sweeps rides a filter / echo / reverb sweep through each mix. " +
        "Tempo match glides the tempos together; Key / pitch match nudges the pitch toward a compatible key. " +
        "Volume leveling evens out loudness between songs (−14 LUFS). Tempo waves orders what's coming up into " +
        "10 BPM steps that build up and wind down; Pockets plays runs of 3–4 songs of a similar genre, era and " +
        "collection."

internal const val MIX_TAB_FOOTER =
    "Volume glide (off by default) levels every song the Auto-DJ plays to one loudness (−14 LUFS, at most " +
        "−12…+6 dB, ramped over 2 s) on each deck's own trim — your Vol faders are never moved — and shows the " +
        "trim under each deck's Vol. Hand-mixing is never leveled.\n\nA mix session records what you play until " +
        "you hit Reset. When Auto-hide played tracks is on, the deck loader hides tracks you've already played " +
        "this session; off, they still show with a ✓.\n\nCue output channel routes a deck's pre-fade-listen (the " +
        "headphones button on each deck) to one side of the stereo output, leaving the house mix on the other " +
        "— for a booth where you monitor on a separate feed.\n\nBeat pulse flashes a ring around each deck on " +
        "every beat (downbeats brighter) so you can feel the groove and eyeball-align the two decks while " +
        "beat-matching.\n\nDeck layout arranges the two Mix decks in portrait: Side by side, Stacked, or Single " +
        "(one deck at a time). Landscape always shows them side by side."

/**
 * Settings ▸ Mixing (iOS `MixingSettingsView`): every mixing control in one pane. The DJ toggles
 * MASK parts of a DJ Mode mix off; they never change the shared Mix timings above them.
 */
@Composable
fun MixingSettingsScreen(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val store = remember { AppGraph.get(context).settings }
    val scope = rememberCoroutineScope()
    val sOrNull by store.mixSettingsFlow().collectAsState(null)
    // Nothing until the first emission: a tap on defaults must never overwrite the stored value.
    val s = sOrNull ?: return
    Column(
        modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp)
            .testTag("settings-mixing-screen"),
    ) {
        SettingsHeader("Crossfades")
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
        SettingsCaption(CROSSFADES_FOOTER)
        Spacer(Modifier.height(16.dp))

        SettingsHeader("Now Playing DJ Mode")
        SwitchRow("Transitions (crossfade)", s.dj.transitions, "settings-dj-transitions") { scope.launch { store.setDjTransitions(it) } }
        SwitchRow("Effect sweeps", s.dj.effectSweeps, "settings-dj-effects") { scope.launch { store.setDjEffectSweeps(it) } }
        SwitchRow("Tempo match", s.dj.tempoMatch, "settings-dj-tempo") { scope.launch { store.setDjTempoMatch(it) } }
        SwitchRow("Key / pitch match", s.dj.keyMatch, "settings-dj-key") { scope.launch { store.setDjKeyMatch(it) } }
        SwitchRow("Volume leveling", s.dj.volumeLeveling, "settings-dj-volume") { scope.launch { store.setDjVolumeLeveling(it) } }
        SwitchRow("Tempo waves", s.dj.tempoWaves, "settings-dj-waves") { scope.launch { store.setDjTempoWaves(it) } }
        SwitchRow("Pockets (genre, year, collections)", s.dj.pockets, "settings-dj-pockets") { scope.launch { store.setDjPockets(it) } }
        SettingsCaption(DJ_FOOTER)
        Spacer(Modifier.height(16.dp))

        SettingsHeader("Mix tab")
        SwitchRow("Volume glide (Auto-DJ)", s.mixVolumeGlide, "settings-mix-volume-glide") { scope.launch { store.setMixVolumeGlide(it) } }
        SwitchRow("Auto-hide played tracks", s.mixAutoHidePlayed, "settings-mix-autohide") { scope.launch { store.setMixAutoHidePlayed(it) } }
        ChoiceRow("Cue output channel", "settings-mix-cue-channel", CueChannel.entries, s.cueOutputChannel, { it.label }) {
            scope.launch { store.setMixCueChannel(it) }
        }
        SwitchRow("Beat pulse", s.beatPulseEnabled, "settings-mix-beat-pulse") { scope.launch { store.setMixBeatPulse(it) } }
        ChoiceRow("Deck layout", "settings-mix-deck-layout", DeckLayout.entries, s.mixDeckLayout, ::deckLayoutLabel) {
            scope.launch { store.setMixDeckLayout(it) }
        }
        SettingsCaption(MIX_TAB_FOOTER)
        Spacer(Modifier.height(24.dp))
    }
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
