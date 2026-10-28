package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.search.SearchSettings
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal const val ONLINE_SEARCH_SECTION_ID = "onlineSearch"

/** Badge text for the credential state. */
internal fun onlineSearchBadge(configured: Boolean): String = if (configured) "Configured" else "Not configured"

/**
 * Settings -> Online search: read-only aoss key id + secret (Keystore-backed) and an optional
 * host override. The Browse cloud toggle lives in Browse itself (iOS parity).
 */
internal fun onlineSearchSection() = SettingsSection(ONLINE_SEARCH_SECTION_ID, 350) { host ->
    val graph = host.graph
    val rev by graph.secrets.revision.collectAsState(initial = 0L)
    val configured by produceState(false, rev) {
        value = withContext(Dispatchers.IO) { SearchSettings.isConfigured(graph.secrets) }
    }
    var keyId by remember { mutableStateOf("") }
    var secret by remember { mutableStateOf("") }
    var endpoint by remember { mutableStateOf("") }
    val savedEndpoint by produceState<String?>(null) {
        value = SearchSettings.endpoint(graph.settings)
        endpoint = value.orEmpty()
    }

    SettingsHeader("Online search")
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("OpenSearch credentials")
        AssistChip(onClick = {}, label = { Text(onlineSearchBadge(configured)) })
    }
    SettingsCaption(
        "Paste the read-only search key to enable the cloud toggle in Browse. " +
            "Stored in the Android Keystore; never synced.",
    )
    OutlinedTextField(
        value = keyId,
        onValueChange = { keyId = it },
        label = { Text(if (configured) "Access key ID (saved — enter to replace)" else "Access key ID") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
    Spacer(Modifier.height(8.dp))
    OutlinedTextField(
        value = secret,
        onValueChange = { secret = it },
        label = { Text(if (configured) "Secret key (saved — enter to replace)" else "Secret key") },
        singleLine = true,
        visualTransformation = PasswordVisualTransformation(),
        modifier = Modifier.fillMaxWidth(),
    )
    Spacer(Modifier.height(8.dp))
    OutlinedTextField(
        value = endpoint,
        onValueChange = { endpoint = it },
        label = { Text("Search host override (optional)") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
    Spacer(Modifier.height(8.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(
            enabled = savedEndpoint != null,
            onClick = {
                host.scope.launch {
                    if (keyId.isNotBlank() != secret.isNotBlank()) {
                        host.snackbar.showSnackbar("Enter both the key id and the secret")
                        return@launch
                    }
                    withContext(Dispatchers.IO) {
                        if (keyId.isNotBlank() && secret.isNotBlank()) {
                            SearchSettings.saveCreds(graph.secrets, keyId, secret)
                        }
                    }
                    SearchSettings.setEndpoint(graph.settings, endpoint)
                    graph.browseGraph.searchConfig.setUserHost(endpoint)
                    keyId = ""
                    secret = ""
                    host.snackbar.showSnackbar("Online search settings saved")
                }
            },
        ) { Text("Save") }
        if (configured) {
            OutlinedButton(
                onClick = {
                    host.scope.launch {
                        withContext(Dispatchers.IO) { SearchSettings.clearCreds(graph.secrets) }
                        host.snackbar.showSnackbar("Search credentials removed")
                    }
                },
            ) { Text("Remove keys") }
        }
    }
}
