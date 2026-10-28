package com.levi.pocketdj.playback.durable

import com.levi.pocketdj.shell.Flushable

/**
 * ON_STOP funnel hook (iOS `flush`): lands the freshest in-memory snapshot synchronously so an OS
 * kill right after backgrounding cannot drop the latest position. Runs on a worker thread
 * (the funnel blocks Main), so it never touches the engine: the writer's 1 Hz tick keeps the
 * store's in-memory position current and every structural change is saved as it happens.
 */
class AppLifecycleFlusher(private val store: PlaybackSessionStore) : Flushable {
    override suspend fun flush() = store.flush()
}
