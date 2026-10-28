package com.levi.pocketdj.screens.settings

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.common.BitMatrix
import com.levi.pocketdj.data.config.RemoteEndpoints
import com.levi.pocketdj.data.sync.Enrollment
import com.levi.pocketdj.data.sync.LinkCode
import com.levi.pocketdj.onboarding.LinkProbeResult
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal const val LINK_DEVICE_SECTION_ID = "link-device"

/** Settings > Link a device (right under Profile): show this device's code / QR, or enter another's. */
internal fun linkDeviceSection() = SettingsSection(LINK_DEVICE_SECTION_ID, 51) { host ->
    val services = host.graph.servicesGraph
    val unauthorized by services.s3Database.unauthorized.collectAsState()
    val configured = RemoteEndpoints.profileSyncBase != null

    SettingsHeader("Link a device")
    if (!configured) {
        SettingsCaption("Device sync isn’t configured for this build, so linking is unavailable. Nothing is sent over the network.")
        return@SettingsSection
    }
    if (unauthorized) {
        Text(
            "Profile not authorized — relink",
            color = MaterialTheme.colorScheme.error,
            modifier = Modifier.testTag("link-unauthorized"),
        )
        SettingsCaption("Enter a fresh code from your other device below.")
    }

    var myCode by remember { mutableStateOf<String?>(null) }
    var showError by remember { mutableStateOf<String?>(null) }
    var input by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    var found by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current

    SettingsCaption("Show this device’s code, then type it (or scan it) on your other device.")
    OutlinedButton(
        enabled = !busy,
        onClick = {
            if (myCode != null) { myCode = null; return@OutlinedButton }
            busy = true; showError = null
            host.scope.launch {
                val result = withContext(Dispatchers.IO) {
                    when (val o = services.enrollment.ensureEnrolled(services.profile.id)) {
                        Enrollment.Outcome.Enrolled, Enrollment.Outcome.AlreadyEnrolled ->
                            runCatching { LinkCode.encode(services.profile.id, services.profileSecrets.secretOrMint()) }
                                .getOrElse { null to "Couldn’t build a code." }
                        Enrollment.Outcome.RelinkRequired -> null to "This device’s profile is locked. Link from your other device instead."
                        Enrollment.Outcome.NotConfigured -> null to "Sync enrollment isn’t provisioned on this build."
                        else -> null to "Couldn’t reach sync ($o). Try again."
                    }
                }
                busy = false
                if (result is String) myCode = result else showError = (result as Pair<*, *>).second as String
            }
        },
        modifier = Modifier.testTag("link-show-code"),
    ) { Text(if (myCode == null) "Show my code" else "Hide code") }
    showError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
    myCode?.let { code ->
        Text(code, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(vertical = 8.dp).testTag("link-my-code"))
        QrCode(LinkCode.URI_PREFIX + code.replace("-", ""))
        OutlinedButton(onClick = { clipboard.setText(AnnotatedString(code)) }) { Text("Copy code") }
        SettingsCaption("Anyone with this code can read and change your synced data. Don’t share it publicly.")
    }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 12.dp)) {
        OutlinedTextField(
            value = input,
            onValueChange = { input = it; message = null; found = false },
            label = { Text("Code from your other device") },
            modifier = Modifier.fillMaxWidth().testTag("link-code-input"),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                enabled = !busy && input.isNotBlank(),
                onClick = {
                    busy = true; message = null
                    host.scope.launch {
                        val r = withContext(Dispatchers.IO) { services.linkProbe.link(input) }
                        busy = false
                        when (r) {
                            is LinkProbeResult.Existing -> { found = true; message = "Linked" + (r.name.takeIf { it.isNotEmpty() }?.let { " to $it" } ?: "") + ". Restore your stuff to this device?" }
                            LinkProbeResult.Fresh -> message = "Linked. Nothing to restore yet; this device will sync from now on."
                            is LinkProbeResult.Unavailable -> message = r.reason
                        }
                    }
                },
                modifier = Modifier.testTag("link-submit"),
            ) { Text("Link") }
            if (found) {
                Button(
                    enabled = !busy,
                    onClick = {
                        busy = true
                        host.scope.launch {
                            val ok = withContext(Dispatchers.IO) { services.linkProbe.restore() }
                            busy = false; found = !ok
                            message = if (ok) "Restored." else "Couldn’t restore right now. Try Sync now."
                        }
                    },
                    modifier = Modifier.testTag("link-restore"),
                ) { Text("Restore my stuff") }
            }
        }
        message?.let { Text(it, style = MaterialTheme.typography.bodySmall, modifier = Modifier.testTag("link-message")) }
    }
}

@Composable
private fun QrCode(payload: String) {
    val matrix: BitMatrix? = remember(payload) {
        runCatching {
            QRCodeWriter().encode(payload, BarcodeFormat.QR_CODE, 0, 0, mapOf(EncodeHintType.MARGIN to 1))
        }.getOrNull()
    }
    if (matrix == null) return
    Canvas(Modifier.size(200.dp).padding(vertical = 4.dp)) {
        drawRect(Color.White, size = size)
        val cell = size.width / matrix.width
        for (y in 0 until matrix.height) for (x in 0 until matrix.width) {
            if (matrix[x, y]) drawRect(Color.Black, Offset(x * cell, y * cell), Size(cell + 0.5f, cell + 0.5f))
        }
    }
}
