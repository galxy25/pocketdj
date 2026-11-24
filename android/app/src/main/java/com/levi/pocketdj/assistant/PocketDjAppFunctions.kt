package com.levi.pocketdj.assistant

import androidx.appfunctions.AppFunctionContext
import androidx.appfunctions.service.AppFunction
import com.levi.pocketdj.shell.MixSource
import com.levi.pocketdj.shell.ShellActionException
import com.levi.pocketdj.shell.ShellActions
import com.levi.pocketdj.shell.StemPart
import com.levi.pocketdj.shell.autoMixLine
import com.levi.pocketdj.shell.pocketPlayingLine
import com.levi.pocketdj.data.pockets.PocketFitter

/**
 * The calls the AppFunctions are allowed to make: exactly the [ShellActions] doors, by id. Production is
 * [ShellActionsTarget]; tests record the calls. (Android AppFunctions = the Gemini equivalent of iOS's Siri AI
 * ToolIntents, `Intents/SiriAITools.swift`.)
 */
interface AppFunctionTarget {
    /** `collectionId` is `pocket:<id>` / `playlist:<id>`; a null song id means "the song playing now". Returns the dialog. */
    suspend fun addSong(songId: String?, collectionId: String): String
    suspend fun setMixMode(on: Boolean): String
    suspend fun setStem(stem: StemPart, muted: Boolean): String
    suspend fun playPlaylist(id: String, shuffle: Boolean): String
    suspend fun playPocket(id: String, shuffle: Boolean): String
    suspend fun playPocketForNow(): String
    suspend fun startAutoMix(source: MixSource, shuffle: Boolean): String
    suspend fun pauseAutoMix()
    suspend fun resumeAutoMix()
    suspend fun createPocket(brief: String, minutes: Int): String
}

/** The production [AppFunctionTarget]: one line per [ShellActions] door, no logic. */
class ShellActionsTarget(private val actions: ShellActions) : AppFunctionTarget {
    override suspend fun addSong(songId: String?, collectionId: String): String =
        actions.addSongToCollection(songId, collectionId).dialog
    override suspend fun setMixMode(on: Boolean): String = actions.setNowPlayingMixMode(on)
    override suspend fun setStem(stem: StemPart, muted: Boolean): String = actions.setStem(stem, muted)
    override suspend fun playPlaylist(id: String, shuffle: Boolean): String = actions.playPlaylist(id, shuffle)
    override suspend fun playPocket(id: String, shuffle: Boolean): String = actions.playPocket(id, shuffle)
    override suspend fun playPocketForNow(): String = pocketPlayingLine(actions.playPocketForNow())
    override suspend fun startAutoMix(source: MixSource, shuffle: Boolean): String {
        val r = actions.startAutoMix(source, shuffle)
        return autoMixLine(r.name, r.count, shuffle)
    }
    override suspend fun pauseAutoMix() = actions.pauseAutoMix()
    override suspend fun resumeAutoMix() = actions.resumeAutoMix()
    override suspend fun createPocket(brief: String, minutes: Int): String = actions.createPocket(brief, minutes)
}

/**
 * Turns the loose, spoken arguments Gemini passes (a song title, a collection NAME, a stem word) into the ids
 * [AppFunctionTarget] takes, using the same strict matchers as the Assistant door ([CollectionNameMatcher] -
 * never initials/subsequence - and [IntentSongMatcher]). Every function returns the sentence to say; a
 * [ShellActionException] becomes that sentence rather than a crash, so the model can relay it.
 */
class AppFunctionsAdapter(
    private val target: AppFunctionTarget,
    private val candidates: (Set<MediaCandidate.Kind>) -> List<MediaCandidate>,
    private val songRows: () -> List<IntentSongMatcher.Row>,
) {
    private val collectionKinds = setOf(MediaCandidate.Kind.Playlist, MediaCandidate.Kind.Pocket)

    private fun resolveCollection(name: String): MediaCandidate? =
        CollectionNameMatcher.rank(name, candidates(collectionKinds)) { it.name }.firstOrNull()

    private fun resolveSong(title: String, artist: String?): String? {
        val query = if (artist.isNullOrBlank()) title else "$title by $artist"
        return IntentSongMatcher.rank(query, songRows()).firstOrNull()?.id
    }

    private suspend fun guarded(body: suspend () -> String): String = try {
        body()
    } catch (e: ShellActionException) {
        e.message.orEmpty()
    }

    private fun collectionId(c: MediaCandidate) =
        (if (c.kind == MediaCandidate.Kind.Pocket) "pocket:" else "playlist:") + c.id

    suspend fun addSongToCollection(song: String, artist: String?, collection: String): String = guarded {
        val c = resolveCollection(collection) ?: throw ShellActionException.CollectionNotFound
        val id = resolveSong(song, artist) ?: throw ShellActionException.SongNotFound
        target.addSong(id, collectionId(c))
    }

    suspend fun addCurrentSongToCollection(collection: String): String = guarded {
        val c = resolveCollection(collection) ?: throw ShellActionException.CollectionNotFound
        target.addSong(null, collectionId(c))
    }

    suspend fun setMixMode(on: Boolean): String = guarded { target.setMixMode(on) }

    suspend fun setStemMuted(stem: String, muted: Boolean): String = guarded {
        val part = StemPart.parse(stem)
            ?: return@guarded "I didn't catch which part: vocals, drums, bass, or the other instruments."
        target.setStem(part, muted)
    }

    suspend fun playCollection(collection: String, shuffle: Boolean): String = guarded {
        val c = resolveCollection(collection) ?: throw ShellActionException.CollectionNotFound
        val name = if (c.kind == MediaCandidate.Kind.Pocket) target.playPocket(c.id, shuffle) else target.playPlaylist(c.id, shuffle)
        if (shuffle) "Shuffling $name." else "Playing $name."
    }

    suspend fun playPocketForNow(): String = guarded { target.playPocketForNow() }

    suspend fun startAutoMix(collection: String, shuffle: Boolean): String = guarded {
        val c = resolveCollection(collection) ?: throw ShellActionException.MixSourceNotFound
        val source = if (c.kind == MediaCandidate.Kind.Pocket) MixSource.Pocket(c.id) else MixSource.Playlist(c.id)
        target.startAutoMix(source, shuffle)
    }

    suspend fun pauseAutoMix(): String = guarded { target.pauseAutoMix(); "Auto-mix paused." }

    suspend fun resumeAutoMix(): String = guarded { target.resumeAutoMix(); "Auto-mix resumed." }

    suspend fun createPocket(brief: String, minutes: Int?): String = guarded {
        target.createPocket(brief, (minutes ?: PocketFitter.DEFAULT_MINUTES).coerceIn(MIN_MINUTES, MAX_MINUTES))
    }

    companion object {
        const val MIN_MINUTES = 10
        const val MAX_MINUTES = 600
    }
}

