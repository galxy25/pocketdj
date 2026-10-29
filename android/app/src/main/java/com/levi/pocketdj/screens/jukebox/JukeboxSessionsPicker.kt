package com.levi.pocketdj.screens.jukebox

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.jukebox.JukeboxRepository
import com.levi.pocketdj.data.jukebox.JukeboxSessionRow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** What tapping a picker row does (tvOS `TVRootView.select`). Pure so the matrix is unit-testable. */
enum class SessionPickAction { ADOPT, END_THEN_ADOPT, ALREADY_HOSTING, IGNORE }

object JukeboxSessionsPickerLogic {
    const val LOAD_ERROR = "Couldn't reach the jukebox server — check Settings."

    /**
     * Same session active: nothing to do. Different active: end it first, then adopt (adopt's guard
     * refuses to clobber an active session). None: adopt. While a start/adopt is in flight, ignore.
     */
    fun decide(activeId: String?, busy: Boolean, targetId: String): SessionPickAction = when {
        busy -> SessionPickAction.IGNORE
        activeId == targetId -> SessionPickAction.ALREADY_HOSTING
        activeId != null -> SessionPickAction.END_THEN_ADOPT
        else -> SessionPickAction.ADOPT
    }

    /** Row sub-line: guest URL (scheme stripped) and, when the broker reports it, time left. */
    fun detail(row: JukeboxSessionRow, nowMs: Long): String {
        val url = row.url.removePrefix("https://").removePrefix("http://")
        val age = row.expiresAt?.let { ageText(it.toLong() - nowMs) }
        return listOfNotNull(url.takeIf { it.isNotBlank() }, age).joinToString(" · ")
    }

    fun ageText(remainingMs: Long): String {
        if (remainingMs <= 0) return "expired"
        val min = remainingMs / 60_000
        return when {
            min < 1 -> "ends in <1 min"
            min < 60 -> "ends in $min min"
            min < 24 * 60 -> "ends in ${min / 60} h"
            else -> "ends in ${min / (24 * 60)} d"
        }
    }

    fun title(row: JukeboxSessionRow) = row.name.ifBlank { JukeboxRepository.DEFAULT_SESSION_NAME }
}

/** Bottom sheet listing broker sessions; tapping one makes this device its host. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun JukeboxSessionsPickerSheet(repository: JukeboxRepository, activeId: String?, onDismiss: () -> Unit) {
    var rows by remember { mutableStateOf<List<JukeboxSessionRow>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(false) }
    var adoptingId by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun refresh() {
        scope.launch {
            loading = true
            try {
                rows = repository.listSessions()
                error = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = JukeboxSessionsPickerLogic.LOAD_ERROR
            } finally {
                loading = false
            }
        }
    }
    LaunchedEffect(Unit) { refresh() }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Jukebox sessions", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                if (loading) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                else TextButton(onClick = ::refresh) { Text("Refresh") }
            }
            Text(
                "Pick a session to host it from this device.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            error?.let {
                Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(top = 8.dp))
            }
            val list = rows
            if (list != null && list.isEmpty() && error == null) {
                Text("No live sessions.", style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 12.dp))
            }
            list?.forEach { row ->
                HorizontalDivider(color = MaterialTheme.colorScheme.outline)
                val hosting = row.jukeboxId == activeId
                Row(
                    Modifier.fillMaxWidth()
                        .clickable(enabled = adoptingId == null) {
                            when (JukeboxSessionsPickerLogic.decide(activeId, adoptingId != null, row.jukeboxId)) {
                                SessionPickAction.IGNORE -> Unit
                                SessionPickAction.ALREADY_HOSTING -> onDismiss()
                                SessionPickAction.ADOPT -> {
                                    repository.adopt(row.jukeboxId); onDismiss()
                                }
                                SessionPickAction.END_THEN_ADOPT -> {
                                    adoptingId = row.jukeboxId
                                    scope.launch {
                                        repository.endAndAwait()
                                        repository.adopt(row.jukeboxId)
                                        onDismiss()
                                    }
                                }
                            }
                        }
                        .padding(vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(JukeboxSessionsPickerLogic.title(row), style = MaterialTheme.typography.bodyLarge, maxLines = 1)
                        val detail = JukeboxSessionsPickerLogic.detail(row, System.currentTimeMillis())
                        if (detail.isNotBlank()) Text(detail, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    }
                    when {
                        hosting -> Text("Hosting here", style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.primary)
                        adoptingId == row.jukeboxId -> CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        else -> Text("Host & show QR", style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}
