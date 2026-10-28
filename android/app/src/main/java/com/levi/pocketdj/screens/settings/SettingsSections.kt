package com.levi.pocketdj.screens.settings

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.screens.settings.sections.aboutSection
import com.levi.pocketdj.screens.settings.sections.appleMusicSection
import com.levi.pocketdj.screens.settings.sections.catalogSection
import com.levi.pocketdj.screens.settings.sections.dataSourcesSection
import com.levi.pocketdj.screens.settings.sections.historySection
import com.levi.pocketdj.screens.settings.sections.importServerSection
import com.levi.pocketdj.screens.settings.sections.jukeboxBrokerSection
import com.levi.pocketdj.screens.settings.sections.storageSection
import com.levi.pocketdj.shell.SettingsSection

/**
 * The Settings section registry (decision D3). `SettingsScreen` renders
 * [ordered] of the aggregated FeatureModule sections; other areas append sections from
 * their sidecar graph and never edit SettingsScreen.
 */
object SettingsSections {
    /** The pre-existing blocks, in their shipped order (100…800). Owned by ShellGraph. */
    fun builtin(): List<SettingsSection> = listOf(
        dataSourcesSection(),
        catalogSection(),
        importServerSection(),
        appleMusicSection(),
        jukeboxBrokerSection(),
        historySection(),
        storageSection(),
        aboutSection(),
    )

    /** Stable sort by [SettingsSection.order] (ties keep registration order). */
    fun ordered(sections: List<SettingsSection>): List<SettingsSection> =
        sections.sortedBy { it.order }

    const val DATA_SOURCES = "dataSources"
    const val CATALOG = "catalog"
    const val IMPORT_SERVER = "importServer"
    const val APPLE_MUSIC = "appleMusic"
    const val JUKEBOX_BROKER = "jukeboxBroker"
    const val HISTORY = "history"
    const val STORAGE = "storage"
    const val ABOUT = "about"
}

// ---- Shared building blocks for sections -------------------------------------

@Composable
internal fun SectionHeader(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(bottom = 6.dp),
    )
}

@Composable
internal fun SectionDivider() {
    Spacer(Modifier.height(16.dp))
    HorizontalDivider()
    Spacer(Modifier.height(16.dp))
}

@Composable
internal fun SettingsCaption(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(vertical = 4.dp),
    )
}

@Composable
internal fun AboutRow(label: String, value: String) {
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
