package com.levi.pocketdj.data.sync

/**
 * One synced document as it exists in the cloud: an opaque payload (the same bytes the owning
 * store persists to its file) plus the write metadata [CloudSyncService] compares for
 * last-writer-wins. Port of iOS `CloudDoc`.
 */
class CloudDoc(
    val key: String,
    val payload: ByteArray,
    /** Epoch ms of the WRITER's local file when it pushed - the LWW comparison value. */
    val modifiedAtMs: Double,
    /** The pushing device's name (surfaced in Settings > Profile). */
    val deviceName: String,
) {
    override fun equals(other: Any?): Boolean =
        other is CloudDoc && key == other.key && modifiedAtMs == other.modifiedAtMs &&
            deviceName == other.deviceName && payload.contentEquals(other.payload)

    override fun hashCode(): Int =
        ((key.hashCode() * 31 + modifiedAtMs.hashCode()) * 31 + deviceName.hashCode()) * 31 + payload.contentHashCode()

    override fun toString(): String = "CloudDoc($key, ${payload.size}B, mtime=$modifiedAtMs, $deviceName)"
}
