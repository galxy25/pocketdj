package com.levi.pocketdj.onboarding

import com.levi.pocketdj.data.credentials.InMemorySecretStore
import com.levi.pocketdj.data.sync.CloudSyncService.ProfileProbe
import com.levi.pocketdj.data.sync.LinkCode
import com.levi.pocketdj.data.sync.ProfileSecretStore
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LinkDeviceProbeTest {
    private val otherId = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
    private val otherSecret = "ab".repeat(32)

    private class Fixture(configured: Boolean = true, var probe: ProfileProbe = ProfileProbe.Fresh) {
        val secrets = ProfileSecretStore(InMemorySecretStore())
        var id = "MY-OWN-ID"
        var unauthorized = false
        var probeCalls = 0
        var restored: List<String>? = listOf("profile")
        var held = false
        val sut = S3LinkDeviceProbe(
            secrets, { id }, { id = it }, { unauthorized = false }, { unauthorized },
            { configured }, { probeCalls++; probe }, { restored },
            holdPushes = { held = true }, releasePushes = { held = false },
        )
    }

    @Test fun notConfigured_isUnavailable_andTouchesNothing() = runTest {
        val f = Fixture(configured = false)
        assertTrue(f.sut.probe() is LinkProbeResult.Unavailable)
        assertTrue(f.sut.link(LinkCode.encode(otherId, otherSecret)) is LinkProbeResult.Unavailable)
        assertEquals(0, f.probeCalls)
        assertEquals("MY-OWN-ID", f.id)
    }

    @Test fun mistypedCode_failsChecksum_beforeAnyNetwork_andNothingAdopted() = runTest {
        val f = Fixture()
        val code = LinkCode.encode(otherId, otherSecret)
        val bad = (if (code[0] == 'A') "B" else "A") + code.drop(1)
        val r = f.sut.link(bad) as LinkProbeResult.Unavailable
        assertTrue(r.reason.contains("doesn't look right"))
        assertEquals(0, f.probeCalls)
        assertEquals("MY-OWN-ID", f.id)
        assertEquals("", f.secrets.secret())
    }

    @Test fun validCode_adoptsIdentity_andReportsExistingName() = runTest {
        val f = Fixture(probe = ProfileProbe.Existing("Levi"))
        val r = f.sut.link(LinkCode.encode(otherId, otherSecret))
        assertEquals(LinkProbeResult.Existing("Levi"), r)
        assertEquals(otherId.lowercase(), f.id)
        assertEquals(otherSecret, f.secrets.secret())
        assertEquals(otherId.lowercase(), f.secrets.enrolledProfileId())
    }

    @Test fun freshCloud_keepsAdoption() = runTest {
        val f = Fixture(probe = ProfileProbe.Fresh)
        assertEquals(LinkProbeResult.Fresh, f.sut.link(LinkCode.encode(otherId, otherSecret)))
        assertEquals(otherSecret, f.secrets.secret())
    }

    @Test fun unreachable_rollsBackToPreviousIdentity() = runTest {
        val f = Fixture(probe = ProfileProbe.Unknown)
        f.secrets.adopt("MY-OWN-ID", "11".repeat(32))
        val r = f.sut.link(LinkCode.encode(otherId, otherSecret))
        assertTrue(r is LinkProbeResult.Unavailable)
        assertEquals("MY-OWN-ID", f.id)
        assertEquals("11".repeat(32), f.secrets.secret())
    }

    @Test fun unauthorizedDuringProbe_surfacesRelinkMessage_andRollsBack() = runTest {
        val f = Fixture()
        val s = f.sut
        f.probe = ProfileProbe.Unknown
        val sut = S3LinkDeviceProbe(f.secrets, { f.id }, { f.id = it }, { f.unauthorized = false }, { true },
            { true }, { ProfileProbe.Unknown }, { null })
        val r = sut.link(LinkCode.encode(otherId, otherSecret)) as LinkProbeResult.Unavailable
        assertTrue(r.reason.contains("Profile not authorized"))
        assertEquals("MY-OWN-ID", f.id)
        assertTrue(s !== sut)
    }

    @Test fun link_turnsSyncOn_whenOff_andBackOffIfLinkFails() = runTest {
        var on = false
        var probe: ProfileProbe = ProfileProbe.Existing("A")
        val sut = S3LinkDeviceProbe(InMemorySecretStore().let { ProfileSecretStore(it) }, { "ME" }, { }, { }, { false },
            { true }, { if (on) probe else ProfileProbe.Disabled }, { listOf("x") },
            syncEnabled = { on }, setSyncEnabled = { on = it })
        assertTrue(sut.link(LinkCode.encode(otherId, otherSecret)) is LinkProbeResult.Existing)
        assertTrue(on)
        sut.unlink()
        assertTrue(!on)
        probe = ProfileProbe.Unknown
        assertTrue(sut.link(LinkCode.encode(otherId, otherSecret)) is LinkProbeResult.Unavailable)
        assertTrue(!on)
    }

    @Test fun restore_reflectsPassOutcome() = runTest {
        val f = Fixture()
        assertTrue(f.sut.restore())
        f.restored = null
        assertTrue(!f.sut.restore())
    }

    @Test fun plainProbe_mapsExistingFreshAndNoAccount() = runTest {
        val f = Fixture(probe = ProfileProbe.Existing("A"))
        assertEquals(LinkProbeResult.Existing("A"), f.sut.probe())
        f.probe = ProfileProbe.NoAccount
        assertTrue(f.sut.probe() is LinkProbeResult.Unavailable)
    }

    @Test fun startFreshAfterLink_restoresPreLinkIdentity() = runTest {
        val f = Fixture(probe = ProfileProbe.Existing("Levi"))
        f.secrets.adopt("MY-OWN-ID", "11".repeat(32))
        f.sut.link(LinkCode.encode(otherId, otherSecret))
        assertEquals(otherId.lowercase(), f.id)
        f.sut.unlink()
        assertEquals("MY-OWN-ID", f.id)
        assertEquals("11".repeat(32), f.secrets.secret())
        assertEquals(false, f.held)
    }

    @Test fun failedRestore_thenUnlink_neverKeepsOtherDevicesIdentity() = runTest {
        val f = Fixture(probe = ProfileProbe.Existing("Levi"))
        f.restored = null
        f.sut.link(LinkCode.encode(otherId, otherSecret))
        assertTrue(!f.sut.restore())
        f.sut.unlink()
        assertEquals("MY-OWN-ID", f.id)
        assertEquals("", f.secrets.secret())
    }

    @Test fun successfulRestore_makesUnlinkANoOp() = runTest {
        val f = Fixture(probe = ProfileProbe.Existing("Levi"))
        f.sut.link(LinkCode.encode(otherId, otherSecret))
        assertTrue(f.sut.restore())
        f.sut.unlink()
        assertEquals(otherId.lowercase(), f.id)
    }

    @Test fun link_holdsPushesUntilRestore_andReleasesOnFreshOrFailure() = runTest {
        val a = Fixture(probe = ProfileProbe.Existing("Levi"))
        a.sut.link(LinkCode.encode(otherId, otherSecret))
        assertTrue("pull-only until the first pull", a.held)
        val b = Fixture(probe = ProfileProbe.Fresh)
        b.sut.link(LinkCode.encode(otherId, otherSecret))
        assertEquals(false, b.held)
        val c = Fixture(probe = ProfileProbe.Unknown)
        c.sut.link(LinkCode.encode(otherId, otherSecret))
        assertEquals(false, c.held)
    }

    @Test fun unlinkWithoutLink_isNoOp() = runTest {
        val f = Fixture()
        f.sut.unlink()
        assertEquals("MY-OWN-ID", f.id)
    }
}
