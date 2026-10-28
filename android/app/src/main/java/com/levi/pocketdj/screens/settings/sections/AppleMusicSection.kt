package com.levi.pocketdj.screens.settings.sections

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.applemusic.MusicKitAuth
import com.levi.pocketdj.screens.settings.SectionHeader
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsSections
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

internal fun appleMusicSection() = SettingsSection(SettingsSections.APPLE_MUSIC, 400) { host ->
    val graph = host.graph
    // Apple Music sign-in (specs/applemusic.md §7). The Music-User-Token round-trip runs
    // through the Apple Music app; the ActivityResult launcher registers against the host
    // activity from here. [DEVICE-ONLY]: on the emulator the deep link can't complete and
    // the result decodes to Cancelled/Failed — never a crash.
    var signingIn by remember { mutableStateOf(false) }
    var appleMusicError by remember { mutableStateOf<String?>(null) }
    val authLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        host.scope.launch {
            signingIn = false
            when (val decoded = graph.musicKitAuth.decodeResult(result.data)) {
                is MusicKitAuth.AuthResult.Success -> {
                    appleMusicError = null
                    // Pre-warm the dev token so the first AM play is instant.
                    graph.musicKitDevTokenClient.prewarm()
                }
                is MusicKitAuth.AuthResult.Cancelled -> appleMusicError = null
                is MusicKitAuth.AuthResult.Failed -> appleMusicError = decoded.message
            }
        }
    }

    SectionHeader("Apple Music")
    val current = host.settings
    when {
        current == null -> Unit
        // Signed-in check FIRST: a user who signed in and later blanked their Import
        // server must still be able to sign out.
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
                        host.scope.launch {
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
            // The developer token is minted BY the rip server (§5): no server, no sign-in.
            OutlinedButton(onClick = {}, enabled = false) {
                Text("Sign in with Apple Music")
            }
            SettingsCaption("Add an Import server first — it mints the Apple Music developer token.")
        }
        else -> {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Button(
                    enabled = !signingIn,
                    onClick = {
                        host.scope.launch {
                            appleMusicError = null
                            signingIn = true
                            try {
                                // Fetch the dev token + build the intent FIRST so a
                                // server/token failure surfaces before Apple Music opens.
                                val intent = graph.musicKitAuth.signInIntent()
                                authLauncher.launch(intent)
                                // signingIn stays true until the result callback fires.
                            } catch (error: CancellationException) {
                                signingIn = false
                                throw error
                            } catch (error: Throwable) {
                                signingIn = false
                                appleMusicError = error.message ?: "Apple Music sign-in is unavailable"
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
}
