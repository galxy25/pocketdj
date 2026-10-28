package com.levi.pocketdj.data.sync

import java.util.concurrent.ConcurrentHashMap

/**
 * In-memory [CloudDocDatabase]: the test double for every sync doctrine and the debug-flag
 * stand-in until the real backend exists. Failure injection and latency hooks let tests drive
 * the probe-failure, deadline and timeout paths.
 */
class InMemoryCloudDocDatabase(
    var account: Boolean = true,
) : CloudDocDatabase {
    private val docs = ConcurrentHashMap<String, CloudDoc>()

    /** When non-null, [fetchMeta] throws it (the offline-on-the-way-to-background case). */
    @Volatile var metaFailure: Throwable? = null

    /** When non-null, [fetch] throws it (the probe `unknown` case). */
    @Volatile var fetchFailure: Throwable? = null

    /** Suspends before every network-ish call (virtual-time latency). */
    @Volatile var latency: suspend () -> Unit = {}

    @Volatile var fetchMetaCalls = 0
    @Volatile var fetchCalls = 0
    val saved = java.util.Collections.synchronizedList(mutableListOf<String>())

    fun put(doc: CloudDoc) { docs[doc.key] = doc }
    fun get(key: String): CloudDoc? = docs[key]
    val keys: Set<String> get() = docs.keys.toSet()

    override suspend fun accountAvailable(): Boolean { latency(); return account }

    override suspend fun fetchMeta(keys: List<String>): Map<String, Double> {
        latency()
        fetchMetaCalls++
        metaFailure?.let { throw it }
        return keys.mapNotNull { k -> docs[k]?.let { k to it.modifiedAtMs } }.toMap()
    }

    override suspend fun fetch(key: String): CloudDoc? {
        latency()
        fetchCalls++
        fetchFailure?.let { throw it }
        return docs[key]
    }

    override suspend fun save(doc: CloudDoc) {
        latency()
        docs[doc.key] = doc
        saved += doc.key
    }

    override suspend fun delete(key: String) { latency(); docs.remove(key) }

    override suspend fun deleteAll(keys: List<String>) { latency(); keys.forEach { docs.remove(it) } }
}
