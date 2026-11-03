package com.levi.pocketdj.screens.shazam

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The developer-token shape ShazamKit expects (ES256, kid = key id, iss = team id, iat/exp,
 * lifetime <= 6 months, no other claims required). Mirrors scripts/rip-server.mjs
 * mintMusicKitToken(), which mints the token both MusicKit and ShazamKit use.
 */
class ShazamDeveloperTokenTest {
    companion object {
        const val NOW = 1_793_660_000L
        private fun b64(s: String) = Base64.getUrlEncoder().withoutPadding().encodeToString(s.toByteArray())

        /** Unsigned JWT with the rip server's header/claims layout (signature is a placeholder). */
        fun jwt(
            header: String = """{"alg":"ES256","kid":"9JRN4H68X4","typ":"JWT"}""",
            claims: String = """{"iss":"EC27UF79GL","iat":$NOW,"exp":${NOW + 150L * 24 * 3600}}""",
        ) = "${b64(header)}.${b64(claims)}.c2ln"
    }

    @Test fun rip_server_token_shape_passes() {
        val p = ShazamDeveloperToken.decode(jwt())!!
        assertEquals("ES256", p.alg); assertEquals("9JRN4H68X4", p.kid); assertEquals("EC27UF79GL", p.iss)
        assertEquals(NOW, p.iat)
        assertEquals(emptyList<String>(), ShazamDeveloperToken.problems(jwt()))
        assertEquals(emptyList<String>(), ShazamDeveloperToken.clockNotes(jwt(), NOW + 60))
    }

    @Test fun not_a_jwt() {
        assertNull(ShazamDeveloperToken.decode("abc"))
        assertNull(ShazamDeveloperToken.decode("a.b"))
        assertNull(ShazamDeveloperToken.decode("!!.@@.##"))
        assertEquals(listOf("not a JWT"), ShazamDeveloperToken.problems(""))
        assertEquals(listOf("not a JWT"), ShazamDeveloperToken.problems("""${b64("[1]")}.${b64("{}")}.c2ln"""))
    }

    @Test fun wrong_alg_and_missing_ids() {
        val t = jwt(header = """{"alg":"HS256","typ":"JWT"}""", claims = """{"iat":$NOW,"exp":${NOW + 3600}}""")
        val p = ShazamDeveloperToken.problems(t)
        assertTrue(p.toString(), p.any { it.startsWith("alg is HS256") })
        assertTrue(p.contains("kid (key id) missing"))
        assertTrue(p.contains("iss (team id) missing"))
    }

    @Test fun lifetime_rules_are_clock_free() {
        val tooLong = jwt(claims = """{"iss":"T","iat":$NOW,"exp":${NOW + ShazamDeveloperToken.MAX_LIFETIME_SEC + 1}}""")
        assertTrue(ShazamDeveloperToken.problems(tooLong).contains("lifetime exceeds 6 months"))
        val atCap = jwt(claims = """{"iss":"T","iat":$NOW,"exp":${NOW + ShazamDeveloperToken.MAX_LIFETIME_SEC}}""")
        assertEquals(emptyList<String>(), ShazamDeveloperToken.problems(atCap))
        val inverted = jwt(claims = """{"iss":"T","iat":${NOW + 10},"exp":$NOW}""")
        assertTrue(ShazamDeveloperToken.problems(inverted).contains("exp is not after iat"))
        val noTimes = jwt(claims = """{"iss":"T"}""")
        assertTrue(ShazamDeveloperToken.problems(noTimes).containsAll(listOf("iat missing", "exp missing")))
    }

    /** Apple checks iat/exp on its own clock: a skewed phone clock must never block a valid token. */
    @Test fun device_clock_never_blocks() {
        val t = jwt()
        // Phone 10 minutes slow (iat "in the future") and phone a year fast (token "expired").
        for (now in listOf(NOW - 600, NOW + 365L * 24 * 3600)) {
            assertEquals(emptyList<String>(), ShazamDeveloperToken.problems(t))
            assertTrue(ShazamDeveloperToken.clockNotes(t, now).isNotEmpty())
        }
        // Inside the 5-minute skew window there is nothing to note.
        assertEquals(emptyList<String>(), ShazamDeveloperToken.clockNotes(t, NOW - 299))
        assertEquals(emptyList<String>(), ShazamDeveloperToken.clockNotes("garbage", NOW))
    }

    @Test fun tolerant_of_padding_extra_claims_and_fractional_dates() {
        // Padded base64url segments (some minters keep '=').
        val enc = Base64.getUrlEncoder()
        val padded = listOf(
            enc.encodeToString("""{"alg":"ES256","kid":"K"}""".toByteArray()),
            enc.encodeToString("""{"iss":"T","iat":$NOW,"exp":${NOW + 3600}}""".toByteArray()),
            "c2ln",
        ).joinToString(".")
        assertTrue(padded.contains('='))
        assertEquals(emptyList<String>(), ShazamDeveloperToken.problems(padded))
        // Extra header fields + claims (origin, sub, nbf...) are allowed.
        val extra = jwt(
            header = """{"alg":"ES256","kid":"K","typ":"JWT","x5t":"z"}""",
            claims = """{"iss":"T","iat":$NOW,"exp":${NOW + 3600},"origin":["https://pocket-dj.com"],"nbf":$NOW,"sub":"s"}""",
        )
        assertEquals(emptyList<String>(), ShazamDeveloperToken.problems(extra))
        // RFC 7519 NumericDate may be fractional.
        val frac = jwt(claims = """{"iss":"T","iat":$NOW.5,"exp":${NOW + 3600}.25}""")
        assertEquals(NOW, ShazamDeveloperToken.decode(frac)!!.iat)
        assertEquals(emptyList<String>(), ShazamDeveloperToken.problems(frac))
        // Surrounding whitespace / trailing newline (token read from a file).
        assertEquals(emptyList<String>(), ShazamDeveloperToken.problems(jwt() + "\n"))
    }
}