/**
 * PocketDJ's Gemini tools (androidx.appfunctions, API 36+; the library registers its service only there, and
 * minSdk stays 35). Each function is a one-line adapter over [AppFunctionsAdapter] -> [ShellActions]; the
 * instance is built by `PocketDjApplication.appFunctionConfiguration`. The KDoc below IS the description Gemini
 * reads (isDescribedByKDoc).
 */
class PocketDjAppFunctions(private val adapter: AppFunctionsAdapter) {

    /**
     * Adds a song from the user's PocketDJ sources to one of their pockets or playlists, found by name. If the song
     * is already in that collection nothing changes.
     *
     * @param song the song title, e.g. "Make Me Proud"
     * @param artist the artist, when the user said one
     * @param collection the name of the pocket or playlist to add it to
     * @return what to tell the user
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun addSongToCollection(appFunctionContext: AppFunctionContext, song: String, artist: String?, collection: String): String =
        adapter.addSongToCollection(song, artist, collection)

    /**
     * Adds the song that is playing right now to one of the user's pockets or playlists, found by name.
     *
     * @param collection the name of the pocket or playlist
     * @return what to tell the user
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun addCurrentSongToCollection(appFunctionContext: AppFunctionContext, collection: String): String =
        adapter.addCurrentSongToCollection(collection)

    /**
     * Turns Mix Mode (the live stem mixer on the song that is playing) on or off.
     *
     * @param on true to turn Mix Mode on, false to turn it off
     * @return what to tell the user
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun setMixMode(appFunctionContext: AppFunctionContext, on: Boolean): String = adapter.setMixMode(on)

    /**
     * Mutes one part of the song that is playing (turns Mix Mode on first if needed).
     *
     * @param stem which part: vocals, drums, bass, or other (the remaining instruments)
     * @return what to tell the user
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun muteStem(appFunctionContext: AppFunctionContext, stem: String): String = adapter.setStemMuted(stem, true)

    /**
     * Unmutes one part of the song that is playing.
     *
     * @param stem which part: vocals, drums, bass, or other (the remaining instruments)
     * @return what to tell the user
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun unmuteStem(appFunctionContext: AppFunctionContext, stem: String): String = adapter.setStemMuted(stem, false)

    /**
     * Plays one of the user's pockets or playlists, found by name.
     *
     * @param collection the name of the pocket or playlist
     * @return what to tell the user
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun playCollection(appFunctionContext: AppFunctionContext, collection: String): String =
        adapter.playCollection(collection, shuffle = false)

    /**
     * Plays one of the user's pockets or playlists in shuffled order, found by name.
     *
     * @param collection the name of the pocket or playlist
     * @return what to tell the user
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun shuffleCollection(appFunctionContext: AppFunctionContext, collection: String): String =
        adapter.playCollection(collection, shuffle = true)

    /**
     * Plays "my pocket": the pocket that fits this moment (time of day, day, the user's habits).
     *
     * @return what to tell the user
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun playMyPocket(appFunctionContext: AppFunctionContext): String = adapter.playPocketForNow()

    /**
     * Starts Auto-Mix, the DJ that beat-matches and blends songs, from one of the user's pockets or playlists, found
     * by name. Set lists are not supported here; they can only be mixed from inside the app.
     *
     * @param collection the name of the pocket or playlist to mix
     * @param shuffle true to shuffle the order
     * @return what to tell the user
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun startAutoMix(appFunctionContext: AppFunctionContext, collection: String, shuffle: Boolean?): String =
        adapter.startAutoMix(collection, shuffle ?: false)

    /**
     * Pauses the running Auto-Mix.
     *
     * @return what to tell the user
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun pauseAutoMix(appFunctionContext: AppFunctionContext): String = adapter.pauseAutoMix()

    /**
     * Resumes a paused Auto-Mix.
     *
     * @return what to tell the user
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun resumeAutoMix(appFunctionContext: AppFunctionContext): String = adapter.resumeAutoMix()

    /**
     * Creates a new pocket (a themed set of songs) from a description, like "90s chill hip hop".
     *
     * @param brief what the pocket should be: decades, genres, moods
     * @param minutes how many minutes of music, 10 to 600; defaults to 90
     * @return what to tell the user
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun createPocket(appFunctionContext: AppFunctionContext, brief: String, minutes: Int?): String =
        adapter.createPocket(brief, minutes)
}
