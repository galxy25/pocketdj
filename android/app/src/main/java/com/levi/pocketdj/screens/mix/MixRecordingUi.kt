package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.mix.recording.MixRecorder
import kotlinx.coroutines.delay

/** m:ss for the recording clock. */
internal fun recordingClock(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return "%d:%02d".format(s / 60, s % 60)
}

/** MIX-12: Record / Stop row with the live clock; surfaces writer failure and a stalled-capture warning. */
@Composable
fun MixRecordingControls(recorder: MixRecorder, modifier: Modifier = Modifier) {
    val recording by recorder.isRecordingFlow.collectAsState()
    val stalled by recorder.captureStalledFlow.collectAsState()
    val failure by recorder.writerFailureMessage.collectAsState()
    var elapsed by remember { mutableLongStateOf(0L) }
    LaunchedEffect(recording) {
        while (recording) { elapsed = System.currentTimeMillis() - recorder.startedAtMs; delay(500) }
        elapsed = 0
    }
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        if (recording) {
            Button(onClick = { recorder.stop() }, modifier = Modifier.testTag("mix-record-stop")) { Text("Stop") }
            Text("● Recording ${recordingClock(elapsed)}" + if (stalled) " (no audio)" else "", modifier = Modifier.testTag("mix-recording-indicator"))
        } else {
            OutlinedButton(onClick = { recorder.start() }, modifier = Modifier.testTag("mix-record-start")) { Text("Record") }
        }
    }
    failure?.let { Text(it, modifier = Modifier.testTag("mix-record-failure")) }
}
