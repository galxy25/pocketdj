package com.levi.pocketdj.data.credentials

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Q10: the search key pair + endpoint are device-local on Android; the iOS wire shape still carries them. */
class SettingsCredentialsDocumentTest {
    private fun keys(doc: SettingsCredentialsDocument) =
        Json.parseToJsonElement(SettingsCredentialsDocument.encode(doc).toString(Charsets.UTF_8)).jsonObject.keys

    @Test fun dataClass_hasNoSearchFields() {
        val members = SettingsCredentialsDocument::class.java.declaredFields.map { it.name }
        assertTrue(members.none { it.startsWith("search") })
        assertEquals(listOf("passThroughSearch"), members.filter { it.contains("earch") })
    }

    @Test fun androidOriginDoc_emitsEmptySearchStrings_soIosCanStillDecode() {
        val text = SettingsCredentialsDocument.encode(SettingsCredentialsDocument(ripServerURL = "https://r", ripToken = "t")).toString(Charsets.UTF_8)
        val o = Json.parseToJsonElement(text).jsonObject
        for (k in SettingsCredentialsDocument.SEARCH_KEYS) assertEquals("", o.getValue(k).toString().trim('"'))
        assertFalse(text.contains("passThroughSearch"))
    }

    @Test fun iosDoc_searchValuesRoundTripVerbatim_butAreNotLiveFields() {
        val ios = """{"schemaVersion":1,"ripServerURL":"u","ripToken":"t","jukeboxServerURL":"","jukeboxToken":"",
            "jukeboxTokensRequiredByDefault":true,"searchAccessKeyID":"AKIAX","searchSecretKey":"shh","searchEndpoint":"https://os"}"""
        val d = SettingsCredentialsDocument.decode(ios.toByteArray())!!
        val out = Json.parseToJsonElement(SettingsCredentialsDocument.encode(d).toString(Charsets.UTF_8)).jsonObject
        assertEquals("\"AKIAX\"", out.getValue("searchAccessKeyID").toString())
        assertEquals("\"shh\"", out.getValue("searchSecretKey").toString())
        assertEquals("\"https://os\"", out.getValue("searchEndpoint").toString())
        // a doc with only search content still counts as blank credentials (nothing synced)
        assertTrue(SettingsCredentialsDocument(passThroughSearch = d.passThroughSearch).credentialsAreBlank)
    }

    @Test fun normalized_dropsPassThrough_soSearchChurnNeverTriggersAPush() {
        val a = SettingsCredentialsDocument(ripToken = "t")
        val b = a.copy(passThroughSearch = Json.parseToJsonElement("""{"searchEndpoint":"x"}""").jsonObject)
        assertEquals(a.normalized(), b.normalized())
        assertTrue(keys(a).containsAll(SettingsCredentialsDocument.SEARCH_KEYS))
    }
}
