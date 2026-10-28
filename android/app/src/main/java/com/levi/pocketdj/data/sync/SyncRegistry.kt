package com.levi.pocketdj.data.sync

import com.levi.pocketdj.shell.SyncEntry
import java.io.File

/**
 * Registers every synced document with the [CloudSyncService]: the shell-level core documents
 * (profile, collections, play-history, collection-activity, play-stats) plus whatever areas
 * contribute through `FeatureModule.syncEntries`. Keys and file names are the iOS names, so the
 * synced payloads are the same bytes on both platforms.
 *
 * Reload seams: each [SyncEntry.onPulled] calls the owning store's `reloadFromDisk()`; a
 * contributor with no seam registers file-only (pulled before it is read).
 */
object SyncRegistry {
    /** Core keys owned by the services area (the account-deletion sweep must cover these + contributed ones). */
    const val KEY_PROFILE = "profile"
    const val KEY_COLLECTIONS = "collections"
    const val KEY_PLAY_HISTORY = "play-history"
    const val KEY_COLLECTION_ACTIVITY = "collection-activity"
    const val KEY_PLAY_STATS = "play-stats"

    /** Registers [entries] against [service], resolving file names under [filesDir]. Returns the keys, in order. */
    fun registerAll(service: CloudSyncService, filesDir: File, entries: List<SyncEntry>): List<String> {
        val dup = entries.groupingBy { it.key }.eachCount().filterValues { it > 1 }.keys
        require(dup.isEmpty()) { "Duplicate sync key(s): ${dup.joinToString()}" }
        for (e in entries) {
            service.register(e.key, File(filesDir, e.fileName), reload = e.onPulled)
        }
        return entries.map { it.key }
    }
}
