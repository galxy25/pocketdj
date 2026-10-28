package com.levi.pocketdj

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.shell.IntentSink
import com.levi.pocketdj.shell.PocketDjApp
import com.levi.pocketdj.ui.theme.PocketDjTheme
import kotlinx.coroutines.launch

/**
 * Deliberately thin (decision D3): it builds the graph, hosts [PocketDjApp] and forwards
 * every launch / new intent to [IntentSink]. Deep links, file opens and Assistant intents
 * are handled by FeatureModule handlers — this file is not edited for them.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Eagerly build the graph + history store so every play is recorded
        // (the store subscribes to PlayEventBus) even before any screen opens.
        // The store constructor reads + decodes the whole log from disk (multi-MB
        // at the 20k cap), so construction happens OFF-MAIN per its own contract.
        val graph = AppGraph.get(this)
        val appContext = applicationContext
        graph.appScope.launch { PlayHistoryStore.get(appContext) }
        setContent {
            PocketDjTheme {
                PocketDjApp()
            }
        }
        // A cold launch carries its intent (deep link, file open); a re-created activity
        // (savedInstanceState != null) must not replay the original one.
        if (savedInstanceState == null) intent?.let { IntentSink.dispatch(it) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        IntentSink.dispatch(intent)
    }

    override fun onStart() {
        super.onStart()
        // Foreground re-check of the remote endpoint config (throttled inside to 15 min).
        AppGraph.get(this).refreshEndpoints()
    }
}
