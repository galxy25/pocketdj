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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/** The seam to the listening-pockets settings (the services wave owns the real switch). */
interface PocketsOptIn {
    /** Pockets ride the rec engine's consent: without Recommendations the switch can't open the gate. */
    val recommendationsEnabled: Boolean
    fun choose(on: Boolean)
}

object PocketsOptInCopy {
    const val TITLE = "Play In the Pocket?"
    const val LEAD =
        "In the Pocket picks 3-4 songs it predicts you'll play straight through, right now, wherever you are. " +
            "It needs listening pockets on - and every round you play teaches them."
    const val CONSENT =
        "Listening pockets send which songs you played (and when) to PocketDJ's recommendation service " +
            "so it can find the stretches you play straight through. You can turn this off any time in Settings."
    const val NEEDS_RECS = "Listening pockets also need Recommendations turned on in Settings."
}

/** The opt-in offer ("Not now" / "Turn on"); the game never turns pockets on by itself. */
@Composable
fun PocketsOptInView(optIn: PocketsOptIn, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(32.dp).testTag("pockets-optin"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(PocketsOptInCopy.TITLE, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center)
        Text(PocketsOptInCopy.LEAD, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(PocketsOptInCopy.CONSENT, style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (!optIn.recommendationsEnabled) {
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
