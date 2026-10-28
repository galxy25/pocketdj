package com.levi.pocketdj.screens.games

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import kotlinx.coroutines.flow.StateFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/** The seam to the listening-pockets settings (the services wave owns the real switch). */
interface PocketsOptIn {
    /** Pockets ride the rec engine's consent: without Recommendations the switch can't open the gate. */
    val recommendationsEnabled: StateFlow<Boolean>
    fun choose(on: Boolean)
}

object PocketsOptInCopy {
    const val TITLE = "Play In the Pocket?"
    const val LEAD =
        "In the Pocket picks 3–4 songs it predicts you'll play straight through, right now, wherever you are. " +
            "It needs listening pockets on — and every round you play teaches them."
    /** Verbatim ListeningPocketsService.consentText (apple/PocketDJ/State/ListeningPocketsService.swift). */
    const val CONSENT =
        "Turning this on sends, for each play in the last 90 days and from now on: the song and its artist, " +
            "when it started (to the minute) and your time-zone offset, whether you finished or skipped it, " +
            "where in the app you played it (which collection, by id), and whether CarPlay was connected. " +
            "It also sends which songs are in each of your pockets and playlists and when you added them " +
            "(ids only, never their names). PocketDJ uses it to find the stretches where you were in a groove."
    fun showNeedsRecs(recommendationsEnabled: Boolean) = !recommendationsEnabled
    const val NEEDS_RECS = "Listening pockets also need Recommendations turned on in Settings."
}

/** The opt-in offer ("Not now" / "Turn on"); the game never turns pockets on by itself. */
@Composable
fun PocketsOptInView(
    optIn: PocketsOptIn,
    modifier: Modifier = Modifier,
    title: String = PocketsOptInCopy.TITLE,
    lead: String = PocketsOptInCopy.LEAD,
) {
    val recsEnabled by optIn.recommendationsEnabled.collectAsState()
    Column(
        modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(32.dp).testTag("pockets-optin"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center)
        Text(lead, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(PocketsOptInCopy.CONSENT, style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (PocketsOptInCopy.showNeedsRecs(recsEnabled)) {
            Text(PocketsOptInCopy.NEEDS_RECS, style = MaterialTheme.typography.bodySmall,
                fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.primary, modifier = Modifier.testTag("pockets-optin-needs-recs"))
        }
        Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.Center) {
            OutlinedButton(onClick = { optIn.choose(false) }, modifier = Modifier.testTag("pockets-optin-decline")) {
                Text("Not now")
            }
            Button(onClick = { optIn.choose(true) }, modifier = Modifier.padding(start = 12.dp).testTag("pockets-optin-accept")) {
                Text("Turn on")
            }
        }
    }
}
