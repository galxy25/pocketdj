package com.levi.pocketdj.data.jukebox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class JukeboxLinkTest {
    private val base = "https://jukebox.pocket-dj.com"

    private fun ok(url: String, id: String, guestBase: String?) =
        assertEquals(url, JukeboxLink(id, guestBase), JukeboxLink.parse(url))

    @Test fun customSchemeHostForm() = ok("pocketdj://jukebox/exmkrd5a", "exmkrd5a", null)
    @Test fun customSchemeTripleSlash() = ok("pocketdj:///jukebox/exmkrd5a", "exmkrd5a", null)
    @Test fun customSchemeCaseInsensitiveVerbAndScheme() = ok("POCKETDJ://JUKEBOX/exmkrd5a", "exmkrd5a", null)
    @Test fun customSchemeTrailingSlash() = ok("pocketdj://jukebox/exmkrd5a/", "exmkrd5a", null)
    @Test fun universalLink() = ok("$base/exmkrd5a/", "exmkrd5a", base)
    @Test fun universalLinkNoTrailingSlash() = ok("$base/exmkrd5a", "exmkrd5a", base)
    @Test fun universalLinkTrailingStateJson() = ok("$base/exmkrd5a/state.json", "exmkrd5a", base)
    @Test fun httpUniversalNormalisesToHttps() = ok("http://jukebox.pocket-dj.com/exmkrd5a/", "exmkrd5a", base)
    @Test fun universalHostCaseInsensitive() = ok("https://JUKEBOX.pocket-dj.com/exmkrd5a/", "exmkrd5a", base)
    @Test fun maxLengthIdAccepted() = ok("pocketdj://jukebox/${"a".repeat(32)}", "a".repeat(32), null)
    @Test fun queryIgnored() = ok("$base/exmkrd5a/?utm=x", "exmkrd5a", base)

    @Test fun uppercaseIdRejected() {
        assertNull(JukeboxLink.parse("pocketdj://jukebox/EXMKRD5A"))
        assertNull(JukeboxLink.parse("$base/Exmkrd5a/"))
    }
    @Test fun shortIdRejected() = assertNull(JukeboxLink.parse("pocketdj://jukebox/abc"))
    @Test fun tooLongIdRejected() = assertNull(JukeboxLink.parse("pocketdj://jukebox/${"a".repeat(33)}"))
    @Test fun digitsOutsideBase32Rejected() {
        assertNull(JukeboxLink.parse("pocketdj://jukebox/abcd0189"))
        assertNull(JukeboxLink.parse("pocketdj://jukebox/abcd-efg"))
    }
    @Test fun foreignHostRejected() {
        assertNull(JukeboxLink.parse("https://example.com/exmkrd5a/"))
        assertNull(JukeboxLink.parse("https://evil.jukebox.pocket-dj.com.example/exmkrd5a/"))
    }
    @Test fun otherVerbOrSchemeRejected() {
        assertNull(JukeboxLink.parse("pocketdj://mwf/exmkrd5a"))
        assertNull(JukeboxLink.parse("musicsdk://callback?code=1"))
        assertNull(JukeboxLink.parse("ftp://jukebox.pocket-dj.com/exmkrd5a/"))
        assertNull(JukeboxLink.parse("pocketdj://jukebox"))
        assertNull(JukeboxLink.parse("not a url"))
        assertNull(JukeboxLink.parse(""))
    }
    @Test fun hostOnlyUniversalRejected() = assertNull(JukeboxLink.parse("$base/"))

    @Test fun stateUrlUsesGuestBase() =
        assertEquals("$base/exmkrd5a/state.json", JukeboxLink("exmkrd5a", base).stateUrl)

    @Test fun stateUrlFallsBackToCanonicalHostForSchemeLinks() =
        assertEquals("https://jukebox.pocket-dj.com/exmkrd5a/state.json", JukeboxLink.parse("pocketdj://jukebox/exmkrd5a")!!.stateUrl)

    @Test fun stateUrlTrimsBaseSlash() =
        assertEquals("https://x.test/abcd/state.json", JukeboxLink("abcd", "https://x.test/").stateUrl)

    @Test fun parseLooseAcceptsBareIdAndLinks() {
        assertEquals(JukeboxLink("exmkrd5a", null), JukeboxLink.parseLoose("  exmkrd5a "))
        assertEquals(JukeboxLink("exmkrd5a", base), JukeboxLink.parseLoose("$base/exmkrd5a/"))
        assertNull(JukeboxLink.parseLoose("EXMKRD5A"))
    }

    @Test fun forEntryRebuildsAndValidates() {
        assertEquals(JukeboxLink("exmkrd5a", base), JukeboxLink.forEntry("exmkrd5a", "$base/"))
        assertEquals(JukeboxLink("exmkrd5a", null), JukeboxLink.forEntry("exmkrd5a", " "))
        assertNull(JukeboxLink.forEntry("BAD", null))
    }
}
