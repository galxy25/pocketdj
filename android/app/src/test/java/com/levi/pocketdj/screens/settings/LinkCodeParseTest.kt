package com.levi.pocketdj.screens.settings

import com.levi.pocketdj.data.sync.LinkCode
import com.levi.pocketdj.shell.DeepLink
import com.levi.pocketdj.shell.DeepLinkParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LinkCodeParseTest {
    private val id = "123e4567-e89b-12d3-a456-426614174000"
    private val secret = "ab".repeat(32)
    private val code = LinkCode.encode(id, secret)

    private fun assertDecodesToSame(c: String) {
        val d = LinkCode.decode(c) as LinkCode.Decoded.Ok
        assertEquals(id, d.profileId); assertEquals(secret, d.secret)
    }

    @Test fun scanAcceptsBareGroupedAndUngroupedCodes() {
        assertDecodesToSame(LinkScan.extract(code)!!)
        assertDecodesToSame(LinkScan.extract(code.replace("-", "").lowercase())!!)
    }

    @Test fun scanAcceptsOwnQrPayload() {
        assertDecodesToSame(LinkScan.extract(LinkCode.URI_PREFIX + code.replace("-", ""))!!)
    }

    @Test fun scanAcceptsPathForm() {
        assertDecodesToSame(LinkScan.extract("pocketdj://link/$code")!!)
    }

    @Test fun scanRejectsForeignAndCorruptPayloads() {
        assertNull(LinkScan.extract(null))
        assertNull(LinkScan.extract("  "))
        assertNull(LinkScan.extract("https://example.com/?code=$code"))
        assertNull(LinkScan.extract("pocketdj://jukebox/abcd"))
        assertNull(LinkScan.extract("pocketdj://link"))
        val flipped = code.replace("-", "").let { (if (it[3] == '0') "1" else "0").let { r -> it.substring(0, 3) + r + it.substring(4) } }
        assertNull(LinkScan.extract(flipped))
        assertNull(LinkScan.extract("hello world"))
    }

    @Test fun deepLinkPathAndQueryFormsParse() {
        for (u in listOf("pocketdj://link/$code", "pocketdj://link?code=${code.replace("-", "")}", "pocketdj:///link/$code")) {
            val link = DeepLinkParser.parse(u)
            assertTrue(u, link is DeepLink.LinkDevice)
            assertDecodesToSame((link as DeepLink.LinkDevice).code)
        }
    }

    @Test fun deepLinkWithBadCodeIsUnresolvedNotParked() {
        assertTrue(DeepLinkParser.parse("pocketdj://link/ABC123") is DeepLink.Unresolved)
    }

    @Test fun deepLinkWithoutCodeIsNone() {
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://link"))
    }

    @Test fun manifestDeclaresOptionalCameraPermission() {
        val f = listOf("src/main/AndroidManifest.xml", "app/src/main/AndroidManifest.xml").map { java.io.File(it) }.first { it.exists() }
        val xml = f.readText().replace(Regex("<!--.*?-->", RegexOption.DOT_MATCHES_ALL), "")
        assertTrue("android:name=\"android.permission.CAMERA\"" in xml)
        assertTrue(Regex("android.hardware.camera\"\\s+android:required=\"false\"").containsMatchIn(xml))
    }
}
