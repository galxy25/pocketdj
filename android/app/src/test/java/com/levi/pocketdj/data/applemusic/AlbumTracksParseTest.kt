package com.levi.pocketdj.data.applemusic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AlbumTracksParseTest {
    @Test fun parsesPositionMetadataAndOrdersByDiscThenTrack() {
        val body = """{"data":[
          {"id":"3","attributes":{"name":"C","artistName":"X","discNumber":2,"trackNumber":1,"durationInMillis":3000}},
          {"id":"2","attributes":{"name":"B","artistName":"X","discNumber":1,"trackNumber":2,"durationInMillis":2000}},
          {"id":"1","attributes":{"name":"A","artistName":"X","discNumber":1,"trackNumber":1}},
          {"attributes":{"name":"no id"}}]}"""
        val t = AppleMusicApiModels.parseAlbumTracks(body)!!
        assertEquals(listOf("1", "2", "3"), t.map { it.id })
        assertEquals(listOf(1, 2, 1), t.map { it.trackNumber })
        assertEquals(2, t[2].discNumber)
        assertNull(t[0].durationMs)
        assertEquals(2000, t[1].durationMs)
    }

    @Test fun undecodableBodyIsNullNotEmpty() {
        assertNull(AppleMusicApiModels.parseAlbumTracks("<html>"))
        assertEquals(emptyList<Any>(), AppleMusicApiModels.parseAlbumTracks("""{"data":[]}"""))
    }

    @Test fun musicVideosAreDropped() {
        val body = """{"data":[{"id":"1","type":"songs","attributes":{"name":"S","artistName":"A"}},
            {"id":"2","type":"music-videos","attributes":{"name":"V","artistName":"A"}}]}"""
        assertEquals(listOf("1"), AppleMusicApiModels.parseAlbumTracks(body)!!.map { it.id })
    }
}
