package com.levi.pocketdj.screens.foryou

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.recommendationsEnabled
import com.levi.pocketdj.data.collections.setRecommendationsEnabled

object CollectionRecsCopy {
    /**
     * WHERE IT COMES BACK. Not a toast: the tile vanishing is the confirmation, so this notice
     * only carries the two places the switch still lives once it has.
     */
    fun offNotice(name: String): String =
        "PocketDJ won’t suggest songs for “$name” any more, and its tile is gone from " +
            "For You.\n\nTurn it back on from that collection’s ⋯ menu, or in Settings ▸ For You."
}

/**
 * "Recommendations" switch for one collection (playlist or pocket; id of unknown kind). Reads the
 * LIVE flag so the row never lies about its state; [onTurnedOff] fires only when an off actually
 * landed (the id still resolves).
 */
@Composable
fun CollectionRecsToggle(
    collections: CollectionsStore,
    collectionId: String,
    idPrefix: String,
    modifier: Modifier = Modifier,
    onTurnedOff: (() -> Unit)? = null,
) {
    @Suppress("UNUSED_VARIABLE")
    val rev by collections.state.collectAsState() // recompose on any collection change
    val on = collections.recommendationsEnabled(collectionId)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        Icon(Icons.Filled.AutoAwesome, contentDescription = null, modifier = Modifier.size(20.dp))
        Text("Recommendations", modifier = Modifier.weight(1f).padding(start = 12.dp))
        Switch(
            checked = on,
            onCheckedChange = { want ->
                if (collections.setRecommendationsEnabled(want, collectionId) && !want) onTurnedOff?.invoke()
            },
            modifier = Modifier.testTag("$idPrefix-recs-toggle"),
        )
    }
}
