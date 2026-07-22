package com.levi.pocketdj.data.storage

import android.content.Context
import coil.annotation.ExperimentalCoilApi
import coil.imageLoader

/**
 * The measurable + clearable face of Coil's artwork cache (specs/storage.md
 * §2.2). An interface so [StorageService] stays a plain JVM unit — the real
 * implementation talks to the default singleton `ImageLoader` that `AsyncImage`
 * populates; tests pass a fake.
 */
interface ArtworkCache {
    /** Bytes on disk Coil reports (`DiskCache.size`), or 0 when no disk cache. */
    fun diskSizeBytes(): Long

    /** Clear both the disk and memory image caches. Best-effort. */
    fun clear()
}

/**
 * Coil-backed [ArtworkCache] over the process default `ImageLoader`
 * (`context.imageLoader`) — the SAME singleton `AsyncImage` uses, since the app
 * registers no custom `ImageLoaderFactory` (specs/storage.md §2.2). Reads Coil's
 * own counters rather than walking the directory.
 */
@OptIn(ExperimentalCoilApi::class)
class CoilArtworkCache(context: Context) : ArtworkCache {
    private val appContext = context.applicationContext

    override fun diskSizeBytes(): Long =
        runCatching { appContext.imageLoader.diskCache?.size ?: 0L }.getOrDefault(0L)

    override fun clear() {
        runCatching {
            appContext.imageLoader.apply {
                diskCache?.clear()
                memoryCache?.clear()
            }
        }
    }
}
