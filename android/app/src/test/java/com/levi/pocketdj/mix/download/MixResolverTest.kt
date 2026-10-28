package com.levi.pocketdj.mix.download

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.data.collections.SetlistTrack
import com.levi.pocketdj.mix.model.MixSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MixResolverTest {
    private class Fake : MixResolverSources {
        val songs = HashMap<String, IndexSong>()
        val pockets = HashMap<String, List<String>>()
        val playlists = HashMap<String, List<String>>()
        val setlists = HashMap<String, Setlist>()
        val disk = HashSet<String>()
        override fun pocketSongIds(pocketId: String) = pockets[pocketId].orEmpty()
        override fun playlistSongIds(playlistId: String) = playlists[playlistId].orEmpty()
        override fun setlist(setlistId: String) = setlists[setlistId]
        override fun song(songId: String) = songs[songId]
        override fun isOnDisk(songId: String) = songId in disk
        val cleanSources = HashSet<MixSource>()
        override fun cleanOnly(source: MixSource) = source in cleanSources
        override fun songsById(): Map<String, IndexSong> = songs
        fun add(id: String, name: String = "N$id", onDisk: Boolean = true, bpm: Double? = 120.0, len: Long? = 200_000) {
            songs[id] = IndexSong(id = id, albumId = "alb$id", artist = "A$id", name = name, bpm = bpm,
                key = "Am", camelot = "8A", length = len)
            if (onDisk) disk += id
        }
    }

    @Test fun pocketKeepsOnlyOnDiskInOrderAndDedupes() {
        val f = Fake()
        listOf("a", "b", "c").forEach { f.add(it) }
        f.add("u", onDisk = false)
        f.pockets["p"] = listOf("a", "u", "b", "a", "missing", "c", "b")
        val out = MixResolver(f).loadables(MixSource.Pocket("p"))
        assertEquals(listOf("a", "b", "c"), out.map { it.songId })
        assertEquals("Na", out[0].title); assertEquals("Aa", out[0].artist)
        assertEquals(120.0, out[0].bpm); assertEquals("8A", out[0].camelot)
        assertEquals("alba", out[0].albumId)
        assertEquals(200_000, out[0].lengthMs)
    }

    @Test fun streamableSeamAdmitsRippedNotBurned() {
        val f = Fake()
        f.add("a"); f.add("s", onDisk = false); f.add("x", onDisk = false)
        f.playlists["pl"] = listOf("a", "s", "x")
        val r = MixResolver(f) { it == "s" }
        assertEquals(listOf("a", "s"), r.loadables(MixSource.Playlist("pl")).map { it.songId })
        r.streamable = null
        assertEquals(listOf("a"), r.loadables(MixSource.Playlist("pl")).map { it.songId })
    }

    @Test fun setlistSkipsTextBlankAndUnburnedAndDedupes() {
        val f = Fake()
        f.add("a"); f.add("b"); f.add("u", onDisk = false)
        f.setlists["s"] = Setlist(id = "s", tracks = listOf(
            SetlistTrack(songId = "a", artist = "A", name = "N"),
            SetlistTrack(isText = true, name = "cue"),
            SetlistTrack(songId = ""),
            SetlistTrack(songId = "u", artist = "x", name = "y"),
            SetlistTrack(songId = "a", artist = "dup", name = "dup"),
            SetlistTrack(songId = "b", artist = "", name = ""),
        ))
        val out = MixResolver(f).loadables(MixSource.Setlist("s"))
        assertEquals(listOf("a", "b"), out.map { it.songId })
    }

    @Test fun setlistSnapshotWinsAndCatalogFillsGaps() {
        val f = Fake()
        f.add("a", bpm = 100.0, len = 111_000); f.add("b", bpm = 99.0, len = 222_000)
        f.setlists["s"] = Setlist(id = "s", tracks = listOf(
            SetlistTrack(songId = "a", artist = "Snap", name = "SnapName", bpm = 128.0, camelot = "5B", lengthMs = 300_000),
            SetlistTrack(songId = "b"),
        ))
        val (a, b) = MixResolver(f).loadables(MixSource.Setlist("s"))
        assertEquals("SnapName", a.title); assertEquals("Snap", a.artist)
        assertEquals(128.0, a.bpm); assertEquals("5B", a.camelot); assertEquals(300_000, a.lengthMs)
        // albumId + key always come from the catalog (snapshots do not store them)
        assertEquals("alba", a.albumId); assertEquals("Am", a.key)
        // blank snapshot fields fall back to catalog
        assertEquals("Nb", b.title); assertEquals("Ab", b.artist); assertEquals(99.0, b.bpm)
        assertEquals("8A", b.camelot); assertEquals(222_000, b.lengthMs)
    }

    @Test fun unknownSetlistAndUnknownSongsResolveEmpty() {
        val f = Fake()
        f.disk += "ghost" // on disk but not in the catalog: pocket path drops it
        f.pockets["p"] = listOf("ghost")
        val r = MixResolver(f)
        assertTrue(r.loadables(MixSource.Setlist("nope")).isEmpty())
        assertTrue(r.loadables(MixSource.Pocket("p")).isEmpty())
    }

    @Test fun memberIdsAreDedupedOrderedAndIgnoreDiskState() {
        val f = Fake()
        f.add("a"); f.add("b", onDisk = false)
        f.setlists["s"] = Setlist(id = "s", tracks = listOf(
            SetlistTrack(songId = "b"), SetlistTrack(isText = true), SetlistTrack(songId = "a"), SetlistTrack(songId = "b"),
        ))
        f.pockets["p"] = listOf("a", "", "b", "a")
        val r = MixResolver(f)
        assertEquals(listOf("b", "a"), r.memberIds(MixSource.Setlist("s")))
        assertEquals(listOf("a", "b"), r.memberIds(MixSource.Pocket("p")))
    }

    @Test fun memberIdsAppliesCleanOnlyFilterForCleanCrates() {
        val f = Fake()
        val expl = "sng_0123456789ab"
        f.songs[expl] = IndexSong(id = expl, artist = "A", name = "N", explicit = true, appleMusicId = "1")
        f.songs["plain"] = IndexSong(id = "plain", artist = "A", name = "P", explicit = false)
        f.pockets["p"] = listOf(expl, "plain")
        val src = MixSource.Pocket("p")
        assertEquals(listOf(expl, "plain"), MixResolver(f).memberIds(src))
        f.cleanSources += src
        // explicit with no clean edition is dropped, never fetched
        assertEquals(listOf("plain"), MixResolver(f).memberIds(src))
    }
}
