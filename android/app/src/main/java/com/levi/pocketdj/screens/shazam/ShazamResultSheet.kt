package com.levi.pocketdj.screens.shazam

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.levi.pocketdj.screens.settings.sections.AppleMusicRecognitionSection

/**
 * "Heard it" sheet (iOS ShazamResultSheet): the CRATE block (in-crate hit deep-links to song
 * detail, otherwise the recognized metadata) above the independent Apple Music block.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShazamResultSheet(
    match: ShazamMatch,
    onOpenSong: (songId: String) -> Unit,
    onOpenAlbum: (albumId: String) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .navigationBarsPadding()
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Heard it", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            val info = match.info
            AsyncImage(
                model = info.artworkUrl,
                contentDescription = null,
                modifier = Modifier.size(96.dp).clip(RoundedCornerShape(12.dp)),
            )
            when (match) {
                is ShazamMatch.InCatalog -> {
                    Text(match.song.name, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                    Text(match.song.artist, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("In your crate", color = MaterialTheme.colorScheme.primary)
                    TextButton(onClick = { onOpenSong(match.song.id) }) { Text("Open song") }
                }
                is ShazamMatch.NotInCatalog -> {
                    Text(info.title ?: "Unknown title", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                    Text(info.artist ?: "Unknown artist", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("Not in your crate", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            AppleMusicRecognitionSection(info = info, onOpenAlbum = onOpenAlbum)
            TextButton(onClick = onDismiss) { Text("Done") }
        }
    }
}
