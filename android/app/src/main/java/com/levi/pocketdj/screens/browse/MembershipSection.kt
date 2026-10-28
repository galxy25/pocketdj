package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp

/** (id, display name) for a playlist or pocket in the membership pickers. */
data class CollectionRef(val id: String, val name: String)

/** Collection-membership filter section (song mode): "In" (SHOW) + "Not in" (HIDE) + Clear membership. */
@Composable
fun MembershipSection(
    membership: MembershipFilter,
    playlists: List<CollectionRef>,
    pockets: List<CollectionRef>,
    onChange: (MembershipFilter) -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        MembershipPicker(
            title = "In playlist / pocket",
            tag = "include",
            any = membership.includeAny,
            ids = membership.includeIds,
            playlists = playlists,
            pockets = pockets,
            onAny = { onChange(membership.copy(includeAny = it)) },
            onIds = { onChange(membership.copy(includeIds = it)) },
        )
        MembershipPicker(
            title = "Not in playlist / pocket",
            tag = "exclude",
            any = membership.excludeAny,
            ids = membership.excludeIds,
            playlists = playlists,
            pockets = pockets,
            onAny = { onChange(membership.copy(excludeAny = it)) },
            onIds = { onChange(membership.copy(excludeIds = it)) },
        )
        if (membership.active) {
            TextButton(onClick = { onChange(membership.cleared()) }, modifier = Modifier.testTag("membership-clear")) {
                Text("Clear membership", color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
private fun MembershipPicker(
    title: String,
    tag: String,
    any: Boolean,
    ids: Set<String>,
    playlists: List<CollectionRef>,
    pockets: List<CollectionRef>,
    onAny: (Boolean) -> Unit,
    onIds: (Set<String>) -> Unit,
) {
    var expanded by rememberSaveable(tag) { mutableStateOf(false) }
    val summary = if (any) "any collection" else if (ids.isEmpty()) "off" else "${ids.size} selected"
    Column(Modifier.fillMaxWidth().testTag("membership-$tag")) {
        Text(
            "$title: $summary",
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.fillMaxWidth().clickable { expanded = !expanded }.padding(vertical = 10.dp),
        )
        if (expanded) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text("Any playlist / pocket", modifier = Modifier.weight(1f))
                Switch(checked = any, onCheckedChange = onAny, modifier = Modifier.testTag("$tag-any"))
            }
            if (!any) {
                if (playlists.isNotEmpty()) {
                    GroupLabel("Playlists")
                    playlists.forEach { CollectionCheckRow("♫ ${it.name}", it.id in ids, "$tag-chip-${it.id}") { on ->
                        onIds(if (on) ids + it.id else ids - it.id)
                    } }
                }
                if (pockets.isNotEmpty()) {
                    GroupLabel("Pockets")
                    pockets.forEach { CollectionCheckRow("◖ ${it.name}", it.id in ids, "$tag-chip-${it.id}") { on ->
                        onIds(if (on) ids + it.id else ids - it.id)
                    } }
                }
            }
        }
    }
}

@Composable
private fun GroupLabel(text: String) {
    Text(text, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 6.dp))
}

@Composable
private fun CollectionCheckRow(label: String, checked: Boolean, tag: String, onToggle: (Boolean) -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().clickable { onToggle(!checked) }.testTag(tag),
    ) {
        Checkbox(checked = checked, onCheckedChange = onToggle)
        Text(label, modifier = Modifier.weight(1f))
    }
}
