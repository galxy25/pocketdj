package com.levi.pocketdj.screens.producer.samples

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.producer.common.StudioFmt
import com.levi.pocketdj.studio.engine.MicRecorder
import com.levi.pocketdj.studio.engine.MicTake
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.levi.pocketdj.studio.StudioSettings

/** Permission states of the mic sheet (denied shows the Settings escape hatch). */
enum class MicPermission { Unknown, Granted, Denied }

/** Record a sample from the microphone: permission, input picker, level meter, record / stop. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MicRecordSheet(graph: AppGraph, onDismiss: () -> Unit, onFiled: (String) -> Unit) {
    val ctx = LocalContext.current
    val studio = graph.studioGraph
    val rec = studio.micRecorder
    val scope = rememberCoroutineScope()
    val recording by rec.isRecording.collectAsState()
    val level by rec.level.collectAsState()
    val stalled by rec.captureStalled.collectAsState()
    val failure by rec.writerFailureMessage.collectAsState()
    val inputs by rec.inputs.collectAsState()

    var permission by remember {
        mutableStateOf(if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) MicPermission.Granted else MicPermission.Unknown)
    }
    var monitorFailed by remember { mutableStateOf(false) }
    var elapsedMs by remember { mutableStateOf(0) }
    var name by remember { mutableStateOf(MicRecorder.DEFAULT_NAME) }
    var filed by remember { mutableStateOf<String?>(null) }
    var pickerOpen by remember { mutableStateOf(false) }

    val askPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        permission = if (ok) MicPermission.Granted else MicPermission.Denied
    }

    // Playback must not be sounding while the mic opens: the engine is parked, the flag guards the rest.
    LaunchedEffect(permission) {
        when (permission) {
            MicPermission.Unknown -> askPermission.launch(Manifest.permission.RECORD_AUDIO)
            MicPermission.Granted -> {
                withContext(Dispatchers.IO) { runCatching { rec.recoverOrphans() } }
                studio.studioEngine.stopSample()
                monitorFailed = !withContext(Dispatchers.IO) { rec.beginMonitoring() }
            }
            MicPermission.Denied -> {}
        }
    }
    // Dismissal mid-take files it (default name) and always releases the capture flag.
    DisposableEffect(Unit) { onDispose { rec.stopAndFileAsync(name.takeIf { it.isNotBlank() }) } }
    LaunchedEffect(name) { rec.pendingName = name }
    // Restore the last picked input (AudioDeviceInfo id; -1 = automatic) once.
    LaunchedEffect(Unit) {
        val saved = runCatching { graph.settings.get(StudioSettings.MIC_INPUT_ID) }.getOrNull() ?: -1
        rec.refreshInputs()
        if (saved >= 0 && rec.inputs.value.any { it.deviceId == saved }) rec.selectInput(saved)
    }

    LaunchedEffect(recording) {
        val t0 = System.currentTimeMillis()
        while (recording) { elapsedMs = (System.currentTimeMillis() - t0).toInt(); delay(100) }
    }

    suspend fun fileTake(take: MicTake) {
        val nm = name.trim().ifEmpty { MicRecorder.DEFAULT_NAME }
        val sample = StudioSample(take.id, nm, take.fileName, take.wasUserFolder, System.currentTimeMillis().toDouble(), take.durationMs, StudioSource.Mic)
        // The SAF write can be large: off the UI thread (callers invoke this from Main).
        withContext(Dispatchers.IO) { studio.studioStore.addSampleRelocating(sample) }
        filed = take.id
        onFiled(take.id)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 20.dp, vertical = 8.dp).testTag("mic-sheet"),
            verticalArrangement = Arrangement.spacedBy(14.dp), horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("Record a sample", style = MaterialTheme.typography.titleLarge)
            when {
                permission == MicPermission.Denied -> {
                    Text("Microphone access is off. Turn it on in Settings to record samples.", Modifier.testTag("mic-denied"))
                    Button(onClick = {
                        ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", ctx.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }) { Text("Open Settings") }
                    TextButton(onClick = { askPermission.launch(Manifest.permission.RECORD_AUDIO) }) { Text("Ask again") }
                }
                permission == MicPermission.Unknown -> Text("Waiting for microphone permission…")
                monitorFailed -> Text("Couldn’t open the microphone. Close other apps that are recording and try again.", color = MaterialTheme.colorScheme.error)
                else -> {
                    LinearProgressIndicator(progress = { level.coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().height(10.dp).testTag("mic-level"))
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(StudioFmt.mmssTenths(elapsedMs), style = MaterialTheme.typography.headlineMedium, modifier = Modifier.testTag("mic-elapsed"))
                        Box {
                            OutlinedButton(onClick = { rec.refreshInputs(); pickerOpen = true }, enabled = !recording, modifier = Modifier.testTag("mic-input-picker")) {
                                Text(inputs.firstOrNull { it.deviceId == rec.selectedDeviceId }?.label ?: "Input: automatic")
                            }
                            DropdownMenu(pickerOpen, { pickerOpen = false }) {
                                DropdownMenuItem(text = { Text("Automatic") }, onClick = { rec.selectInput(null); scope.launch { graph.settings.set(StudioSettings.MIC_INPUT_ID, -1) }; pickerOpen = false })
                                inputs.forEach { o -> DropdownMenuItem(text = { Text(o.label) }, onClick = { rec.selectInput(o.deviceId); scope.launch { graph.settings.set(StudioSettings.MIC_INPUT_ID, o.deviceId) }; pickerOpen = false }) }
                            }
                        }
                    }
                    if (!recording && filed == null) OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("mic-name"))
                    if (stalled) Text("The microphone stopped delivering audio. Stop and try again.", color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("mic-stalled"))
                    failure?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    if (recording) {
                        Button(
                            onClick = { scope.launch { rec.stopAwaitingFinalize()?.let { fileTake(it) } } },
                            colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                            modifier = Modifier.testTag("mic-stop"),
                        ) { Icon(Icons.Filled.Stop, null); Text("Stop", Modifier.padding(start = 8.dp)) }
                    } else if (filed != null) {
                        Text("Saved. It’s in your Samples list.", Modifier.testTag("mic-saved"))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { filed = null; name = MicRecorder.DEFAULT_NAME; elapsedMs = 0; scope.launch { monitorFailed = !withContext(Dispatchers.IO) { rec.beginMonitoring() } } }) { Text("Record another") }
                            Button(onClick = onDismiss) { Text("Done") }
                        }
                    } else {
                        Button(
                            onClick = { elapsedMs = 0; scope.launch { if (!withContext(Dispatchers.IO) { rec.start() }) monitorFailed = true } },
                            colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                            modifier = Modifier.testTag("mic-record"),
                        ) { Icon(Icons.Filled.FiberManualRecord, null, Modifier.size(18.dp)); Text("Record", Modifier.padding(start = 8.dp)) }
                    }
                }
            }
        }
    }
}
