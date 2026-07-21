package com.levi.pocketdj.data.jukebox

import android.content.Context
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.emptyPreferences
import com.levi.pocketdj.di.AppGraph
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/**
 * Jukebox-feature object graph, hanging off [AppGraph] (the core graph is
 * owned by the integrator; this sidecar keeps the feature self-contained).
 * `JukeboxGraph.get(context)` anywhere; lazy process-wide singletons — the
 * repository must be app-scoped so the 4 s loop survives navigation.
 */
class JukeboxGraph private constructor(context: Context) {

    private val app = AppGraph.get(context)
    private val appContext = context.applicationContext

    /** Session persistence lives in its own small DataStore file. */
    private val sessionDataStore = PreferenceDataStoreFactory.create(
        // Corrupt file → defaults (session lost) instead of a crash on every save.
        corruptionHandler = ReplaceFileCorruptionHandler { emptyPreferences() },
        scope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
    ) {
        File(appContext.filesDir, "pocketdj-jukebox.preferences_pb")
    }

    val client: JukeboxClient = JukeboxClient(
        http = app.httpClient,
        json = app.json,
        configProvider = {
            val current = app.settings.current()
            JukeboxClient.Config(
                baseUrl = current.jukeboxServerUrl,
                token = current.jukeboxToken,
                installId = app.settings.ensureInstallId(),
            )
        },
    )

    val repository: JukeboxRepository = JukeboxRepository(
        context = appContext,
        client = client,
        sessionStore = JukeboxSessionStore(sessionDataStore, app.json),
        catalog = app.catalogRepository,
        rips = app.ripsRepository,
        playback = app.playbackController,
        scope = app.appScope,
    )

    companion object {
        @Volatile
        private var instance: JukeboxGraph? = null

        fun get(context: Context): JukeboxGraph =
            instance ?: synchronized(this) {
                instance ?: JukeboxGraph(context).also { instance = it }
            }
    }
}
