package com.levi.pocketdj.shell

import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.NOW_PLAYING_PLAYLIST_ID
import com.levi.pocketdj.screens.collections.AddToActions
import com.levi.pocketdj.screens.collections.AddToItem

/** What an add said (iOS `AddToCollectionResult`; [dialog] is the toast / spoken line, verbatim). */
data class AddToCollectionResult(
    val songTitle: String,
    val collectionName: String,
    /** Already a member: nothing was written (the sheet's tap would REMOVE; voice / links never do). */
    val alreadyMember: Boolean,
) {
    val dialog: String
        get() = if (alreadyMember) "$songTitle is already in $collectionName." else "Added $songTitle to $collectionName."
}

/**
 * The id a collection travels under across doors (`pocket:<id>` / `playlist:<id>`, iOS
 * `CollectionEntity.addTarget(from:)`). A `setlist:` id, an unknown prefix or an empty id is not an add target.
 */
object CollectionRef {
    fun target(collectionId: String): AddTarget? {
        val kind = when {
            collectionId.startsWith("pocket:") -> AddTarget.Kind.POCKET
            collectionId.startsWith("playlist:") -> AddTarget.Kind.PLAYLIST
            else -> return null
        }
        val id = collectionId.substringAfter(':')
        return if (id.isBlank()) null else AddTarget(kind, id)
    }

    fun encode(target: AddTarget): String = "${target.kind.token}:${target.id}"
}

/** "This song" = the AUDIBLE owner's track (iOS `currentSongId`). Pure so the rule is testable. */
object AudibleOwner {
    /**
     * @param sequencerRunning the Now Playing sequencer is running
     * @param mixActive the Mix owns a running deck or an auto mix is on
     * @param mixSongId the live Mix deck's song
     * @param sequencerSongId the sequencer's current row (playing OR paused)
     */
    fun songId(
        sequencerRunning: Boolean,
        mixActive: Boolean,
        mixSongId: String?,
        sequencerSongId: String?,
    ): String? {
        val npAudible = sequencerRunning && !mixActive
        if (!npAudible && mixActive && mixSongId != null) return mixSongId
        return sequencerSongId ?: mixSongId
    }
}

/**
 * The add itself, over [CollectionsStore] only (iOS `IntentServices.addSongToCollection` after its veto /
 * lookup preamble). Lands exactly where the Add-to sheet's row tap lands: a pocket's membership, or a
 * playlist's FIRST chapter, through [AddToActions.add] so the Recent row, History > Activity and the
 * Apple Music write-back all see a normal add. A member is never toggled off; the reserved Now Playing
 * playlist is never a target.
 */
class AddToCollectionAction(private val store: CollectionsStore) {
    fun add(songId: String, songTitle: String, collectionId: String): AddToCollectionResult {
        var target = CollectionRef.target(collectionId) ?: throw ShellActionException.CollectionNotFound
        val name: String
        when (target.kind) {
            AddTarget.Kind.POCKET -> {
                name = (store.pocket(target.id) ?: throw ShellActionException.CollectionNotFound).name
            }
            AddTarget.Kind.PLAYLIST -> {
                if (target.id == NOW_PLAYING_PLAYLIST_ID) throw ShellActionException.CollectionNotFound
                val pl = store.playlist(target.id) ?: throw ShellActionException.CollectionNotFound
                name = pl.name
                target = target.copy(sequenceId = pl.sequences.firstOrNull()?.nodeId)
            }
        }
        val actions = AddToActions(AddToItem.Song(songId), store)
        if (actions.isMember(target)) return AddToCollectionResult(songTitle, name, alreadyMember = true)
        actions.add(target)
        return AddToCollectionResult(songTitle, name, alreadyMember = false)
    }
}
