package com.levi.pocketdj.data.credentials

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class CredentialsSyncTest {
    @get:Rule val tmp = TemporaryFolder()

    private class FakePort(var live: SettingsCredentialsDocument = SettingsCredentialsDocument()) : CredentialsPort {
        var applied = 0
        override fun read() = live
        override fun apply(doc: SettingsCredentialsDocument) { live = doc; applied++ }
    }

    private fun file() = File(tmp.root, "creds.json")
    private fun doc(url: String = "https://rip", tok: String = "t") =
        SettingsCredentialsDocument(ripServerURL = url, ripToken = tok)

    @Test fun blankInstall_neverMaterializesDoc() {
        val sync = CredentialsSync(file(), FakePort())
        assertFalse(sync.syncIfChanged())
        assertFalse(file().exists())
    }

    @Test fun configuredInstall_materializes_thenIsIdempotent() {
        val sync = CredentialsSync(file(), FakePort(doc()))
        assertTrue(sync.syncIfChanged())
        val mtime = file().lastModified()
        val bytes = file().readBytes()
        assertFalse(sync.syncIfChanged())
        assertEquals(mtime, file().lastModified())
        assertTrue(bytes.contentEquals(file().readBytes()))
    }

    @Test fun onceFileExists_blankEditIsPushed() {
        val port = FakePort(doc())
        val sync = CredentialsSync(file(), port)
        sync.syncIfChanged()
        port.live = SettingsCredentialsDocument() // user cleared everything deliberately
        assertTrue(sync.syncIfChanged())
        assertEquals("", SettingsCredentialsDocument.decode(file().readBytes())!!.ripToken)
    }

    @Test fun afterResetSuspend_noBlankDocIsEverWritten() {
        val port = FakePort(doc())
        val sync = CredentialsSync(file(), port)
        sync.syncIfChanged()
        file().delete()                      // reset deletes the mirror ...
        sync.suspendUntilRelaunch()
        port.live = doc(tok = "")            // ... then the secrets wipe fires the watcher
        assertFalse(sync.syncIfChanged())
        port.live = SettingsCredentialsDocument()
        assertFalse(sync.syncIfChanged())
        assertFalse(file().exists())
    }

    @Test fun encode_isSortedKeys_dropsNulls_andIosShaped() {
        val text = SettingsCredentialsDocument.encode(doc()).toString(Charsets.UTF_8)
        assertEquals(
            """{"jukeboxServerURL":"","jukeboxToken":"","jukeboxTokensRequiredByDefault":true,"ripServerURL":"https://rip",""" +
                """"ripToken":"t","schemaVersion":1,"searchAccessKeyID":"","searchEndpoint":"","searchSecretKey":""}""",
            text,
        )
        assertFalse(text.contains("sources"))
        assertFalse(text.contains("appleMusicPrivateSync"))
    }

    @Test fun decode_acceptsIosDocWithSourcesAndUnknownKeys() {
        val ios = """{"schemaVersion":1,"ripServerURL":"u","ripToken":"t","jukeboxServerURL":"","jukeboxToken":"",
            "jukeboxTokensRequiredByDefault":false,"searchAccessKeyID":"a","searchSecretKey":"s","searchEndpoint":"e",
            "appleMusicPrivateSync":true,"future":1,
            "sources":[{"id":"9B2E0F5A-0000-0000-0000-000000000001","name":"My Vinyl","urlString":"https://x","enabled":true}]}"""
        val d = SettingsCredentialsDocument.decode(ios.toByteArray())!!
        assertEquals("t", d.ripToken)
        assertEquals(false, d.jukeboxTokensRequiredByDefault)
        assertEquals("true", d.appleMusicPrivateSync.toString())
        assertTrue(d.sources.toString().contains("My Vinyl"))
        assertNull(SettingsCredentialsDocument.decode("not json".toByteArray()))
    }

    @Test fun pulledEmptySecret_sameUrl_neverWipesLocal_andHealsFile() {
        val port = FakePort(doc(tok = "keep-me"))
        val sync = CredentialsSync(file(), port)
        // a pull lands: same URL, empty token (the 2026-09-12 incident shape)
        file().writeBytes(SettingsCredentialsDocument.encode(doc(tok = "")))
        assertTrue(sync.applyPulled()) // re-saved => pushes back, healing the fleet
        assertEquals("keep-me", port.live.ripToken)
        assertEquals("keep-me", SettingsCredentialsDocument.decode(file().readBytes())!!.ripToken)
    }

    @Test fun pulledEmptySecret_differentUrl_adoptsWholesale() {
        val port = FakePort(doc("https://old", "keep"))
        val sync = CredentialsSync(file(), port)
        file().writeBytes(SettingsCredentialsDocument.encode(doc("https://new", "")))
        assertFalse(sync.applyPulled()) // adopted exactly: file already equals live
        assertEquals("https://new", port.live.ripServerURL)
        assertEquals("", port.live.ripToken)
    }

    @Test fun pulledEmptySecret_clearedUrl_clearsPair() {
        val port = FakePort(doc("https://old", "keep"))
        val r = CredentialsSync.merge(port.live, doc("", ""))
        assertFalse(r.keptRip)
        assertEquals("", r.doc.ripToken)
    }

    @Test fun pulledNonEmptySecret_overwritesLocal() {
        val r = CredentialsSync.merge(doc("https://rip", "old"), doc("https://rip", "new"))
        assertEquals("new", r.doc.ripToken)
        assertFalse(r.keptRip)
    }

    @Test fun jukeboxToken_guardedIndependently() {
        val local = SettingsCredentialsDocument(jukeboxServerURL = "https://jb", jukeboxToken = "jt", ripServerURL = "r", ripToken = "x")
        val pulled = SettingsCredentialsDocument(jukeboxServerURL = "https://jb", jukeboxToken = "", ripServerURL = "r", ripToken = "y")
        val r = CredentialsSync.merge(local, pulled)
        assertEquals("jt", r.doc.jukeboxToken)
        assertEquals("y", r.doc.ripToken)
        assertTrue(r.keptJukebox)
    }

    @Test fun searchFields_areNeverAdoptedFromAPull_andNeverTouchLiveSettings() {
        val port = FakePort(doc("https://rip", "t"))
        val ios = """{"schemaVersion":1,"ripServerURL":"https://rip","ripToken":"t","jukeboxServerURL":"","jukeboxToken":"",
            "jukeboxTokensRequiredByDefault":true,"searchAccessKeyID":"AKIA","searchSecretKey":"sek","searchEndpoint":"https://s"}"""
        file().writeText(ios)
        CredentialsSync(file(), port).applyPulled()
        // the live (port) doc has no search members at all; nothing about them reaches applyDoc
        assertFalse(port.live.toString().contains("AKIA"))
        assertFalse(port.live.toString().contains("sek"))
    }

    @Test fun iosSearchKeys_surviveAnAndroidRewrite_soIosKeepsItsConfig() {
        val port = FakePort(doc("https://rip", "t2")) // differs from the file: forces a re-materialize
        val ios = """{"schemaVersion":1,"ripServerURL":"https://rip","ripToken":"t","jukeboxServerURL":"","jukeboxToken":"",
            "jukeboxTokensRequiredByDefault":true,"searchAccessKeyID":"AKIA","searchSecretKey":"sek","searchEndpoint":"https://s"}"""
        file().writeText(ios)
        assertTrue(CredentialsSync(file(), port).syncIfChanged())
        val out = file().readText()
        assertTrue(out.contains("\"searchAccessKeyID\":\"AKIA\""))
        assertTrue(out.contains("\"searchSecretKey\":\"sek\""))
        assertTrue(out.contains("\"searchEndpoint\":\"https://s\""))
        assertTrue(out.contains("\"ripToken\":\"t2\""))
    }

    @Test fun cleanPull_roundTripsByteIdentical_noPushBack() {
        val port = FakePort(SettingsCredentialsDocument())
        val sync = CredentialsSync(file(), port)
        val pulled = doc("https://rip", "tok")
        file().writeBytes(SettingsCredentialsDocument.encode(pulled))
        val mtime = file().lastModified()
        assertFalse(sync.applyPulled())
        assertEquals(pulled, port.live)
        assertEquals(mtime, file().lastModified())
        assertNotNull(port.live)
    }

    @Test fun undecodablePull_changesNothing() {
        val port = FakePort(doc())
        file().writeText("garbage")
        assertFalse(CredentialsSync(file(), port).applyPulled())
        assertEquals(0, port.applied)
    }

    // A real Swift JSONEncoder(.sortedKeys) doc: escaped slashes, untrimmed value, sources + unknown source field.
    private val iosDoc = """{"appleMusicPrivateSync":true,"jukeboxServerURL":"https:\/\/host\/jb","jukeboxToken":"j",""" +
        """"jukeboxTokensRequiredByDefault":true,"ripServerURL":"https:\/\/host\/rip ","ripToken":"t","schemaVersion":1,""" +
        """"searchAccessKeyID":"","searchEndpoint":"","searchSecretKey":"",""" +
        """"sources":[{"enabled":true,"future":"x","id":"9B2E0F5A-0000-0000-0000-000000000001","name":"V","urlString":"https:\/\/x"}]}"""

    @Test fun iosEncodedDoc_cleanPull_doesNotResave() {
        val port = FakePort(SettingsCredentialsDocument(
            ripServerURL = "https://host/rip", ripToken = "t", jukeboxServerURL = "https://host/jb", jukeboxToken = "j"))
        file().writeText(iosDoc)
        val mtime = file().lastModified()
        assertFalse(CredentialsSync(file(), port).applyPulled())
        assertEquals(iosDoc, file().readText())
        assertEquals(mtime, file().lastModified())
    }

    @Test fun pulledSources_surviveAndroidResave() {
        val port = FakePort(doc("https://old", "t"))
        val sync = CredentialsSync(file(), port)
        file().writeText(iosDoc.replace("\"t\",\"schemaVersion", "\"\",\"schemaVersion")) // empty rip token, differing URL => adopt, rewrite
        sync.applyPulled()
        port.live = port.live.copy(jukeboxToken = "changed")
        assertTrue(sync.syncIfChanged())
        val out = SettingsCredentialsDocument.decode(file().readBytes())!!
        assertEquals("changed", out.jukeboxToken)
        assertTrue(out.sources.toString().contains("\"future\":\"x\""))
        assertEquals("true", out.appleMusicPrivateSync.toString())
    }

    @Test fun watcherDuringPullGap_doesNotOverwritePulledBytes() {
        val port = FakePort(doc("https://local", "L"))
        val sync = CredentialsSync(file(), port)
        sync.syncIfChanged()
        val pulled = SettingsCredentialsDocument.encode(doc("https://cloud", "C"))
        sync.writePulled(pulled)
        assertFalse(sync.syncIfChanged()) // watcher fires between write and apply
        assertTrue(pulled.contentEquals(file().readBytes()))
        sync.applyPulled()
        assertEquals("C", port.live.ripToken)
    }

    @Test fun neverMirrorsWhileTheSecretStoreIsUnavailable() {
        val f = file()
        val sync = CredentialsSync(f, FakePort(doc()), secretsAvailable = { false })
        assertFalse(sync.syncIfChanged())
        assertFalse(f.exists())
    }
}
