package com.levi.pocketdj.assistant

import com.levi.pocketdj.shell.ShellActionException
import com.levi.pocketdj.shell.ShellRoute
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaSearchHandlerTest {
    private fun pl(id: String, name: String, played: Double? = null) =
        MediaCandidate(MediaCandidate.Kind.Playlist, id, name, played)

    private fun pk(id: String, name: String, played: Double? = null) =
        MediaCandidate(MediaCandidate.Kind.Pocket, id, name, played)

    private fun resolve(
        query: String,
        focus: MediaFocus = MediaFocus.Playlist,
        pool: List<MediaCandidate>,
        title: String? = null,
    ): MediaSearchResult = MediaSearchResolver.resolve(MediaSearchRequest(query, focus, title = title)) { kinds ->
        pool.filter { it.kind in kinds }
    }

    @Test
    fun focusMime_mapsToKinds() {
        assertEquals(MediaFocus.Playlist, MediaFocus.fromMime("vnd.android.cursor.item/playlist"))
        assertEquals(MediaFocus.Song, MediaFocus.fromMime("vnd.android.cursor.item/audio"))
        assertEquals(MediaFocus.Album, MediaFocus.fromMime("vnd.android.cursor.item/album"))
        assertEquals(MediaFocus.Artist, MediaFocus.fromMime("vnd.android.cursor.item/artist"))
        assertEquals(MediaFocus.Any, MediaFocus.fromMime("vnd.android.cursor.item/*"))
        assertEquals(MediaFocus.Any, MediaFocus.fromMime(null))
    }

    @Test
    fun from_readsExtras_andStructuredExtraBeatsRawQuery() {
        val extras = mapOf(
            MediaSearchRequest.EXTRA_QUERY to "play my warmup pocket",
            MediaSearchRequest.EXTRA_FOCUS to "vnd.android.cursor.item/playlist",
            MediaSearchRequest.EXTRA_PLAYLIST to "Warmup",
        )
        val req = MediaSearchRequest.from { extras[it] }
        assertEquals(MediaFocus.Playlist, req.focus)
        assertEquals("Warmup", req.effectiveQuery)
        assertEquals("only query", MediaSearchRequest("only query").effectiveQuery)
    }

    @Test
    fun exactBeatsNormalizedBeatsTokenCoverage() {
        val pool = listOf(
            pl("cover", "Late Night Warmup Mix"),
            pl("norm", "warm-up!"),
            pl("exact", "Warm Up"),
        )
        val r = resolve("Warm Up", pool = pool) as MediaSearchResult.Play
        assertEquals("exact", r.candidate.id)
        val r2 = resolve("warmup", pool = listOf(pl("cover", "Late Night Warmup Mix"), pl("norm", "Warmup"))) as MediaSearchResult.Play
        assertEquals("norm", r2.candidate.id)
        val r3 = resolve("night warmup", pool = listOf(pl("cover", "Late Night Warmup Mix"), pl("no", "Cooldown"))) as MediaSearchResult.Play
        assertEquals("cover", r3.candidate.id)
    }

    @Test
    fun caseAndDiacriticFolding() {
        val r = resolve("cafe del mar", pool = listOf(pk("p", "Café del Mar"))) as MediaSearchResult.Play
        assertEquals("p", r.candidate.id)
        assertEquals(MediaCandidate.Kind.Pocket, r.candidate.kind)
        val r2 = resolve("CAFÉ DEL MAR", pool = listOf(pk("p", "cafe del mar"))) as MediaSearchResult.Play
        assertEquals("p", r2.candidate.id)
    }

    @Test
    fun tie_goesToMostRecentlyPlayed() {
        val pool = listOf(pl("old", "Warmup", 100.0), pk("new", "Warmup", 900.0), pl("never", "Warmup", null))
        assertEquals("new", (resolve("warmup", pool = pool) as MediaSearchResult.Play).candidate.id)
    }

    @Test
    fun spokenFillerIsStripped_andKindHintBreaksTies() {
        val pool = listOf(pl("pl", "Warmup", 900.0), pk("pk", "Warmup", 100.0))
        val r = resolve("my warmup pocket", pool = pool) as MediaSearchResult.Play
        assertEquals("pk", r.candidate.id)
        val r2 = resolve("play the warmup playlist", pool = pool) as MediaSearchResult.Play
        assertEquals("pl", r2.candidate.id)
    }

    @Test
    fun shuffleWord_setsShuffle() {
        val r = resolve("shuffle warmup", pool = listOf(pk("pk", "Warmup"))) as MediaSearchResult.Play
        assertTrue(r.shuffle)
        assertEquals(false, (resolve("warmup", pool = listOf(pk("pk", "Warmup"))) as MediaSearchResult.Play).shuffle)
    }

    @Test
    fun noMatch_landsOnBrowseWithTheQuery() {
        val r = resolve("  something else ", pool = listOf(pk("pk", "Warmup")))
        assertEquals(MediaSearchResult.Browse("something else"), r)
        // A partial token ("warm") is NOT coverage of "warmup".
        assertEquals(MediaSearchResult.Browse("warm"), resolve("warm", pool = listOf(pk("pk", "Warmup"))))
    }

    @Test
    fun artistFocus_andBlankQuery() {
        assertEquals(
            MediaSearchResult.Browse("daft punk"),
            resolve("daft punk", focus = MediaFocus.Artist, pool = listOf(pk("pk", "Daft Punk"))),
        )
        assertEquals(MediaSearchResult.Empty, resolve("   ", pool = emptyList()))
    }

    @Test
    fun songFocus_matchesTitleExtra() {
        val song = MediaCandidate(MediaCandidate.Kind.Song, "s1", "Around the World")
        val r = resolve("play around the world by daft punk", focus = MediaFocus.Song, pool = listOf(song), title = "Around the World")
        assertEquals("s1", (r as MediaSearchResult.Play).candidate.id)
    }

    @Test
    fun songFocus_artistExtraBreaksTitleTies() {
        val other = MediaCandidate(MediaCandidate.Kind.Song, "s-other", "Hello", artist = "Lionel Richie")
        val adele = MediaCandidate(MediaCandidate.Kind.Song, "s-adele", "Hello (Remastered Deluxe)", artist = "Adele")
        val exactAdele = MediaCandidate(MediaCandidate.Kind.Song, "s-adele2", "Hello", artist = "Adele")
        val req = MediaSearchRequest("hello by adele", MediaFocus.Song, title = "Hello", artist = "Adele")
        val r = MediaSearchResolver.resolve(req) { listOf(other, adele, exactAdele) }
        assertEquals("s-adele2", (r as MediaSearchResult.Play).candidate.id)
    }

    @Test
    fun structuredPlaylist_stillHonoursShuffleAndPocketHintFromRawQuery() {
        val list = pl("l", "Warmup", 5.0)
        val pocket = pk("p", "Warmup", 1.0)
        val req = MediaSearchRequest("shuffle my warmup pocket", MediaFocus.Playlist, playlist = "warmup")
        val r = MediaSearchResolver.resolve(req) { listOf(list, pocket) } as MediaSearchResult.Play
        assertEquals("p", r.candidate.id)
        assertTrue(r.shuffle)
    }

    private class Recorder : MediaPlayActions {
        val calls = mutableListOf<String>()
        var fail: ShellActionException? = null
        private fun go(s: String): String { fail?.let { throw it }; calls += s; return s }
        override suspend fun playPlaylist(id: String, shuffle: Boolean) = go("playlist:$id:$shuffle")
        override suspend fun playPocket(id: String, shuffle: Boolean) = go("pocket:$id:$shuffle")
        override suspend fun playAlbum(id: String, shuffle: Boolean) = go("album:$id:$shuffle")
        override suspend fun playSong(id: String) = go("song:$id")
    }

    @Test
    fun handler_playsMatch_elseRoutesToBrowse_elseSpeaksTheFailure() = runTest {
        val actions = Recorder()
        val routes = mutableListOf<ShellRoute>()
        val messages = mutableListOf<String>()
        val h = MediaSearchHandler(
            actions = actions,
            candidates = { kinds -> listOf(pk("p1", "Warmup", 5.0)).filter { it.kind in kinds } },
            openRoute = { routes += it },
            message = { messages += it },
        )
        assertEquals("pocket:p1:false", h.handle(MediaSearchRequest("warmup", MediaFocus.Playlist)))
        assertNull(h.handle(MediaSearchRequest("nothing here")))
        assertEquals(listOf<ShellRoute>(ShellRoute.BrowseSearch("nothing here")), routes)
        actions.fail = ShellActionException.SetupIncomplete
        assertNull(h.handle(MediaSearchRequest("warmup")))
        assertEquals(listOf("Finish setting up PocketDJ in the app first."), messages)
    }
}
