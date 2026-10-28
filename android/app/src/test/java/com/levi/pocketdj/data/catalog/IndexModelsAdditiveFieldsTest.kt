package com.levi.pocketdj.data.catalog

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.edition.SongVariant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class IndexModelsAdditiveFieldsTest {
    private fun decode(s: String) = PdjJson.lenient.decodeFromString<IndexJson>(s)

    @Test fun legacyDoc_newFieldsNull() {
        val i = decode("""{"songs":[{"id":"s","artist":"a","name":"n"}],"albums":[{"id":"a","artist":"a","name":"n"}]}""")
        val s = i.songs[0]
        assertNull(s.dateAdded); assertNull(s.appleMusicIdExplicit); assertNull(s.spotifyUrl)
        assertNull(i.albums[0].youtubeUrl); assertNull(i.artists)
    }

    @Test fun newFieldsDecode() {
        val i = decode("""{"songs":[{"id":"s","artist":"a","name":"n","explicit":true,"appleMusicId":"1",
          "appleMusicIdExplicit":"1","appleMusicIdClean":"2","dateAdded":1700000000000,
          "appleMusicUrl":"u","spotifyUrl":"sp","youtubeUrl":null}],
          "albums":[{"id":"a","artist":"a","name":"n","appleMusicUrl":"au"}]}""")
        val s = i.songs[0]
        assertEquals(1.7e12, s.dateAdded!!, 0.0)
        assertEquals("2", s.appleMusicId(SongVariant.CLEAN)); assertEquals("1", s.appleMusicId(SongVariant.EXPLICIT))
        assertEquals("sp", s.spotifyUrl); assertNull(s.youtubeUrl); assertEquals("au", i.albums[0].appleMusicUrl)
    }

    @Test fun appleMusicIdFor_fallsBackToPrimaryByExplicitness() {
        val e = IndexSong(id = "s", artist = "a", name = "n", explicit = true, appleMusicId = "9")
        assertEquals("9", e.appleMusicId(SongVariant.EXPLICIT)); assertNull(e.appleMusicId(SongVariant.CLEAN))
        val c = e.copy(explicit = false)
        assertEquals("9", c.appleMusicId(SongVariant.CLEAN)); assertNull(c.appleMusicId(SongVariant.EXPLICIT))
    }

    @Test fun artistsTable_lenient() {
        val i = decode("""{"artists":[{"key":"the band","name":"The Band","id":123,"songs":4,"alt":[5,6]},{"key":"x"},{"name":"y","id":null,"extra":1}]}""")
        val a = i.artists!!
        assertEquals(3, a.size); assertEquals(123L, a[0].id); assertEquals(listOf(5L, 6L), a[0].alt)
        assertNull(a[1].id); assertEquals("", a[2].key)
    }

    @Test fun normalize_collapsesWhitespace() {
        assertEquals("the big band", IndexArtist.normalize("  The   BIG\tBand "))
    }
}
