package com.levi.pocketdj

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.ProcessLifecycleOwner
import com.levi.pocketdj.shell.FlushOnStop
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.shell.IntentSink
import com.levi.pocketdj.shell.PocketDjApp
import com.levi.pocketdj.ui.theme.PocketDjTheme
import com.levi.pocketdj.ui.dnd.songDropRoot
import kotlinx.coroutines.launch

/**
 * Deliberately thin (decision D3): it builds the graph, hosts [PocketDjApp] and forwards
 * every launch / new intent to [IntentSink]. Deep links, file opens and Assistant intents
 * are handled by FeatureModule handlers — this file is not edited for them.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // PocketDJ is dark-only (iOS pins .preferredColorScheme(.dark) at the app root), so the
        // system bars always draw LIGHT icons, whatever the system light/dark setting is.
        enableEdgeToEdge(
            statusBarStyle = androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        // Eagerly build the graph + history store so every play is recorded
        // (the store subscribes to PlayEventBus) even before any screen opens.
        // The store constructor reads + decodes the whole log from disk (multi-MB
        // at the 20k cap), so construction happens OFF-MAIN per its own contract.
        val graph = AppGraph.get(this)
        graph.startInteractive() // ANS-SHELL-1: playback wiring + rec flush; a worker cold start never gets here
        val appContext = applicationContext
        // Process-level ON_STOP: flush every module's pending writes (idempotent re-register guard).
        ProcessLifecycleOwner.get().lifecycle.let { lc ->
            if (!flushObserverAdded) {
                flushObserverAdded = true
                lc.addObserver(FlushOnStop(graph.features))
            }
        }
        graph.appScope.launch { PlayHistoryStore.get(appContext) }
        graph.servicesGraph.startCloudSync() // SVC-7: launch pass after onboarding, foreground + tick triggers
        setContent {
            PocketDjTheme {
                androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.songDropRoot()) { PocketDjApp() }
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

    // ProcessLifecycleOwner delays ON_STOP ~700 ms; flush on the Activity's own transitions so
    // a debounced writer survives Home + immediate kill. flushNow is serialized + idempotent.
    override fun onPause() {
        super.onPause()
        AppGraph.get(this).flushAsync()
    }

    override fun onStop() {
        super.onStop()
        AppGraph.get(this).flushAsync()
    }

    private companion object {
        @Volatile var flushObserverAdded = false
    }
}
