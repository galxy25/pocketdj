package com.levi.pocketdj.screens.settings

import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.data.rips.RipServerClient
import com.levi.pocketdj.data.settings.AppSettings
import com.levi.pocketdj.data.settings.SourceConfig
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Settings — Android P1 rows (specs/browse.md §12): data sources (enable/disable
 * + one-tap preset loaders + reload), import (rip) server URL/token + test
 * connection, jukebox broker URL/token, online-search toggle, catalog
 * refresh/clear-cache, about.
 *
 * Entry composable for the integrator; lives at
 * `com.levi.pocketdj.screens.settings.SettingsScreen` (replaces the placeholder
 * `com.levi.pocketdj.screens.SettingsScreen` import in MainActivity).
 */
@Composable
fun SettingsScreen(
    modifier: Modifier = Modifier,
    onOpenStorage: () -> Unit = {},
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }

    val settings by graph.settings.settings.collectAsState(initial = null)
    val catalogState by graph.catalogRepository.state.collectAsState()

    // Editable copies, seeded once from the first settings emission.
    var seeded by remember { mutableStateOf(false) }
    var ripUrl by remember { mutableStateOf("") }
    var ripToken by remember { mutableStateOf("") }
    var jukeboxUrl by remember { mutableStateOf("") }
    var jukeboxToken by remember { mutableStateOf("") }
    LaunchedEffect(settings) {
        val current = settings ?: return@LaunchedEffect
        if (!seeded) {
            seeded = true
            ripUrl = current.ripServerUrl
            ripToken = current.ripToken
            jukeboxUrl = current.jukeboxServerUrl
            jukeboxToken = current.jukeboxToken
        }
    }

    var healthResult by remember { mutableStateOf<String?>(null) }
    var testingHealth by remember { mutableStateOf(false) }
    var confirmClearCache by remember { mutableStateOf(false) }
    var confirmClearHistory by remember { mutableStateOf(false) }

    // Apple Music sign-in (specs/applemusic.md §7). The Music-User-Token round-trip
    // runs through the Apple Music app; we own an ActivityResult launcher HERE (via
    // `rememberLauncherForActivityResult`, which registers against the host activity)
    // so no MainActivity wiring is needed. [DEVICE-ONLY]: on the emulator the deep
    // link can't complete and the result decodes to Cancelled/Failed — never a crash.
    var signingIn by remember { mutableStateOf(false) }
    var appleMusicError by remember { mutableStateOf<String?>(null) }
    val authLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        scope.launch {
            signingIn = false
            when (val decoded = graph.musicKitAuth.decodeResult(result.data)) {
                is com.levi.pocketdj.data.applemusic.MusicKitAuth.AuthResult.Success -> {
                    appleMusicError = null
                    // Pre-warm the dev token so the first AM play is instant.
                    graph.musicKitDevTokenClient.prewarm()
                }
                is com.levi.pocketdj.data.applemusic.MusicKitAuth.AuthResult.Cancelled ->
                    appleMusicError = null
                is com.levi.pocketdj.data.applemusic.MusicKitAuth.AuthResult.Failed ->
                    appleMusicError = decoded.message
            }
        }
    }

    Box(modifier = modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            // ---- Data sources -------------------------------------------------
            SectionHeader("Data sources")
            val current = settings
            if (current == null) {
                CircularProgressIndicator(Modifier.padding(8.dp))
            } else {
                current.sources.forEach { source ->
                    SourceRow(
                        source = source,
                        onToggle = { enabled ->
                            scope.launch {
                                // Transform inside the DataStore edit — a stale
                                // composition snapshot must not undo a quick
                                // preceding toggle.
                                graph.settings.updateSources { sources ->
                                    sources.map {
                                        if (it.id == source.id) it.copy(enabled = enabled) else it
                                    }
                                }
                                graph.catalogRepository.refresh()
                            }
                        },
                    )
                }
                // One-tap preset loaders, hidden once present (match name OR url).
                val presets = listOf(AppSettings.appleMusicSource(), AppSettings.digitalSource())
                presets.forEach { preset ->
                    val present = current.sources.any {
                        it.name == preset.name || it.url == preset.url
                    }
                    if (!present) {
                        TextButton(
                            onClick = {
                                scope.launch {
                                    graph.settings.updateSources { sources ->
                                        if (sources.any { it.name == preset.name || it.url == preset.url }) {
                                            sources
                                        } else {
                                            sources + preset
                                        }
                                    }
                                    graph.catalogRepository.refresh()
                                }
                            },
                        ) {
                            Text("Add “${preset.name}”")
                        }
                    }
                }
            }

            SectionDivider()

            // ---- Catalog ------------------------------------------------------
            SectionHeader("Catalog")
            catalogState.catalog?.let { catalog ->
                SettingsCaption(
                    "${catalog.albums.size} albums · ${catalog.songs.size} songs · " +
                        "${catalog.availableSources.size} sources",
                )
            }
            catalogState.error?.let { SettingsCaption("Last refresh: $it") }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Button(
                    onClick = { graph.catalogRepository.refresh() },
                    enabled = !catalogState.isRefreshing,
                ) {
                    Text("Reload catalog")
                }
                Spacer(Modifier.width(12.dp))
                OutlinedButton(onClick = { confirmClearCache = true }) {
                    Text("Clear cache")
                }
                if (catalogState.isRefreshing) {
                    Spacer(Modifier.width(12.dp))
                    CircularProgressIndicator(
                        modifier = Modifier.width(18.dp).height(18.dp),
                        strokeWidth = 2.dp,
                    )
                }
            }
            SettingsCaption(
                "Reload refreshes in place and never blanks a loaded catalog. " +
                    "Clear cache removes the offline copies, then refetches.",
            )

            SectionDivider()

            // ---- Import (rip) server -----------------------------------------
            SectionHeader("Import server")
            SettingsCaption(
                "Blank by default — paste your rip server's URL (e.g. a Tailscale " +
                    "Funnel address). Songs without a public rip stay browsable " +
                    "metadata until a server is configured.",
            )
            OutlinedTextField(
                value = ripUrl,
                onValueChange = { ripUrl = it },
                label = { Text("Server URL") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = ripToken,
                onValueChange = { ripToken = it },
                label = { Text("Access token (optional)") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Button(
                    onClick = {
                        scope.launch {
                            graph.settings.setRipServer(ripUrl, ripToken)
                            snackbar.showSnackbar("Import server saved")
                        }
                    },
                ) {
                    Text("Save")
                }
                Spacer(Modifier.width(12.dp))
                OutlinedButton(
                    enabled = ripUrl.isNotBlank() && !testingHealth,
                    onClick = {
                        scope.launch {
                            testingHealth = true
                            healthResult = null
                            try {
                                // Probe the TYPED values without committing them —
                                // only Save persists (a failed test must not flip
                                // every unripped song to rip-on-demand ▶).
                                val health = graph.ripServerClient.health(ripUrl, ripToken)
                                healthResult = if (health.ok) {
                                    buildString {
                                        append("Connected")
                                        health.catalog?.songs?.let { append(" — $it songs") }
                                        health.version?.let { append(" · v$it") }
                                        if (health.hls == true) append(" · HLS")
                                    }
                                } else {
                                    "Server responded but reported not-OK"
                                }
                            } catch (error: RipServerClient.RipServerException) {
                                healthResult = error.message
                            } catch (error: Exception) {
                                if (error is CancellationException) throw error
                                healthResult = error.message ?: "Unreachable"
                            } finally {
                                testingHealth = false
                            }
                        }
                    },
                ) {
                    Text(if (testingHealth) "Testing…" else "Test connection")
                }
            }
            healthResult?.let { SettingsCaption(it) }

            SectionDivider()

            // ---- Apple Music -------------------------------------------------
            SectionHeader("Apple Music")
            when {
                current == null -> Unit
                // Signed-in check FIRST: a user who signed in and later blanked
                // their Import server must still be able to sign out (and not have
                // a live Music-User-Token stranded behind a disabled button).
                current.hasAppleMusic -> {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            "Apple Music · Connected",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.weight(1f),
                        )
                        OutlinedButton(
                            onClick = {
                                scope.launch {
                                    graph.musicKitAuth.signOut()
                                    // Free the native AM engine's resources (§3.3).
                                    graph.playbackController.releaseAppleMusic()
                                    appleMusicError = null
                                }
                            },
                        ) {
                            Text("Sign out")
                        }
                    }
                    SettingsCaption(
                        "Full-track streaming needs an active Apple Music " +
                            "subscription and the Apple Music app installed. Where a " +
                            "track can't stream, a 30-second preview plays instead.",
                    )
                }
                !current.hasRipServer -> {
                    // Signed OUT with no Import server: the developer token is
                    // minted BY the rip server (§5), so sign-in is impossible until
                    // an Import server is configured.
                    OutlinedButton(onClick = {}, enabled = false) {
                        Text("Sign in with Apple Music")
                    }
                    SettingsCaption(
                        "Add an Import server first — it mints the Apple Music " +
                            "developer token.",
                    )
                }
                else -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Button(
                            enabled = !signingIn,
                            onClick = {
                                scope.launch {
                                    appleMusicError = null
                                    signingIn = true
                                    try {
                                        // Fetch the dev token + build the intent FIRST
                                        // so a server/token failure surfaces before
                                        // Apple Music is ever opened (§7).
                                        val intent = graph.musicKitAuth.signInIntent()
                                        authLauncher.launch(intent)
                                        // signingIn stays true until the result
                                        // callback fires (RESULT_CANCELED at minimum).
                                    } catch (error: CancellationException) {
                                        signingIn = false
                                        throw error
                                    } catch (error: Throwable) {
                                        signingIn = false
                                        appleMusicError =
                                            error.message ?: "Apple Music sign-in is unavailable"
                                    }
                                }
                            },
                        ) {
                            Text(if (signingIn) "Connecting…" else "Sign in with Apple Music")
                        }
                        if (signingIn) {
                            Spacer(Modifier.width(12.dp))
                            CircularProgressIndicator(
                                modifier = Modifier.width(18.dp).height(18.dp),
                                strokeWidth = 2.dp,
                            )
                        }
                    }
                    SettingsCaption(
                        "Opens the Apple Music app to connect your account. Full-track " +
                            "streaming needs an active subscription; without one (or on " +
                            "an emulator) 30-second previews play instead.",
                    )
                    appleMusicError?.let { SettingsCaption(it) }
                }
            }

            SectionDivider()

            // ---- Jukebox broker ----------------------------------------------
            SectionHeader("Jukebox broker")
            SettingsCaption("The request-line broker Jukebox Hero connects to. Blank = off.")
            OutlinedTextField(
                value = jukeboxUrl,
                onValueChange = { jukeboxUrl = it },
                label = { Text("Broker URL") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = jukeboxToken,
                onValueChange = { jukeboxToken = it },
                label = { Text("Broker token (optional)") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            Button(
                onClick = {
                    scope.launch {
                        graph.settings.setJukeboxServer(jukeboxUrl, jukeboxToken)
                        snackbar.showSnackbar("Jukebox broker saved")
                    }
                },
            ) {
                Text("Save")
            }

            // NOTE: the "Search online" toggle was removed — Browse has no online
            // mode on Android P1 (no OpenSearch client or credential fields), and
            // a switch that changes nothing is a misleading affordance. The
            // settings key (`onlineSearchEnabled`) survives for when it ships.

            SectionDivider()

            // ---- History ------------------------------------------------------
            SectionHeader("History")
            OutlinedButton(onClick = { confirmClearHistory = true }) {
                Text("Clear play history")
            }
            SettingsCaption(
                "Removes every recorded play from this device. Settings, sources, " +
                    "and the install identity are kept.",
            )

            SectionDivider()

            // ---- Storage ------------------------------------------------------
            SectionHeader("Storage")
            OutlinedButton(onClick = onOpenStorage) {
                Text("Manage storage")
            }
            SettingsCaption(
                "See what PocketDJ keeps on this device per category, with sizes, and " +
                    "clear the re-derivable caches and logs.",
            )

            SectionDivider()

            // ---- About --------------------------------------------------------
            SectionHeader("About")
            val versionName = remember {
                runCatching {
                    context.packageManager.getPackageInfo(context.packageName, 0).versionName
                }.getOrNull() ?: "?"
            }
            AboutRow("App", "PocketDJ $versionName (Android)")
            AboutRow("Android", "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
            AboutRow("Catalog", Endpoints.CATALOG_BASE)
            AboutRow("Rips", Endpoints.RIPS_BASE)

            Spacer(Modifier.height(24.dp))
        }

        SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
    }

    if (confirmClearCache) {
        AlertDialog(
            onDismissRequest = { confirmClearCache = false },
            title = { Text("Clear catalog cache?") },
            text = {
                Text(
                    "Removes the offline catalog copies from this device, then " +
                        "refetches from the network. Your sources and settings are kept.",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmClearCache = false
                        scope.launch {
                            graph.catalogService.clearCache()
                            graph.catalogRepository.refresh()
                            snackbar.showSnackbar("Catalog cache cleared")
                        }
                    },
                ) {
                    Text("Clear")
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmClearCache = false }) { Text("Cancel") }
            },
        )
    }

    if (confirmClearHistory) {
        AlertDialog(
            onDismissRequest = { confirmClearHistory = false },
            title = { Text("Clear play history?") },
            text = {
                Text(
                    "Every recorded play is removed from this device. " +
                        "Settings and sources are kept. This can't be undone.",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmClearHistory = false
                        scope.launch {
                            // clear() does synchronous file IO — keep it off-main.
                            withContext(Dispatchers.Default) {
                                PlayHistoryStore.get(context).clear()
                            }
                            snackbar.showSnackbar("Play history cleared")
                        }
                    },
                ) {
                    Text("Clear")
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmClearHistory = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun SourceRow(source: SourceConfig, onToggle: (Boolean) -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(source.name, style = MaterialTheme.typography.bodyMedium)
            Text(
                source.url,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Switch(checked = source.enabled, onCheckedChange = onToggle)
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(bottom = 6.dp),
    )
}

@Composable
private fun SectionDivider() {
    Spacer(Modifier.height(16.dp))
    HorizontalDivider()
    Spacer(Modifier.height(16.dp))
}

@Composable
private fun SettingsCaption(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(vertical = 4.dp),
    )
}

@Composable
private fun AboutRow(label: String, value: String) {
    Row(modifier = Modifier.padding(vertical = 2.dp)) {
        Text(
            label,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(72.dp),
        )
        Text(
            value,
            style = MaterialTheme.typography.bodySmall,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
