package com.levi.pocketdj.data.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class LinkCodeTest {
    private val id = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
    private val secret = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    @Test fun roundTrip() {
        val code = LinkCode.encode(id, secret)
        val d = LinkCode.decode(code) as LinkCode.Decoded.Ok
        assertEquals(id.lowercase(), d.profileId)
        assertEquals(secret, d.secret)
    }

    @Test fun groupedInFives_andLooksTypable() {
        val code = LinkCode.encode(id, secret)
        assertTrue(code.split('-').dropLast(1).all { it.length == 5 })
        assertTrue(code.all { it == '-' || it in "0123456789ABCDEFGHJKMNPQRSTVWXYZ" })
    }

    @Test fun toleratesCaseSpacesAndConfusables() {
        val code = LinkCode.encode(id, secret)
        val sloppy = " " + code.lowercase().replace("0", "o").replace("1", "l").replace('-', ' ') + "\n"
        assertEquals(LinkCode.decode(code), LinkCode.decode(sloppy))
    }

    @Test fun singleCharTypoFailsChecksum() {
        val code = LinkCode.encode(id, secret)
        for (i in listOf(0, 7, 40, 80)) {
            val chars = code.toCharArray()
            val pos = code.indices.filter { code[it] != '-' }[i]
            chars[pos] = if (chars[pos] == 'A') 'B' else 'A'
            val r = LinkCode.decode(String(chars))
            assertTrue("typo at $i -> $r", r == LinkCode.Decoded.BadChecksum || r == LinkCode.Decoded.BadFormat)
        }
    }

    @Test fun garbageAndTruncationAreBadFormat() {
        assertEquals(LinkCode.Decoded.BadFormat, LinkCode.decode(""))
        assertEquals(LinkCode.Decoded.BadFormat, LinkCode.decode("hello world!"))
        assertEquals(LinkCode.Decoded.BadFormat, LinkCode.decode(LinkCode.encode(id, secret).dropLast(7)))
    }

    @Test fun uriFormRoundTripsAndIsAcceptedByDecode() {
        val uri = LinkCode.toUri(id, secret)
        assertTrue(uri.startsWith("pocketdj://link?code="))
        assertEquals(LinkCode.decode(LinkCode.encode(id, secret)), LinkCode.decode(uri))
        assertEquals(LinkCode.Decoded.BadFormat, LinkCode.decode("pocketdj://link?nothing=1"))
    }

    @Test fun differentSecretsGiveDifferentCodes() {
        assertTrue(LinkCode.encode(id, secret) != LinkCode.encode(id, secret.replace('0', '1')))
        assertTrue(LinkCode.encode(UUID.randomUUID().toString(), secret) != LinkCode.encode(id, secret))
    }

    @Test fun redactedToString() {
        val d = LinkCode.decode(LinkCode.encode(id, secret))
        assertTrue(!d.toString().contains(secret))
    }

    @Test(expected = IllegalArgumentException::class) fun rejectsNonHexSecret() {
        LinkCode.encode(id, "zz")
    }
}
