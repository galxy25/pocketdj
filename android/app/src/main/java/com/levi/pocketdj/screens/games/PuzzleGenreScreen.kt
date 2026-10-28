package com.levi.pocketdj.screens.games

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.screens.browse.Genre

/** Multi-select genre category checklist (iOS `genrePicker`). Back returns to setup. */
@Composable
fun PuzzleGenreScreen(
    selected: Set<String>,
    onToggle: (String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    Column(modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        androidx.compose.foundation.layout.Row(
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        ) {
            TextButton(onClick = onBack) { Text("‹ Back") }
            Text("Genres", style = MaterialTheme.typography.titleLarge)
        }
        LazyColumn {
            items(Genre.categoryNames, key = { it }) { name ->
                PuzzleCheckRow(name, name in selected, { onToggle(name) }, "puzzle-genre-$name")
            }
        }
    }
}
