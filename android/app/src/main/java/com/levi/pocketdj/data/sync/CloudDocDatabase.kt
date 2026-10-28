package com.levi.pocketdj.data.sync

/**
 * The backend seam [CloudSyncService] talks through (iOS `CloudDocDatabase`). An interface so
 * the engine is driven end-to-end by [InMemoryCloudDocDatabase] in JVM tests; SVC-9 supplies the
 * S3/Lambda implementation. Keys are the static registry names ("collections", "profile", ...)
 * so no query is ever needed - everything is fetch-by-key.
 */
interface CloudDocDatabase {
    /** Whether an account/enrollment exists and the backend is reachable (sync can run at all). */
    suspend fun accountAvailable(): Boolean

    /**
     * Cheap metadata probe: key -> modifiedAtMs for each key that EXISTS in the cloud
     * (absent keys are simply missing). Never fetches payloads.
     */
    suspend fun fetchMeta(keys: List<String>): Map<String, Double>

    /** Full fetch of one document (null when it does not exist in the cloud). */
    suspend fun fetch(key: String): CloudDoc?

    /** Upsert one document (blind overwrite - the caller already did the LWW comparison). */
    suspend fun save(doc: CloudDoc)

    /** Delete one document. IDEMPOTENT: a missing record is success. */
    suspend fun delete(key: String)

    /** Delete many documents in one operation. Same idempotence. */
    suspend fun deleteAll(keys: List<String>)
}

/** Default database until a backend is configured (SVC-9): no account, so every pass is a no-op. */
object UnavailableCloudDocDatabase : CloudDocDatabase {
    override suspend fun accountAvailable(): Boolean = false
    override suspend fun fetchMeta(keys: List<String>): Map<String, Double> = emptyMap()
    override suspend fun fetch(key: String): CloudDoc? = null
    override suspend fun save(doc: CloudDoc) = Unit
    override suspend fun delete(key: String) = Unit
    override suspend fun deleteAll(keys: List<String>) = Unit
}
