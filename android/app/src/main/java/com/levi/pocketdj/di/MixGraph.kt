package com.levi.pocketdj.di

import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.mix.store.MixDeckSessionStore
import com.levi.pocketdj.mix.store.MixSessionStore
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.Flushable
import com.levi.pocketdj.shell.ResetHook
import java.io.File

/**
 * Sidecar graph for the mix area (decision D3). Owns the two durable Mix documents
 * (`pocketdj-mix-decks.json`, `pocketdj-mix-sessions.json`) over the shared off-main
 * [VersionedJsonWriter]; packages in this area override the FeatureModule members they
 * contribute and add their own lazies here - never in AppGraph.
 */
class MixGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "mix"

    private val writerExecutor by lazy { VersionedJsonWriter.backgroundExecutor("pdj-mix-writer") }

    /** The live-mix snapshot (decks + crossfader + Auto-DJ). No disk I/O until load()/save(). */
    private val deckLazy = lazy {
        val f = File(app.appContext.filesDir, MixDeckSessionStore.FILE_NAME)
        MixDeckSessionStore(f, writer = VersionedJsonWriter(f, writerExecutor))
    }
    val mixDeckSession: MixDeckSessionStore get() = deckLazy.value

    /** The mix session action log (also the engine's recorder). */
    private val sessionsLazy = lazy {
        val f = File(app.appContext.filesDir, MixSessionStore.FILE_NAME)
        MixSessionStore(f, writer = VersionedJsonWriter(f, writerExecutor))
    }
    val mixSessions: MixSessionStore get() = sessionsLazy.value

    // ON_STOP: both documents are written inline so a process kill right after backgrounding
    // cannot lose the latest positions / events.
    override val flushables: List<Flushable> = listOf(
        Flushable {
            // Only stores that were actually built this process: constructing one just to
            // flush it would decode + rewrite an unchanged (possibly multi-MB) document on main.
            if (deckLazy.isInitialized()) deckLazy.value.flush()
            if (sessionsLazy.isInitialized()) sessionsLazy.value.flush()
        },
    )

    override val resetHooks: List<ResetHook> = listOf(
        ResetHook {
            if (deckLazy.isInitialized()) deckLazy.value.clear()
            else File(app.appContext.filesDir, MixDeckSessionStore.FILE_NAME).delete()
            if (sessionsLazy.isInitialized()) sessionsLazy.value.clear()
            else File(app.appContext.filesDir, MixSessionStore.FILE_NAME).delete()
        },
    )
}
