package com.levi.pocketdj.data.jukebox

import android.content.Context
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.emptyPreferences
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.onboarding.OnboardingPrefs
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

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
                profileId = app.servicesGraph.enrolledProfileId(), // SVC-10
            )
        },
    )

    /** JBX-2 guest side: joined-sessions list (process-wide, UI-independent) + public client. */
    val joined: JoinedSessionsStore = joinedSessions(appContext)

    val guestClient: JukeboxGuestClient = JukeboxGuestClient(
        http = app.httpClient,
        json = app.json,
        installId = { app.settings.ensureInstallId() },
        configuredBase = { app.settings.current().jukeboxServerUrl },
    )

    val repository: JukeboxRepository = JukeboxRepository(
        context = appContext,
        client = client,
        sessionStore = JukeboxSessionStore(sessionDataStore, app.json),
        catalog = app.catalogRepository,
        rips = app.ripsRepository,
        playback = app.playbackController,
        scope = app.appScope,
        pocketDjName = {
            app.settings.get(OnboardingPrefs.PROFILE_NAME)
        },
    ).also { repo ->
        repo.queue = SequencerJukeboxQueue(app.playbackGraph.sequencer)
        // SURF-10: Apple Music catalog match stage + rip-backed placement for AM-only rows.
        var storefront: String? = null
        repo.externalMatch = JukeboxAppleMusicMatch(
            api = app.appleMusicApi,
            songs = { app.catalogRepository.state.value.catalog?.songs.orEmpty() },
            storefront = {
                storefront ?: (app.appleMusicApi.userStorefront() as? com.levi.pocketdj.data.applemusic.AmResult.Ok)
                    ?.value.also { storefront = it } ?: "us"
            },
        )
        repo.placementSink = JukeboxAmPlacementSink(isPlayable = app.ripsRepository::isPlayable)
        repo.adHocRipStarter = JukeboxAdHocRipStarter { song ->
            app.browseGraph.appleMusicRecognition.startRipAndBurn(
                song.id, song.name, song.artist, song.appleMusicId.orEmpty(),
            ) == com.levi.pocketdj.screens.shazam.RipStart.REQUESTED
        }
    }

    companion object {
        @Volatile
        private var instance: JukeboxGraph? = null

        @Volatile
        private var joinedInstance: JoinedSessionsStore? = null

        /**
         * The joined-sessions store on its own light DataStore file, so deep links / the route
         * resolver can use it without constructing the whole (player-bound) jukebox graph.
         */
        fun joinedSessions(context: Context): JoinedSessionsStore =
            joinedInstance ?: synchronized(this) {
                joinedInstance ?: run {
                    val app = AppGraph.get(context)
                    val ctx = context.applicationContext
                    val ds = PreferenceDataStoreFactory.create(
                        corruptionHandler = ReplaceFileCorruptionHandler { emptyPreferences() },
                        scope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
                    ) { File(ctx.filesDir, "pocketdj-jukebox-joined.preferences_pb") }
                    JoinedSessionsStore(DataStoreJoinedStorage(ds), app.appScope).also {
                        joinedInstance = it
                        app.appScope.launch(Dispatchers.IO) { it.load() }
                    }
                }
            }

        fun get(context: Context): JukeboxGraph =
            instance ?: synchronized(this) {
                instance ?: JukeboxGraph(context).also { instance = it }
            }
    }
}
