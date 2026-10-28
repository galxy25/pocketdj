package com.levi.pocketdj.diag

import com.levi.pocketdj.data.credentials.InMemorySecretStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagKeyFileTest {
    private fun json(
        type: String = "pocketdj-diag-key", v: String = "1", env: String = "green", account: String = "623170744161",
        id: String = "AKIAABCDEFGHIJKLMNOP", secret: String = "SUPERSECRETVALUE",
    ) = """{"type":"$type","schemaVersion":$v,"env":"$env","account":"$account","accessKeyID":"$id","secret":"$secret","exportedAt":"x"}"""

    private fun rejected(text: String) = (DiagKeyFile.decode(text) as DiagKeyFile.Decoded.Rejected).why

    @Test fun validFileDecodes() {
        val f = (DiagKeyFile.decode(json()) as DiagKeyFile.Decoded.Ok).file
        assertEquals("green", f.env); assertEquals("623170744161", f.account); assertEquals("x", f.exportedAt)
    }

    @Test fun validationMatrix() {
        assertEquals(DiagKeyFile.Invalid.NotJson, rejected("nope"))
        assertEquals(DiagKeyFile.Invalid.WrongType, rejected(json(type = "other")))
        assertEquals(DiagKeyFile.Invalid.UnsupportedVersion(2), rejected(json(v = "2")))
        assertEquals(DiagKeyFile.Invalid.Missing("env"), rejected(json(env = "  ")))
        assertEquals(DiagKeyFile.Invalid.Missing("secret"), rejected(json(secret = "")))
        assertEquals(DiagKeyFile.Invalid.BadAccessKeyId, rejected(json(id = "AKIAshort")))
        assertEquals(DiagKeyFile.Invalid.BadAccount, rejected(json(account = "12345")))
        assertTrue(DiagKeyFile.decode(json(id = "ASIAABCDEFGHIJKLMNOP")) is DiagKeyFile.Decoded.Ok)
        assertEquals(DiagKeyFile.Invalid.Missing("schemaVersion"),
            rejected("""{"type":"pocketdj-diag-key","env":"g"}"""))
    }

    @Test fun bucketAccountParsing() {
        assertEquals("623170744161", DiagKeyFile.bucketAccount("https://pocketdj-logs-623170744161.s3.us-west-2.amazonaws.com"))
        assertNull(DiagKeyFile.bucketAccount("https://example.com"))
        assertNull(DiagKeyFile.bucketAccount("not a url"))
    }

    private class Rig(logsBase: String = "https://pocketdj-logs-623170744161.s3.us-west-2.amazonaws.com") {
        val secrets = InMemorySecretStore()
        val store = DiagCredentialStore(secrets)
        val logs = mutableListOf<String>()
        var reloads = 0
        val importer = DiagKeyImporter(store, { logsBase }, { "green" }, { logs += it }, { reloads++ })
    }

    @Test fun importStoresKeyAndReloads() {
        val r = Rig()
        val o = r.importer.importText(json()) as DiagKeyImporter.Outcome.Imported
        assertEquals("AKIAABCDEFGHIJKLMNOP", o.keyId)
        assertEquals("SUPERSECRETVALUE", r.store.load()?.secret)
        assertEquals(1, r.reloads)
    }

    @Test fun accountMismatchNeedsConfirmationThenForce() {
        val r = Rig()
        val held = r.importer.importText(json(account = "111122223333"))
        assertTrue(held is DiagKeyImporter.Outcome.NeedsConfirmation)
        assertNull(r.store.load()); assertEquals(0, r.reloads)
        val forced = r.importer.importText(json(account = "111122223333"), force = true) as DiagKeyImporter.Outcome.Imported
        assertTrue(forced.mismatch != null)
        assertTrue(r.store.load() != null)
    }

    @Test fun malformedRejectedWithNamedReasonAndNoSecretLeak() {
        val r = Rig()
        val o = r.importer.importText(json(id = "bad")) as DiagKeyImporter.Outcome.Invalid
        assertEquals("key file's access key ID is malformed", o.reason)
        assertNull(r.store.load())
        assertFalse((r.logs + o.reason).any { it.contains("SUPERSECRETVALUE") })
    }

    @Test fun removeClears() {
        val r = Rig()
        r.importer.importText(json())
        r.importer.remove()
        assertNull(r.store.load())
        assertEquals(2, r.reloads)
    }
}
