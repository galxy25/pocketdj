package com.levi.pocketdj.screens.producer.tracks

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.screens.producer.common.EditSlider
import com.levi.pocketdj.studio.model.StudioMasterFX
import java.util.Locale

/**
 * The master-FX grid + master gain (iOS Tracks master grid): Phaser, Ring mod, Brazilian bass, Drive,
 * each a toggle with its knobs, plus master gain -24...+12 dB. NO Freeze: the Tracks path has no Freezer
 * (a persisted freezeEnabled is ignored by the player, and never surfaced here). Every change is applied
 * to the running player live by the host and persisted through the store.
 */
@Composable
fun MasterFxGrid(fx: StudioMasterFX, onChange: (StudioMasterFX) -> Unit, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag("tracks-master-fx"), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Master FX", style = MaterialTheme.typography.titleSmall)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(fx.phaserEnabled, { onChange(fx.copy(phaserEnabled = !fx.phaserEnabled)) }, { Text("Phaser") }, modifier = Modifier.testTag("master-fx-phaser"))
            FilterChip(fx.ringModEnabled, { onChange(fx.copy(ringModEnabled = !fx.ringModEnabled)) }, { Text("Ring mod") }, modifier = Modifier.testTag("master-fx-ring"))
            FilterChip(fx.brazilianBassEnabled, { onChange(fx.copy(brazilianBassEnabled = !fx.brazilianBassEnabled)) }, { Text("Bass") }, modifier = Modifier.testTag("master-fx-brazil"))
            FilterChip(fx.driveEnabled, { onChange(fx.copy(driveEnabled = !fx.driveEnabled)) }, { Text("Drive") }, modifier = Modifier.testTag("master-fx-drive"))
        }
        if (fx.phaserEnabled) {
            EditSlider("Phaser rate", 0.05..4.0, fx.phaserRate, { "%.2f Hz".format(Locale.US, it) }, "master-fx-phaser-rate", step = 0.05) { onChange(fx.copy(phaserRate = it)) }
            EditSlider("Phaser depth", 0.0..1.0, fx.phaserDepth, { "${(it * 100).toInt()}%" }, "master-fx-phaser-depth", step = 0.01) { onChange(fx.copy(phaserDepth = it)) }
        }
        if (fx.ringModEnabled) {
            EditSlider("Ring freq", 20.0..2000.0, fx.ringModFreqHz, { "${it.toInt()} Hz" }, "master-fx-ring-freq", step = 5.0) { onChange(fx.copy(ringModFreqHz = it)) }
            EditSlider("Ring mix", 0.0..1.0, fx.ringModMix, { "${(it * 100).toInt()}%" }, "master-fx-ring-mix", step = 0.01) { onChange(fx.copy(ringModMix = it)) }
        }
        if (fx.brazilianBassEnabled) {
            EditSlider("Bass amount", 0.0..1.0, fx.brazilianBassAmount, { "${(it * 100).toInt()}%" }, "master-fx-brazil-amount", step = 0.01) { onChange(fx.copy(brazilianBassAmount = it)) }
        }
        if (fx.driveEnabled) {
            EditSlider("Drive amount", 0.0..1.0, fx.driveAmount, { "${(it * 100).toInt()}%" }, "master-fx-drive-amount", step = 0.01) { onChange(fx.copy(driveAmount = it)) }
        }
        HorizontalDivider(Modifier.padding(vertical = 4.dp))
        EditSlider("Master gain", -24.0..12.0, fx.masterGainDb, { "%+.1f dB".format(Locale.US, it) }, "master-fx-gain", step = 0.5) { onChange(fx.copy(masterGainDb = it)) }
    }
}
