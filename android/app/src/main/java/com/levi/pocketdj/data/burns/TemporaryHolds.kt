package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.edition.SongVariant

/**
 * The temporary-vs-pinned ledger rules (iOS `BurnStore` "Temporary holds"), pure and
 * unit-testable. ABSENCE OF A HOLD = PINNED: every pre-existing file, every explicit
 * Download / Mix result and everything not CREATED by the buffer lane has no hold and is never
 * touched by the expiry sweep. Not thread-safe; [BurnStore] serialises access.
 */
class TemporaryHoldLedger(initial: Collection<TemporaryHold> = emptyList()) {
    private val map = LinkedHashMap<String, TemporaryHold>().also { m -> initial.forEach { m.putIfAbsent(it.songId, it) } }

    /** Replace the contents (ledger load). */
    fun load(initial: Collection<TemporaryHold>) {
        map.clear(); initial.forEach { map.putIfAbsent(it.songId, it) }
    }

    val holds: Map<String, TemporaryHold> get() = LinkedHashMap(map)
    val isEmpty: Boolean get() = map.isEmpty()
    operator fun get(songId: String): TemporaryHold? = map[songId]

    fun isTemporary(songId: String): Boolean = map[songId]?.audio == true
    fun expiry(songId: String): Double? = map[songId]?.expiresAtMs
    val footprintBytes: Long get() = map.values.sumOf { it.bytes }

    /** Document encoding: null when empty so a hold-free ledger stays byte-identical to iOS-shaped JSON. */
    fun toDocument(): List<TemporaryHold>? = map.values.toList().takeIf { it.isNotEmpty() }

    /**
     * PROMOTE: drop the holds of [songIds], keep their files. Matches by BASE song id so pinning a
     * row also pins its edition variants' holds (over-pinning only keeps a file). Returns the
     * dropped song ids.
     */
    fun pin(songIds: Iterable<String>): List<String> {
        if (map.isEmpty()) return emptyList()
        val bases = songIds.filter { it.isNotEmpty() }.map { SongVariant.baseId(it) }.toSet()
        if (bases.isEmpty()) return emptyList()
        val hit = map.keys.filter { SongVariant.baseId(it) in bases }
        hit.forEach { map.remove(it) }
        return hit
    }

    /** "Keep all": every buffered asset becomes a normal download. Returns how many holds dropped. */
    fun pinAll(): Int = map.size.also { map.clear() }

    /** Remove one hold outright (the sweep, after deleting its files). */
    fun drop(songId: String): TemporaryHold? = map.remove(songId)

    /** Replace (or, with null, remove) one hold: the sweep's post-removal write. */
    fun replace(songId: String, hold: TemporaryHold?) { if (hold == null) map.remove(songId) else map[songId] = hold }

    /** Files for [songIds] are gone (removeBurns): their holds go with them. */
    fun dropAll(songIds: Collection<String>) { songIds.forEach { map.remove(it) } }

    /** Stem parts of [songId] were deleted: forget them in its hold (an emptied hold is removed). */
    fun forgetStemParts(songId: String, parts: Collection<String>) {
        val h = map[songId] ?: return
        val left = h.stemParts - parts.toSet()
        val updated = h.copy(
            stemParts = left,
            stemBytes = h.stemBytes?.minus(parts.toSet())?.takeIf { it.isNotEmpty() },
            stemPartsInUserFolder = h.stemPartsInUserFolder?.minus(parts.toSet())?.takeIf { it.isNotEmpty() },
        )
        if (updated.isEmpty) map.remove(songId) else map[songId] = updated
    }

    /** What the buffer lane just created for one song. */
    data class Created(
        val songId: String,
        val audioBytes: Long? = null,
        val stemPart: String? = null,
        val stemBytes: Long = 0,
        val inUserFolder: Boolean = false,
        val folderPath: String? = null,
        /** The created user-folder file's name + modification time (identity for the sweep). */
        val fileName: String? = null,
        val fileMtimeMs: Double? = null,
        /** The song's already-held audio lives in a user folder (released on a folder switch). */
        val heldAudioInUserFolder: Boolean = false,
    )

    /**
     * The buffer lane CREATED an asset: add it to the song's hold with expiry now + TTL (moves an
     * existing expiry later, never earlier). [ttlHours] null = "Keep": no hold, a normal download
     * from birth. Picked-folder assets are pinned at creation when [keepPickedFolder] is on, or
     * when the file's identity can't be read. Returns the resulting hold, or null when pinned.
     */
    fun noteCreated(c: Created, nowMs: Double, ttlHours: Double?, keepPickedFolder: Boolean): TemporaryHold? {
        if (ttlHours == null) return null
        if (c.inUserFolder && keepPickedFolder) return null
        if (c.inUserFolder && c.fileName != null && c.fileMtimeMs == null) return null
        val expires = nowMs + ttlHours * 3_600_000.0
        var h = map[c.songId] ?: TemporaryHold(c.songId, audio = false, stemParts = emptyList(), createdAtMs = nowMs, expiresAtMs = expires)
        h = h.copy(expiresAtMs = maxOf(h.expiresAtMs, expires))
        if (c.inUserFolder) {
            if (h.userFolderPath != null && h.userFolderPath != c.folderPath) {
                // The picked folder changed since earlier user-folder assets landed: release them
                // (kept on disk, pinned) - the sweep must never resolve them in the new folder.
                val released = (h.stemPartsInUserFolder ?: emptyList()).toSet()
                h = h.copy(
                    stemParts = h.stemParts.filterNot { it in released },
                    stemBytes = h.stemBytes?.minus(released)?.takeIf { it.isNotEmpty() },
                    stemPartsInUserFolder = null,
                    userFolderFiles = null,
                    audio = h.audio && !c.heldAudioInUserFolder,
                    audioBytes = if (h.audio && c.heldAudioInUserFolder) null else h.audioBytes,
                )
            }
            h = h.copy(userFolderPath = c.folderPath)
            if (c.fileName != null && c.fileMtimeMs != null) {
                h = h.copy(userFolderFiles = (h.userFolderFiles ?: emptyMap()) + (c.fileName to c.fileMtimeMs))
            }
        }
        if (c.audioBytes != null) h = h.copy(audio = true, audioBytes = c.audioBytes)
        c.stemPart?.let { part ->
            val uf = (h.stemPartsInUserFolder ?: emptyList()).toMutableSet()
            if (c.inUserFolder) uf.add(part) else uf.remove(part)
            h = h.copy(
                stemParts = if (part in h.stemParts) h.stemParts else h.stemParts + part,
                stemBytes = (h.stemBytes ?: emptyMap()) + (part to c.stemBytes),
                stemPartsInUserFolder = uf.sorted().takeIf { it.isNotEmpty() },
            )
        }
        map[c.songId] = h
        return h
    }
}
