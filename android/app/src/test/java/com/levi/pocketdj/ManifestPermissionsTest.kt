package com.levi.pocketdj

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/** Source-manifest assertions for the location permissions (Levi 2026-10-29 C2 reversal: background IS declared). */
class ManifestPermissionsTest {
    private val xml: String by lazy {
        val f = listOf("src/main/AndroidManifest.xml", "app/src/main/AndroidManifest.xml").map(::File).first { it.exists() }
        f.readText().replace(Regex("<!--.*?-->", RegexOption.DOT_MATCHES_ALL), "")
    }

    private fun declares(p: String) = "android:name=\"android.permission.$p\"" in xml

    @Test fun declaresLocationPermissionsIncludingBackgroundAndFgsLocation() {
        for (p in listOf("ACCESS_COARSE_LOCATION", "ACCESS_FINE_LOCATION", "ACCESS_BACKGROUND_LOCATION", "FOREGROUND_SERVICE_LOCATION", "FOREGROUND_SERVICE_MEDIA_PLAYBACK")) {
            assertTrue("missing $p", declares(p))
        }
    }

    @Test fun playbackServiceDeclaresLocationType() {
        val svc = Regex("<service\\s[^>]*PlaybackService[^>]*>", RegexOption.DOT_MATCHES_ALL).find(xml)!!.value
        assertTrue(svc, Regex("foregroundServiceType=\"[^\"]*mediaPlayback[^\"]*\"").find(svc)!!.value.contains("location"))
    }

    @Test fun applicationRequestsLargeHeap() {
        // Answers verification: ~130-185 MB of live catalog state OOM'd the For You ranking on a 192 MB growth limit.
        val app = Regex("<application\\s[^>]*>", RegexOption.DOT_MATCHES_ALL).find(xml)!!.value
        assertTrue(app, "android:largeHeap=\"true\"" in app)
    }
}
