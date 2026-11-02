package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.data.profile.ProfileAudioStore
import com.levi.pocketdj.data.profile.ProfileSourceStore
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DemuxSaveTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun audioStore(): ProfileAudioStore {
        val d = tmp.newFolder("p")
        return ProfileAudioStore(ProfileSourceStore(File(d, ProfileSourceStore.FILE_NAME), File(d, "profile-audio")))
    }
    private fun file(name: String, body: String = name) = File(tmp.newFolder(), name).apply { writeText(body) }
    private fun stemSet(tag: String) = DemuxStore.STEM_NAMES.associateWith { file("$it.mp3", "$tag-$it") }

    @Test fun burnedStemsWinOverCache() {
        val burned = stemSet("b"); val cache = stemSet("c")
        assertEquals(burned, DemuxSave.chooseStems(burned, cache))
    }

    @Test fun cacheUsedWhenNoBurnedSet() {
        val cache = stemSet("c")
        assertEquals(cache, DemuxSave.chooseStems(null, cache))
    }

    @Test fun incompleteBurnedSetFallsToCache() {
        val burned = stemSet("b") - "bass"; val cache = stemSet("c")
        assertEquals(cache, DemuxSave.chooseStems(burned, cache))
        assertNull(DemuxSave.chooseStems(burned, null))
    }

    @Test fun durationZeroIsNull() {
        assertNull(DemuxSave.durationOrNull(0)); assertNull(DemuxSave.durationOrNull(-5))
        assertEquals(1234L, DemuxSave.durationOrNull(1234))
    }

    @Test fun saveWithStemsIngestsOriginalAndStemsAsDemuxKind() = runBlocking {
        val store = audioStore()
        val orig = file("song.mp3", "ORIGINAL-BYTES")
        val id = DemuxSave.save(orig, "Artist — Song", 60_000, stemSet("b"), null, 120.0, "A minor", "8A", store)
        assertNotNull(id); assertTrue(ProfileSourceStore.isProfileSongId(id!!))
        val e = store.originalFor(id)
        assertEquals("ORIGINAL-BYTES", e!!.readText())
        assertEquals(setOf("vocals", "drums", "bass", "other"), store.stemFiles(id)!!.keys)
        assertEquals("b-bass", store.stemFiles(id)!!["bass"]!!.readText())
    }

    @Test fun saveWithoutStemsStillSavesOriginal() = runBlocking {
        val store = audioStore()
        val id = DemuxSave.save(file("a.m4a"), "T", 0, null, null, null, null, null, store)!!
        assertNotNull(store.originalFor(id)); assertNull(store.stemFiles(id))
    }

    /** Q117 + Q116: a saved mp3 demux is a Mix-eligible "Pocket DJ" row with its four stems; a non-mp3 one plays in Now Playing only. */
    @Test fun savedMp3DemuxIsMixEligibleWithItsStemsAndNonMp3StaysOffTheDecks() = runBlocking {
        val store = audioStore()
        val none = object : com.levi.pocketdj.mix.engine.MixTrackResolver { override fun resolve(songId: String) = null }
        val mix = com.levi.pocketdj.data.profile.ProfileMixTrackResolver(store, none)
        val id = DemuxSave.save(file("song.mp3"), "Song", 60_000, null, stemSet("c"), null, null, null, store)!!
        assertTrue(mix.exists(id))
        assertEquals("mp3", mix.resolve(id)!!.file.extension)
        assertEquals(DemuxStore.STEM_NAMES.toSet(), store.stemFiles(id)!!.keys)
        val m4a = DemuxSave.save(file("song.m4a"), "Song", 60_000, null, stemSet("d"), null, null, null, store)!!
        assertNotNull("still a playable profile row", store.originalFor(m4a))
        assertTrue(!mix.exists(m4a)); assertNull(mix.resolve(m4a))
    }

    @Test fun missingAudioSavesNothing() = runBlocking {
        val store = audioStore()
        assertNull(DemuxSave.save(null, "T", 1, null, null, null, null, null, store))
        assertNull(DemuxSave.save(File(tmp.root, "gone.mp3"), "T", 1, null, null, null, null, null, store))
        assertTrue(store.usageBytes() == 0L)
    }
}
