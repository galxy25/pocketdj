package com.levi.pocketdj.assistant

import com.levi.pocketdj.shell.MixSource
import com.levi.pocketdj.shell.ShellActionException
import com.levi.pocketdj.shell.StemPart
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class PocketDjAppFunctionsTest {
    private class Rec : AppFunctionTarget {
        val calls = mutableListOf<String>()
        var fail: ShellActionException? = null
        private fun <T> rec(c: String, r: T): T { calls += c; fail?.let { throw it }; return r }
        override suspend fun addSong(songId: String?, collectionId: String) = rec("add($songId,$collectionId)", "Added.")
        override suspend fun setMixMode(on: Boolean) = rec("mixMode($on)", "Mix Mode is $on.")
        override suspend fun setStem(stem: StemPart, muted: Boolean) = rec("stem(${stem.stemName},$muted)", "ok")
        override suspend fun playPlaylist(id: String, shuffle: Boolean) = rec("playlist($id,$shuffle)", "Workout")
        override suspend fun playPocket(id: String, shuffle: Boolean) = rec("pocket($id,$shuffle)", "Chill")
        override suspend fun playPocketForNow() = rec("now", "Playing your pocket: Morning.")
        override suspend fun startAutoMix(source: MixSource, shuffle: Boolean) = rec("mix($source,$shuffle)", "Auto-mixing.")
        override suspend fun pauseAutoMix() = rec("pause", Unit)
        override suspend fun resumeAutoMix() = rec("resume", Unit)
        override suspend fun createPocket(brief: String, minutes: Int) = rec("create($brief,$minutes)", "Building.")
    }

    private val cands = listOf(
        MediaCandidate(MediaCandidate.Kind.Playlist, "p1", "Workout"),
        MediaCandidate(MediaCandidate.Kind.Pocket, "k1", "Chill Vibes"),
        MediaCandidate(MediaCandidate.Kind.Pocket, "k2", "Rainy Afternoon Pop"),
    )
    private val songs = listOf(
        IntentSongMatcher.Row("s1", "Make Me Proud", "Drake"),
        IntentSongMatcher.Row("s2", "Hotline Bling", "Drake"),
    )
    private val rec = Rec()
    private val a = AppFunctionsAdapter(rec, { kinds -> cands.filter { it.kind in kinds } }, { songs })
    private fun run(b: suspend () -> String) = runBlocking { b() }

    @Test fun addSong_resolvesSongAndPocketByName() {
        run { a.addSongToCollection("make me proud", "Drake", "my Chill Vibes pocket") }
        assertEquals(listOf("add(s1,pocket:k1)"), rec.calls)
    }

    @Test fun addSong_playlistGetsPlaylistPrefix() {
        run { a.addSongToCollection("Hotline Bling", null, "Workout") }
        assertEquals(listOf("add(s2,playlist:p1)"), rec.calls)
    }

    @Test fun addCurrentSong_passesNullSongId() {
        run { a.addCurrentSongToCollection("Workout") }
        assertEquals(listOf("add(null,playlist:p1)"), rec.calls)
    }

    @Test fun unknownCollection_isSpokenNotCalled_andNeverInitials() {
        val said = run { a.addCurrentSongToCollection("RAP") } // "Rainy Afternoon Pop" initials must not match
        assertEquals(ShellActionException.CollectionNotFound.message, said)
        assertEquals(emptyList<String>(), rec.calls)
    }

    @Test fun unknownSong_isSpoken() {
        val said = run { a.addSongToCollection("zzzzqqq nothing", null, "Workout") }
        assertEquals(ShellActionException.SongNotFound.message, said)
        assertEquals(emptyList<String>(), rec.calls)
    }

    @Test fun mixModeAndStems() {
        run { a.setMixMode(true) }
        run { a.setStemMuted("the vocals", true) }
        run { a.setStemMuted("bassline", false) }
        assertEquals(listOf("mixMode(true)", "stem(vocals,true)", "stem(bass,false)"), rec.calls)
    }

    @Test fun unknownStem_isSpoken() {
        val said = run { a.setStemMuted("kazoo", true) }
        assertEquals(true, said.startsWith("I didn't catch which part"))
        assertEquals(emptyList<String>(), rec.calls)
    }

    @Test fun playAndShuffle_routeByKind() {
        assertEquals("Playing Chill.", run { a.playCollection("Chill Vibes", false) })
        assertEquals("Shuffling Workout.", run { a.playCollection("workout playlist", true) })
        assertEquals(listOf("pocket(k1,false)", "playlist(p1,true)"), rec.calls)
    }

    @Test fun playMyPocket_and_autoMixLifecycle() {
        run { a.playPocketForNow() }
        run { a.startAutoMix("Chill Vibes", true) }
        run { a.startAutoMix("Workout", false) }
        assertEquals("Auto-mix paused.", run { a.pauseAutoMix() })
        assertEquals("Auto-mix resumed.", run { a.resumeAutoMix() })
        assertEquals(
            listOf("now", "mix(Pocket(id=k1),true)", "mix(Playlist(id=p1),false)", "pause", "resume"),
            rec.calls,
        )
    }

    @Test fun autoMixUnknownSource_saysMixSourceNotFound() {
        assertEquals(ShellActionException.MixSourceNotFound.message, run { a.startAutoMix("Nope Nope", false) })
    }

    @Test fun createPocket_defaultsAndClampsMinutes() {
        run { a.createPocket("90s chill hip hop", null) }
        run { a.createPocket("x", 3) }
        run { a.createPocket("y", 5000) }
        assertEquals(listOf("create(90s chill hip hop,90)", "create(x,10)", "create(y,600)"), rec.calls)
    }

    @Test fun shellActionFailure_becomesTheSpokenLine() {
        rec.fail = ShellActionException.NoAutoMixRunning
        assertEquals("There's no auto-mix running.", run { a.pauseAutoMix() })
    }
}
