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
        assertEquals(emptyList<String>(), ShazamDeveloperToken.problems(jwt(), NOW + 60))
    }

    @Test fun not_a_jwt() {
        assertNull(ShazamDeveloperToken.decode("abc"))
        assertNull(ShazamDeveloperToken.decode("a.b"))
        assertNull(ShazamDeveloperToken.decode("!!.@@.##"))
        assertEquals(listOf("not a JWT"), ShazamDeveloperToken.problems("", NOW))
    }

    @Test fun wrong_alg_and_missing_ids() {
        val t = jwt(header = """{"alg":"HS256","typ":"JWT"}""", claims = """{"iat":$NOW,"exp":${NOW + 3600}}""")
        val p = ShazamDeveloperToken.problems(t, NOW)
        assertTrue(p.toString(), p.any { it.startsWith("alg is HS256") })
        assertTrue(p.contains("kid (key id) missing"))
        assertTrue(p.contains("iss (team id) missing"))
    }

    @Test fun expiry_rules() {
        assertTrue(ShazamDeveloperToken.problems(jwt(), NOW + 151L * 24 * 3600).contains("expired"))
        val tooLong = jwt(claims = """{"iss":"T","iat":$NOW,"exp":${NOW + ShazamDeveloperToken.MAX_LIFETIME_SEC + 1}}""")
        assertTrue(ShazamDeveloperToken.problems(tooLong, NOW).contains("lifetime exceeds 6 months"))
        val future = jwt(claims = """{"iss":"T","iat":${NOW + 3600},"exp":${NOW + 7200}}""")
        assertTrue(ShazamDeveloperToken.problems(future, NOW).contains("iat is in the future"))
        val noTimes = jwt(claims = """{"iss":"T"}""")
        assertTrue(ShazamDeveloperToken.problems(noTimes, NOW).containsAll(listOf("iat missing", "exp missing")))
    }
}
