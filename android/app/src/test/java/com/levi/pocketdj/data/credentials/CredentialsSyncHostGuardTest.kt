package com.levi.pocketdj.data.credentials

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of iOS SettingsCredentialsSyncTests (sameServerHost / keepLocalSecret, commits 1bad0e9d + dd1f190c). */
class CredentialsSyncHostGuardTest {
    private val same = CredentialsSync.Companion::sameServerHost

    @Test fun sameHost_isHostLevelAndCaseInsensitive() {
        assertTrue(same("https://a.ts.net", "https://A.ts.net:10000"))
        assertTrue(same("https://a.ts.net/rip", "http://a.ts.net"))
        assertFalse(same("https://a.ts.net", "https://b.ts.net"))
        assertFalse(same("not a url", "also not"))
        assertTrue(same("same-junk", "same-junk")) // exact-string shortcut
    }

    @Test fun sameHost_newlinesSchemelessHostPortAndTrailingDot() {
        assertTrue(same("https://a.ts.net\n", "https://a.ts.net:10000"))
        assertTrue(same("a.ts.net:10000", "https://a.ts.net"))
        assertTrue(same("https://a.ts.net.", "https://A.TS.NET:10000/"))
        assertFalse(same("a.ts.net:10000", "b.ts.net:10000"))
        assertEquals("levis-imac.tail2e2bdf.ts.net", CredentialsSync.serverHost("levis-imac.tail2e2bdf.ts.net:10000"))
        assertNull(CredentialsSync.serverHost("  "))
    }

    @Test fun serverHost_stripsUserinfoPathQueryAndHandlesIpv6() {
        assertEquals("a.ts.net", CredentialsSync.serverHost("https://user:pw@A.ts.net:8443/x?y=1#z"))
        assertEquals("[::1]", CredentialsSync.serverHost("http://[::1]:10000/rip"))
        assertNull(CredentialsSync.serverHost("https://"))
    }

    @Test fun emptyPulledSecret_forSameHostDifferentPort_keepsLocal_theFunnelPortCase() {
        // The incident: another device re-pointed the rip URL to the :10000 Funnel port with an empty token.
        assertTrue(CredentialsSync.keepLocalSecret("tok", "", "https://imac.ts.net", "https://imac.ts.net:10000"))
        assertTrue(CredentialsSync.keepLocalSecret("tok", "", "https://imac.ts.net:10000", "https://IMAC.ts.net"))
    }

    @Test fun emptyPulledSecret_forDifferentHost_adoptsWholesale() {
        assertFalse(CredentialsSync.keepLocalSecret("tok", "", "https://imac.ts.net", "https://other.ts.net"))
    }

    @Test fun keepLocalSecret_otherPreconditions() {
        assertFalse(CredentialsSync.keepLocalSecret("tok", "pulled", "https://a", "https://a")) // pulled has a secret
        assertFalse(CredentialsSync.keepLocalSecret("", "", "https://a", "https://a")) // nothing local to keep
        assertFalse(CredentialsSync.keepLocalSecret("tok", "", "https://a", "")) // cleared pair propagates
    }

    @Test fun merge_sameHostEmptySecret_neverReplacesLocalSecret_butAdoptsTheUrl() {
        val local = SettingsCredentialsDocument(ripServerURL = "https://imac.ts.net", ripToken = "secret")
        val pulled = SettingsCredentialsDocument(ripServerURL = "https://imac.ts.net:10000", ripToken = "")
        val r = CredentialsSync.merge(local, pulled)
        assertTrue(r.keptRip)
        assertEquals("secret", r.doc.ripToken)
        assertEquals("https://imac.ts.net:10000", r.doc.ripServerURL)
    }

    @Test fun merge_differentHost_adoptsEmptyToken() {
        val local = SettingsCredentialsDocument(ripServerURL = "https://imac.ts.net", ripToken = "secret")
        val pulled = SettingsCredentialsDocument(ripServerURL = "https://other.ts.net", ripToken = "")
        val r = CredentialsSync.merge(local, pulled)
        assertFalse(r.keptRip)
        assertEquals("", r.doc.ripToken)
    }

    @Test fun merge_jukeboxGuardUsesHostToo() {
        val local = SettingsCredentialsDocument(jukeboxServerURL = "https://jb.ts.net", jukeboxToken = "jt")
        val pulled = SettingsCredentialsDocument(jukeboxServerURL = "jb.ts.net:10000", jukeboxToken = "")
        val r = CredentialsSync.merge(local, pulled)
        assertTrue(r.keptJukebox)
        assertEquals("jt", r.doc.jukeboxToken)
    }

    @Test fun guardedApply_repushes_localDiffersFromPull() {
        val tmp = java.io.File.createTempFile("creds", ".json").also { it.deleteOnExit() }
        var live = SettingsCredentialsDocument(ripServerURL = "https://imac.ts.net", ripToken = "secret")
        val port = object : CredentialsPort {
            override fun read() = live
            override fun apply(doc: SettingsCredentialsDocument) { live = doc }
        }
        val sync = CredentialsSync(tmp, port)
        sync.writePulled(
            SettingsCredentialsDocument.encode(
                SettingsCredentialsDocument(ripServerURL = "https://imac.ts.net:10000", ripToken = ""),
            ),
        )
        assertTrue(sync.applyPulled()) // guarded => re-materialized (and so pushed back)
        assertEquals("secret", live.ripToken)
        assertEquals("secret", SettingsCredentialsDocument.decode(tmp.readBytes())!!.ripToken)
    }
}
