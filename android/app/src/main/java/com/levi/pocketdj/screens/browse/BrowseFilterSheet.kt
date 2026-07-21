package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp

/**
 * P1 filter sheet — the task-locked field cut: genre, BPM range, key (Camelot),
 * source (specs/browse.md §6.5). Selections AND-compose; each section is one
 * clause of the shared engine semantics in [BrowseFilters].
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun BrowseFilterSheet(
    filters: BrowseFilters,
    genreOptions: List<String>,
    camelotOptions: List<String>,
    sourceOptions: List<String>,
    onFilters: (BrowseFilters) -> Unit,
    onDismiss: () -> Unit,
) {
    // BPM bounds edit as local text, committed on every keystroke that parses.
    var bpmMinText by remember { mutableStateOf(filters.bpmMin?.let(::trimDouble) ?: "") }
    var bpmMaxText by remember { mutableStateOf(filters.bpmMax?.let(::trimDouble) ?: "") }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .navigationBarsPadding()
                .padding(bottom = 24.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text(
                    "Filters",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                TextButton(
                    onClick = {
                        bpmMinText = ""
                        bpmMaxText = ""
                        onFilters(BrowseFilters())
                    },
                    enabled = filters.activeCount > 0,
                ) {
                    Text("Clear all")
                }
            }

            if (genreOptions.isNotEmpty()) {
                SectionLabel("Genre")
                OptionChips(
                    options = genreOptions,
                    selected = filters.genres,
                    onSelected = { onFilters(filters.copy(genres = it)) },
                )
            }

            SectionLabel("BPM")
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                OutlinedTextField(
                    value = bpmMinText,
                    onValueChange = { text ->
                        bpmMinText = text
                        onFilters(filters.copy(bpmMin = text.toDoubleOrNull()))
                    },
                    label = { Text("Min") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(12.dp))
                Text("–", color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.width(12.dp))
                OutlinedTextField(
                    value = bpmMaxText,
                    onValueChange = { text ->
                        bpmMaxText = text
                        onFilters(filters.copy(bpmMax = text.toDoubleOrNull()))
                    },
                    label = { Text("Max") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                )
            }
            Text(
                "Applies to songs; songs without a BPM are hidden while set.",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp),
            )

            if (camelotOptions.isNotEmpty()) {
                SectionLabel("Key (Camelot)")
                OptionChips(
                    options = camelotOptions,
                    selected = filters.camelots,
                    onSelected = { onFilters(filters.copy(camelots = it)) },
                )
            }

            if (sourceOptions.size > 1) {
                SectionLabel("Source")
                OptionChips(
                    options = sourceOptions,
                    selected = filters.sources,
                    onSelected = { onFilters(filters.copy(sources = it)) },
                )
            }
        }
    }
}

private fun trimDouble(value: Double): String =
    if (value == value.toLong().toDouble()) value.toLong().toString() else value.toString()

@Composable
private fun SectionLabel(text: String) {
    Spacer(Modifier.height(16.dp))
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Spacer(Modifier.height(6.dp))
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun OptionChips(
    options: List<String>,
    selected: Set<String>,
    onSelected: (Set<String>) -> Unit,
) {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        options.forEach { option ->
            FilterChip(
                selected = option in selected,
                onClick = {
                    onSelected(if (option in selected) selected - option else selected + option)
                },
                label = { Text(option) },
            )
        }
    }
}
