package com.levi.pocketdj

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
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
        // Edge-to-edge: minSdk 35 + targetSdk 36 means the platform ENFORCES it on every device
        // this app installs on (transparent bars, content under them; Compose pads with
        // WindowInsets). The bar styling — light icons (PocketDJ is dark-only, like iOS's
        // .preferredColorScheme(.dark)) and no nav-bar scrim — lives in Theme.PocketDJ. We do NOT
        // call enableEdgeToEdge(): androidx.activity's pre-35 fallbacks (EdgeToEdgeApi26..30) call
        // Window.setStatusBarColor / setNavigationBarColor / layoutInDisplayCutoutMode, which Play
        // flags as deprecated edge-to-edge APIs.
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
