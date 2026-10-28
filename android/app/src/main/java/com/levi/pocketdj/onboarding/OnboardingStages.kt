package com.levi.pocketdj.onboarding

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.applemusic.MusicKitAuth
import com.levi.pocketdj.data.settings.AppSettings
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable
private fun OnboardingCard(content: @Composable ColumnScope.() -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) { content() }
    }
}

@Composable
private fun NavRow(
    showBack: Boolean,
    onBack: () -> Unit,
    continueLabel: String,
    continueEnabled: Boolean = true,
    onContinue: () -> Unit,
) {
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        if (showBack) OutlinedButton(onClick = onBack, modifier = Modifier.testTag("onboarding-back")) { Text("Back") }
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.End) {
            Button(
                onClick = onContinue,
                enabled = continueEnabled,
                modifier = Modifier.testTag("onboarding-continue"),
            ) { Text(continueLabel) }
        }
    }
}

/** Stage 1's internal machine: the choice, then the link probe's outcome. */
private enum class ProfilePhase { Choosing, Probing, LinkUnavailable, LinkFound, Naming }

/** Stage 1 — profile: name + "Use on this device" / "Link a device" (probe stubbed until SVC-9). */
@Composable
fun OnboardingProfileStage(graph: AppGraph, store: OnboardingStore) {
    val scope = rememberCoroutineScope()
    var phase by rememberSaveable { mutableStateOf(ProfilePhase.Choosing) }
    var name by rememberSaveable { mutableStateOf("") }
    var foundName by rememberSaveable { mutableStateOf("") }
    var unavailableReason by rememberSaveable { mutableStateOf("") }

    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        when (phase) {
            ProfilePhase.Choosing -> {
                OnboardingCard {
                    Text("Link a device", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Already use PocketDJ elsewhere? Link this device to bring back your playlists, pockets, and sessions.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Button(
                        onClick = {
                            phase = ProfilePhase.Probing
                            scope.launch {
                                when (val r = graph.shellGraph.linkDeviceProbe.probe()) {
                                    is LinkProbeResult.Existing -> { foundName = r.name; phase = ProfilePhase.LinkFound }
                                    LinkProbeResult.Fresh -> phase = ProfilePhase.Naming
                                    is LinkProbeResult.Unavailable -> {
                                        unavailableReason = r.reason
                                        phase = ProfilePhase.LinkUnavailable
                                    }
                                }
                            }
                        },
                        modifier = Modifier.testTag("onboarding-choice-link"),
                    ) { Text("Link a device") }
                }
                OnboardingCard {
                    Text("Just this device", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Keep everything on this device only. You can link a device later in Settings.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    OutlinedButton(
                        onClick = { phase = ProfilePhase.Naming },
                        modifier = Modifier.testTag("onboarding-choice-device"),
                    ) { Text("Use on this device") }
                }
            }
            ProfilePhase.Probing -> OnboardingCard {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    CircularProgressIndicator(Modifier.padding(2.dp), strokeWidth = 2.dp)
                    Text("Looking for your profile…")
                }
            }
            ProfilePhase.LinkUnavailable -> {
                OnboardingCard {
                    Text("Can't link right now", style = MaterialTheme.typography.titleMedium)
                    Text(unavailableReason, style = MaterialTheme.typography.bodyMedium)
                    Button(
                        onClick = { phase = ProfilePhase.Naming },
                        modifier = Modifier.testTag("onboarding-link-continue-device"),
                    ) { Text("Use on this device") }
                    TextButton(onClick = { phase = ProfilePhase.Choosing }) { Text("Back") }
                }
            }
            ProfilePhase.LinkFound -> OnboardingCard {
                Text(
                    if (foundName.isEmpty()) "Welcome back" else "Welcome back, $foundName",
                    style = MaterialTheme.typography.titleMedium,
                )
                Text("A PocketDJ profile already exists. Restoring arrives with device linking.")
                TextButton(onClick = { phase = ProfilePhase.Naming }) { Text("Start fresh on this device") }
            }
            ProfilePhase.Naming -> {
                OnboardingCard {
                    Text("Your PocketDJ name", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Shown on your performance items and the Jukebox Hero DJ line. Optional — change it anytime in Settings.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    OutlinedTextField(
                        value = name,
                        onValueChange = { name = it },
                        label = { Text("DJ name") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("onboarding-name"),
                    )
                }
                NavRow(showBack = false, onBack = {}, continueLabel = "Continue") {
                    val trimmed = name.trim()
                    scope.launch {
                        if (trimmed.isNotEmpty()) graph.settings.set(OnboardingPrefs.PROFILE_NAME, trimmed)
                        store.advance()
                    }
                }
            }
        }
    }
}

/** Stage 2 — Apple Music sign-in (reuses [MusicKitAuth]); never blocks: "Continue without". */
@Composable
fun OnboardingAppleMusicStage(graph: AppGraph, store: OnboardingStore) {
    val scope = rememberCoroutineScope()
    val settings by graph.settings.settings.collectAsState(initial = AppSettings())
    var signingIn by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        scope.launch {
            signingIn = false
            when (val decoded = graph.musicKitAuth.decodeResult(result.data)) {
                is MusicKitAuth.AuthResult.Success -> {
                    error = null
                    runCatching { graph.musicKitDevTokenClient.prewarm() }
                }
                MusicKitAuth.AuthResult.Cancelled -> error = null
                is MusicKitAuth.AuthResult.Failed -> error = decoded.message
            }
        }
    }
    val signedIn = settings.hasAppleMusic

    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        OnboardingCard {
            Text("Sign in with Apple Music", style = MaterialTheme.typography.titleMedium)
            Text(
                "Play full songs straight from your Apple Music subscription. Apple Music is playback only — nothing is ever captured, recorded, or downloaded from it.",
                style = MaterialTheme.typography.bodyMedium,
            )
            if (signedIn) {
                Text("Signed in — ready to stream.", color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.testTag("onboarding-am-signedin"))
            } else {
                Button(
                    enabled = !signingIn,
                    modifier = Modifier.testTag("onboarding-am-signin"),
                    onClick = {
                        scope.launch {
                            error = null
                            signingIn = true
                            try {
                                launcher.launch(graph.musicKitAuth.signInIntent())
                            } catch (e: CancellationException) {
                                signingIn = false
                                throw e
                            } catch (t: Throwable) {
                                signingIn = false
                                error = t.message ?: "Apple Music sign-in is unavailable"
                            }
                        }
                    },
                ) { Text(if (signingIn) "Connecting…" else "Sign in") }
                Text(
                    "Without signing in (or on an emulator) 30-second previews play instead.",
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.testTag("onboarding-am-previews-only"),
                )
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            Text("Change this anytime in Settings ▸ Apple Music.", style = MaterialTheme.typography.bodySmall)
        }
        NavRow(
            showBack = true,
            onBack = store::back,
            continueLabel = if (signedIn) "Continue" else "Continue without Apple Music",
            onContinue = store::advance,
        )
    }
}

/** Stage 3 — shared sources (Vinyl / Digital / Streaming); zero picks are legitimate. */
@Composable
fun OnboardingSourcesStage(graph: AppGraph, store: OnboardingStore) {
    val scope = rememberCoroutineScope()
    var vinyl by rememberSaveable { mutableStateOf(true) }
    var digital by rememberSaveable { mutableStateOf(true) }
    var streaming by rememberSaveable { mutableStateOf(true) }
    var finishing by remember { mutableStateOf(false) }

    @Composable
    fun sourceCard(title: String, detail: String, on: Boolean, tag: String, set: (Boolean) -> Unit) {
        OnboardingCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(title, style = MaterialTheme.typography.titleMedium)
                    Text(detail, style = MaterialTheme.typography.bodyMedium)
                }
                Switch(checked = on, onCheckedChange = set, modifier = Modifier.testTag(tag))
            }
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        sourceCard(
            "Shared vinyl catalog",
            "The PocketDJ vinyl collection — digitized records, analyzed for tempo, key, and mood.",
            vinyl, "onboarding-source-vinyl",
        ) { vinyl = it }
        sourceCard(
            "Shared digital catalog",
            "The PocketDJ digital collection — pre-prepared files that play and download with no extra step.",
            digital, "onboarding-source-digital",
        ) { digital = it }
        sourceCard(
            "Shared Apple Music catalog",
            "The PocketDJ Apple Music catalog — metadata only. Songs play through your own Apple Music subscription.",
            streaming, "onboarding-source-streaming",
        ) { streaming = it }
        Text(
            if (vinyl || digital || streaming) {
                "Signed in to Apple Music? Your own library and playlists are added automatically."
            } else {
                "No shared catalogs — the browser will show just your own Apple Music library (added automatically after sign-in)."
            },
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.testTag("onboarding-own-library-note"),
        )
        NavRow(
            showBack = true,
            onBack = store::back,
            continueLabel = "Start DJing",
            continueEnabled = !finishing,
        ) {
            finishing = true
            scope.launch {
                try {
                    graph.settings.applyOnboardingSources(vinyl, digital, streaming)
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // Never strand the user on stage 3: keep the default sources and finish.
                    android.util.Log.e("PocketDJ", "[onboarding] saving sources failed; finishing with defaults", e)
                }
                store.complete()
            }
        }
    }
}
