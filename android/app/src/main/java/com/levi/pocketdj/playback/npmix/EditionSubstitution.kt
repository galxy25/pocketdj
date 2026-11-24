package com.levi.pocketdj.playback.npmix

import com.levi.pocketdj.data.edition.EditionPolicy
import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.mix.nowplaying.StemLockState
import com.levi.pocketdj.playback.sequencer.QueueItem

/**
 * Stem Lock edition rule A (iOS 428a16ef, `SetlistPlayer.vocalsMutedEditionSubstitute`; design android-parity2 4.5).
 *
 * A Stem Lock carrying stems with the VOCALS MUTED makes the two editions of a song sound the same (the edition
 * difference lives in the vocals). A PREFERENCE row whose wanted edition has no rip/burn therefore plays the BASE cut
 * plus stems instead of an Apple Music start where the lock could mute nothing. Pure decisions only; the host
 * ([com.levi.pocketdj.di.MixGraph]) supplies [Facts] and the sequencer applies the result at the row's start.
 *
 * Sticky for the row: the substitution is written into the queue row's `resolveId`, so un-muting mid-track keeps the
 * substituted local file. Never applies to `editionLocked` rows, Q94 `cleanOnlySkip` rows or clean-only runs.
 */
object EditionSubstitution {
    /** What the host knows about a row's two candidate files, evaluated now (unmemoized: dots must agree with the start). */
    data class Facts(
        /** The wanted edition (`resolveId`) is on device or ripped: no substitution. */
        val wantedAvailable: Boolean,
        /** The base cut (`id`) is on device (burned) or ripped. */
        val baseAvailable: Boolean,
        /** The base cut has stems burned or separable remotely. */
        val baseHasStems: Boolean,
    )

    /** The lock carries stems with the vocals muted. */
    fun mutesVocals(lock: StemLockState): Boolean = lock.wantsStems && "vocals" in lock.muted

    /** The base id [item] would play instead of its wanted edition, or null (rule A does not apply). */
    fun substitute(item: QueueItem, lock: StemLockState, collectionCleanOnly: Boolean, facts: Facts): String? {
        if (!mutesVocals(lock)) return null
        if (!EditionPolicy.allowsVocalsMutedSubstitution(item, collectionCleanOnly)) return null
        if (facts.wantedAvailable) return null
        if (!facts.baseAvailable) return null
        if (!facts.baseHasStems) return null
        return item.id
    }

    /**
     * The id the buffer lane fetches / the dots key on for [item]: the playing row's sticky choice (its `resolveId`),
     * else rule A as of now, else the wanted edition's id.
     */
    fun laneAudioId(item: QueueItem, isCurrent: Boolean, substitute: String?): String =
        if (isCurrent) item.resolveId else substitute ?: item.resolveId

    /**
     * B: will THIS row play from a local file right now? [ladderLocal] = the edition ladder's burned file exists;
     * under a Stem Lock / Mix Mode ([laneActive]) the lane's complete cut of [laneAudioId] also counts. Never another
     * edition's copy that the start would skip.
     */
    fun rowWillPlayLocally(studioOrProfile: Boolean, ladderLocal: Boolean, laneActive: Boolean, laneCutLocal: Boolean): Boolean =
        studioOrProfile || ladderLocal || (laneActive && laneCutLocal)

    /** The edition label of the cut that actually plays (the opposite of the requested variant). */
    fun playedLabel(requested: String?): String = if (requested == SongVariant.EXPLICIT.raw) "clean" else "explicit"

    /** `[npmix] edition-substitute row=… played=… requested=… reason=vocals-muted` (the `[npmix]` lane prefix is the logger's). */
    fun logLine(item: QueueItem, via: String, file: String): String =
        "edition-substitute row=${item.id} played=${playedLabel(item.variant)} requested=${item.variant ?: "-"} " +
            "reason=vocals-muted via=$via file=$file"
}
