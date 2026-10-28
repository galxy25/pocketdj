package com.levi.pocketdj.screens.producer

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.levi.pocketdj.di.AppGraph

/**
 * Route glue for the Producer tab. The shell's nav host calls [ProducerRoute] for the Producer
 * destination (the only shared-file edit STU-3 makes); sub-tab state is internal to [ProducerScreen],
 * so no extra nav routes exist yet. Later Studio packages (arranger fullscreen, score) add theirs here.
 */
object ProducerRoutes {
    /** Sub-tab selection is persisted (AppSettings `studioTab`), not a nav argument. */
    const val ROUTE_NOTE = "producer"
}

@Composable
fun ProducerRoute(graph: AppGraph, modifier: Modifier = Modifier) {
    ProducerScreen(graph, modifier)
}
