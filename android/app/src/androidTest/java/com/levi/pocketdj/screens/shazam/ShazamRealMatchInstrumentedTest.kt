package com.levi.pocketdj.screens.shazam

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.levi.pocketdj.audio.core.AudioDecoder
import com.shazam.shazamkit.AudioSampleRateInHz
import com.shazam.shazamkit.DeveloperToken
import com.shazam.shazamkit.DeveloperTokenProvider
import com.shazam.shazamkit.MatchResult
import com.shazam.shazamkit.ShazamKit
import com.shazam.shazamkit.ShazamKitResult
import com.shazam.shazamkit.Signature
import java.io.File
import java.util.Locale
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Real ShazamKit round trip against Apple's catalog: decode a clip of a well-known song, build a
 * signature on device, match it with a real developer token. No audio is committed (copyright):
 * the clip and the token are pushed at run time and passed as instrumentation args.
 *
 *   ffmpeg -ss 45 -t 10 -i song.mp3 -ac 1 -ar 48000 clip.wav && adb push clip.wav /data/local/tmp/shazam-clip.wav
 *   node scripts/shazam-token-probe.mjs --out tok && adb push tok /data/local/tmp/shazam-token && rm tok
 *   ./gradlew :app:connectedDebugAndroidTest \
 *     -Pandroid.testInstrumentationRunnerArguments.class=com.levi.pocketdj.screens.shazam.ShazamRealMatchInstrumentedTest \
 *     -Pandroid.testInstrumentationRunnerArguments.shazamClip=/data/local/tmp/shazam-clip.wav \
 *     -Pandroid.testInstrumentationRunnerArguments.shazamToken=/data/local/tmp/shazam-token \
 *     -Pandroid.testInstrumentationRunnerArguments.shazamExpectTitle="Make Me Proud"
 *
 * Without the args each test is skipped (assumption), so the default connected run stays green.
 */
@RunWith(AndroidJUnit4::class)
class ShazamRealMatchInstrumentedTest {
    private val args = InstrumentationRegistry.getArguments()

    private fun clip(): File {
        val path = args.getString("shazamClip")
        assumeTrue("pass -e shazamClip <device path>", !path.isNullOrBlank() && File(path).canRead())
        return File(path!!)
    }

    private suspend fun signatureOf(clip: File): Signature {
        val pcm = AudioDecoder.decode(clip.path, rate = 48_000, maxSeconds = 10.0)
        assertNotNull("clip did not decode", pcm)
        val mono = pcm!!.let { p ->
            ByteArray(p.frames * 2).also { out ->
                for (f in 0 until p.frames) {
                    var s = 0f
                    for (c in 0 until p.channels) s += p.samples[f * p.channels + c]
                    val v = (s / p.channels * 32767f).toInt().coerceIn(-32768, 32767)
                    out[2 * f] = (v and 0xFF).toByte(); out[2 * f + 1] = (v shr 8).toByte()
                }
            }
        }
        val gen = when (val r = ShazamKit.createSignatureGenerator(AudioSampleRateInHz.SAMPLE_RATE_48000)) {
            is ShazamKitResult.Success -> r.data
            is ShazamKitResult.Failure -> { fail("signature generator: ${r.reason}"); error("unreachable") }
        }
        gen.append(mono, mono.size, System.currentTimeMillis())
        return gen.generateSignature()
    }

    @Test fun signatureFromClip() = runBlocking<Unit> {
        val sig = signatureOf(clip())
        assertTrue("signature too short: ${sig.durationInMs} ms", sig.durationInMs >= 3_000)
    }

    @Test fun realCatalogMatch() = runBlocking<Unit> {
        val clip = clip()
        val tokenPath = args.getString("shazamToken")
        assumeTrue("pass -e shazamToken <device path to a developer JWT>", !tokenPath.isNullOrBlank() && File(tokenPath).canRead())
        val token = File(tokenPath!!).readText().trim()
        assertEquals("token shape", emptyList<String>(), ShazamDeveloperToken.problems(token))

        val catalog = ShazamKit.createShazamCatalog(DeveloperTokenProvider { DeveloperToken(token) }, Locale.US)
        val session = when (val r = ShazamKit.createSession(catalog)) {
            is ShazamKitResult.Success -> r.data
            is ShazamKitResult.Failure -> { fail("session: ${r.reason}"); error("unreachable") }
        }
        when (val m = session.match(signatureOf(clip))) {
            is MatchResult.Match -> {
                val item = m.matchedMediaItems.first()
                android.util.Log.i("ShazamRealMatch", "MATCH title=${item.title} artist=${item.artist} am=${item.appleMusicID}")
                args.getString("shazamExpectTitle")?.let { want ->
                    assertTrue("matched '${item.title}', expected '$want'", item.title?.contains(want, ignoreCase = true) == true)
                }
            }
            is MatchResult.NoMatch -> fail("no match for a well-known clip")
            is MatchResult.Error -> fail(
                "${m.exception.matchError}: " + shazamMatchErrorMessage(m.exception.matchError.name, m.exception.message),
            )
        }
    }
}
