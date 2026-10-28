package com.levi.pocketdj.screens.collections

import com.levi.pocketdj.data.backup.BackupPayload
import com.levi.pocketdj.data.backup.BackupZip
import com.levi.pocketdj.data.backup.BackupZipException
import com.levi.pocketdj.data.backup.CollectionShare
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.collections.io.CollectionFile
import com.levi.pocketdj.data.collections.io.ImportKind
import com.levi.pocketdj.data.collections.io.ImportSummary
import com.levi.pocketdj.data.collections.io.PlaylistZip
import com.levi.pocketdj.data.collections.io.PocketZip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CollectionExportImportTest {
    @Test fun exportFilenameExplicitExtension() {
        assertEquals("Warm Up.pocket.pdjcollection", CollectionShare.exportFilename(CollectionShare.Kind.POCKET, "Warm Up"))
        assertEquals("Set 1.playlist.pdjcollection", CollectionShare.exportFilename(CollectionShare.Kind.PLAYLIST, "Set 1"))
        // path separators / reserved characters can never escape the picker's directory or truncate the tail
        val nasty = CollectionShare.exportFilename(CollectionShare.Kind.PLAYLIST, "a/b\\c:d*e?\"f<g>h|i")
        assertTrue(nasty, nasty.endsWith(".playlist.pdjcollection"))
        assertFalse(nasty.dropLast(".playlist.pdjcollection".length).contains(Regex("[/\\\\:*?\"<>|]")))
        assertEquals("Untitled.pocket.pdjcollection", CollectionShare.exportFilename(CollectionShare.Kind.POCKET, " ../ "))
        assertEquals("Mix.csv", CollectionShare.exportFilename(CollectionShare.Kind.CSV, "Mix"))
        assertEquals("application/zip", CollectionShare.ZIP_MIME)
        assertEquals("PocketDJ-Backup-2026-10-28.pocketdj.zip", CollectionShare.backupFilename("2026-10-28"))
    }

    @Test fun contentRouting() {
        val pocket = Pocket(id = "p1", name = "P", songIds = listOf("s1"), createdAt = 1.0, updatedAt = 1.0)
        val playlist = Playlist(id = "pl1", name = "PL", sequences = emptyList(), createdAt = 1.0, updatedAt = 1.0)
        assertEquals(ImportKind.POCKET, CollectionFile.detectKind(PocketZip.export(pocket, mapOf("p1" to pocket))))
        assertEquals(ImportKind.PLAYLIST, CollectionFile.detectKind(PlaylistZip.export(playlist, mapOf("p1" to pocket))))
        assertEquals(ImportKind.BACKUP, CollectionFile.detectKind(BackupZip.export(BackupPayload())))
        assertEquals(ImportKind.COLLECTIONS_JSON, CollectionFile.detectKind(CollectionFile.pocketEnvelope(pocket)))
        // routing is by CONTENT: the file name never matters (detectKind takes bytes only)
    }

    @Test fun summaryMessages() {
        assertEquals(
            "Imported 1 playlist, 2 pockets",
            CollectionShare.summaryMessage(ImportSummary(ImportKind.PLAYLIST, pockets = 2, playlists = 1, added = 3)),
        )
        assertEquals(
            "Already up to date - nothing new to import",
            CollectionShare.summaryMessage(ImportSummary(ImportKind.POCKET, pockets = 1, unchanged = 1)),
        )
        assertTrue(CollectionShare.summaryMessage(ImportSummary(ImportKind.BACKUP, playlists = 1, added = 1)).startsWith("Restored"))
        assertEquals("That isn't a PocketDJ file", CollectionShare.failureMessage(BackupZipException(true, "x")))
    }

    @Test fun boundedReadRejectsOversize() {
        val big = ByteArray(2048)
        assertEquals(2048, CollectionShare.readBounded(big.inputStream(), 4096).size)
        val r = runCatching { CollectionShare.readBounded(big.inputStream(), 1024) }
        assertTrue(r.isFailure)
    }

    @Test fun restoreMessageCountsSourcesAndFavorites() {
        val none = ImportSummary(ImportKind.BACKUP, unchanged = 2)
        assertEquals("Restored 2 sources, 40 favorites", CollectionShare.restoreMessage(none, 2, 40))
        assertEquals("Already up to date - nothing new to import", CollectionShare.restoreMessage(none, 0, 0))
        assertEquals(
            "Restored 1 playlist, 1 source (3 catalog items not bundled)",
            CollectionShare.restoreMessage(ImportSummary(ImportKind.BACKUP, playlists = 1, added = 1), 1, 0, 3),
        )
    }

    @Test fun foreignFilesAreNotPocketDj() {
        assertEquals(
            "That isn't a PocketDJ file",
            CollectionShare.summaryMessage(ImportSummary(ImportKind.COLLECTIONS_JSON)),
        )
        assertEquals(
            "That isn't a PocketDJ file",
            CollectionShare.failureMessage(kotlinx.serialization.SerializationException("Unexpected JSON token at offset 0")),
        )
        assertEquals("That isn't a PocketDJ file", CollectionShare.failureMessage(IllegalArgumentException("x")))
    }

    @Test fun lostExportBytesDeleteTheCreatedDocument() {
        var deleted = 0
        var written: ByteArray? = null
        val msg = completeExport("W.pocket.pdjcollection", null, { written = it; true }, { deleted++ })
        assertEquals(1, deleted); assertEquals(null, written)
        assertEquals("Export was interrupted - please try again", msg)
        // failed write also cleans up; success does not
        assertEquals("Couldn't write the file", completeExport("a", byteArrayOf(1), { false }, { deleted++ }))
        assertEquals(2, deleted)
        assertEquals("Exported a", completeExport("a", byteArrayOf(1), { true }, { deleted++ }))
        assertEquals(2, deleted)
    }
}
