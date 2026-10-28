package com.levi.pocketdj.di

import android.content.Intent
import com.levi.pocketdj.data.games.GameScoreboardStore
import com.levi.pocketdj.data.games.GamesPrefs
import com.levi.pocketdj.shell.DeepLinkHandler
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.ResetHook
import com.levi.pocketdj.shell.SyncEntry
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Sidecar graph for the games area (decision D3). GM-1 contributes the scoreboard store
 * (`pocketdj-game-scores.json`, union-synced), its "Reset everything" hook and the debug
 * `-e pdj.seedGames true` fixture seed. Later game packages add their lazies here.
 */
class GamesGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "games"

    val scoreboard: GameScoreboardStore by lazy {
        GameScoreboardStore(File(app.appContext.filesDir, GamesPrefs.SCOREBOARD_FILE))
    }

    override val resetHooks: List<ResetHook> = listOf(ResetHook { scoreboard.clear() })

    override val syncEntries: List<SyncEntry> =
        listOf(SyncEntry(GamesPrefs.SCOREBOARD_SYNC_KEY, GamesPrefs.SCOREBOARD_FILE))

    override val deepLinkHandlers: List<DeepLinkHandler> = listOf(
        DeepLinkHandler { intent ->
            if (isDebuggable() && wantsSeed(intent)) {
                app.appScope.launch(Dispatchers.IO) { runCatching { scoreboard.seedFixture(replaceExisting = true) } }
            }
            false // never consumes the intent
        },
    )

    private fun wantsSeed(intent: Intent): Boolean =
        intent.getBooleanExtra(GamesPrefs.SEED_EXTRA, false) ||
            intent.getStringExtra(GamesPrefs.SEED_EXTRA) == "true"

    private fun isDebuggable(): Boolean =
        (app.appContext.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
}
