package com.levi.pocketdj.remote.mix

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.mix.engine.Gesture
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.LoadedTrack
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.remote.RemoteEnvelope
import com.levi.pocketdj.remote.RemoteRecipient
import com.levi.pocketdj.screens.remote.MixTogetherCopy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ports the drift / loop / held-deck / readiness cases of iOS `MixSyncTests` over [MixSync] devices on an in-memory FIFO
 * net (the same one [MixSyncCoreTest] uses), one manual clock with per-device skew, a fake deck port (no audio), every
 * tick by hand.
 */
class MixSyncDriftTest {
    private val json = PdjJson.lenient

    private fun assertEquals(msg: String, expected: Int, actual: Int) = org.junit.Assert.assertEquals(msg, expected.toLong(), actual.toLong())

    private class Clock { var t = 8_000_000.0 }

    // ---------------- fake deck port ----------------

    private class DeckSt {
        var songId: String? = null
        var isPlaying = false
        var posMs = 0
        var at = 0.0
        var durationMs = 200_000
        var rate = 1.0
        var ready = true
        var controls = HashMap<String, MixSyncEvent>()
        var nudge = 1.0
        var loop: Pair<Int, Int>? = null
    }

    private class FakePort(val now: () -> Double) : MixSyncDeckPort {
        override var gestureTap: ((Gesture) -> Unit)? = null
        val decks = mapOf(Deck.A to DeckSt(), Deck.B to DeckSt())
        var crossfader = 0.5
        var blockedReason: String? = null
        var sessionActive = false
        val nudges = ArrayList<Pair<Deck, Double>>()
        val applied = ArrayList<String>()
        class Play(val deck: Deck, val fromMs: Int, val atLocalMs: Double)
        val plays = ArrayList<Play>()
        val gestures = ArrayList<Gesture>()
        var loadsReady = true
        val seeds = HashMap<Deck, List<MixSyncEvent>>()
        var loads = 0

        fun d(deck: Deck) = decks.getValue(deck)

        fun playhead(deck: Deck): Int {
            val s = d(deck)
            val linear = if (s.isPlaying) s.posMs + Math.round((now() - s.at) * s.rate * s.nudge).toInt() else s.posMs
            val w = s.loop
            if (w == null || w.second <= w.first || linear < w.first) return linear
            return w.first + (linear - w.first) % (w.second - w.first)
        }

        private fun rebase(deck: Deck) { d(deck).let { it.posMs = playhead(deck); it.at = now() } }

        override fun syncStatus(deck: Deck): MixSyncDeckStatus {
            val s = d(deck)
            return MixSyncDeckStatus(
                s.songId, s.isPlaying, playhead(deck), if (s.songId == null) 0 else s.durationMs, s.rate,
                s.songId != null && s.ready, s.loop != null, s.loop?.first, s.loop?.second,
            )
        }

        override fun syncLoad(item: MixLoadable, deck: Deck) {
            val old = d(deck).controls
            decks.getValue(deck).also { it.songId = item.songId; it.isPlaying = false; it.posMs = 0; it.at = now(); it.rate = 1.0; it.ready = true; it.loop = null; it.nudge = 1.0; it.controls = old }
            loads++
            applied += "load:${deck.label}:${item.songId}"
        }

        override fun syncEject(deck: Deck) {
            val s = d(deck)
            s.songId = null; s.isPlaying = false; s.posMs = 0; s.loop = null; s.controls = HashMap(); s.rate = 1.0
            applied += "eject:${deck.label}"
        }

        override fun syncPlay(deck: Deck, fromMs: Int, atLocalMs: Double) {
            val s = d(deck)
            val w = s.loop
            s.posMs = if (w != null && w.second > w.first) w.first + Math.floorMod(fromMs - w.first, w.second - w.first) else fromMs
            s.isPlaying = true
            s.at = atLocalMs
            plays += Play(deck, fromMs, atLocalMs)
            applied += "play:${deck.label}:$fromMs"
        }

        override fun syncPause(deck: Deck, atMs: Int) {
            val s = d(deck)
            s.isPlaying = false; s.posMs = atMs; s.at = now()
            applied += "pause:${deck.label}:$atMs"
        }

        override fun syncApplyControl(e: MixSyncEvent) {
            if (e.kind == MixSyncKind.CROSSFADER) { crossfader = e.value ?: crossfader; applied += "ctl:crossfader=${e.value}"; return }
            val deck = e.engineDeck ?: return
            if (e.kind == MixSyncKind.TEMPO) { rebase(deck); e.value?.let { d(deck).rate = it } }
            d(deck).controls[e.controlKey] = e
            applied += "ctl:${e.kind}:${deck.label}=${e.value}"
        }

        override fun syncSetControls(deck: Deck, controls: List<MixSyncEvent>) {
            val c = HashMap<String, MixSyncEvent>()
            for (e in controls) if (e.kind != MixSyncKind.LOOP && e.kind != MixSyncKind.LOOP_UNITS) c[e.controlKey] = e
            rebase(deck)
            d(deck).rate = c["rate:${deck.label}"]?.value ?: 1.0
            d(deck).controls = c
            applied += "controls:${deck.label}:${c.keys.sorted().joinToString(",")}"
        }

        override fun syncSetLoop(deck: Deck, on: Boolean, units: Double?, startMs: Int?, endMs: Int?) {
            rebase(deck)
            if (on && startMs != null && endMs != null) d(deck).loop = startMs to endMs else if (!on) d(deck).loop = null
            applied += "loop:${deck.label}:" + if (on) "$startMs-$endMs" else "off"
        }

        override fun syncNudgeRate(deck: Deck, factor: Double) {
            rebase(deck); d(deck).nudge = factor; nudges += deck to factor
        }

        override fun syncSeedEvents(deck: Deck): List<MixSyncEvent> = seeds[deck] ?: emptyList()
        override val syncCrossfader: Double get() = crossfader
        override fun setAutoDjBlocked(reason: String?) { blockedReason = reason }
        override fun syncSessionActive(on: Boolean) { sessionActive = on }

        // ---- the user's hands (local gestures -> the tap)
        fun tap(g: Gesture) { gestures += g; gestureTap?.invoke(g) }

        fun userLoad(deck: Deck, id: String) {
            val old = d(deck).controls
            d(deck).also { it.songId = id; it.isPlaying = false; it.posMs = 0; it.at = now(); it.ready = loadsReady; it.controls = old; it.rate = 1.0; it.loop = null }
            tap(Gesture(Gesture.LOAD, deck, posMs = 0, track = LoadedTrack(id, "T-$id", "A", bpm = 120.0), lengthMs = 200_000))
        }

        fun userPlay(deck: Deck, fromMs: Int? = null) {
            fromMs?.let { d(deck).posMs = it }
            d(deck).isPlaying = true; d(deck).at = now()
            tap(Gesture(MixSyncKind.PLAY, deck, posMs = playhead(deck)))
        }

        fun userPause(deck: Deck) {
            rebase(deck); d(deck).isPlaying = false
            tap(Gesture(MixSyncKind.PAUSE, deck, posMs = playhead(deck)))
        }

        fun userSet(kind: String, deck: Deck, v: Double) {
            d(deck).controls[MixSyncEvent(kind, deck.label).controlKey] = MixSyncEvent(kind, deck.label, value = v)
            tap(Gesture(kind, deck, value = v))
        }

        fun value(kind: String, deck: Deck): Double? = d(deck).controls[MixSyncEvent(kind, deck.label).controlKey]?.value

        fun systemPause(deck: Deck) {
            rebase(deck); d(deck).isPlaying = false
            tap(Gesture(MixSyncKind.PAUSE, deck, posMs = playhead(deck), cause = Gesture.Cause.SYSTEM))
        }

        fun systemPlay(deck: Deck) {
            d(deck).isPlaying = true; d(deck).at = now()
            tap(Gesture(MixSyncKind.PLAY, deck, posMs = playhead(deck), cause = Gesture.Cause.SYSTEM))
        }

        fun enginePause(deck: Deck) {
            rebase(deck); d(deck).isPlaying = false
            tap(Gesture(MixSyncKind.PAUSE, deck, posMs = playhead(deck), cause = Gesture.Cause.ENGINE))
        }

        fun userLoop(deck: Deck, start: Int, end: Int) {
            rebase(deck); d(deck).loop = start to end
            tap(Gesture(Gesture.LOOP, deck, value = 2.0, flag = true, posMs = playhead(deck), loopStartMs = start, loopEndMs = end))
        }
    }

    // ---------------- net + devices ----------------

    private class Net {
        val devs = LinkedHashMap<String, Dev>()
        var hostId: String? = null
        val log = ArrayList<Triple<String, String, RemoteEnvelope>>()
        private val queue = ArrayDeque<Triple<String, String, RemoteEnvelope>>()

        fun route(from: String, env: RemoteEnvelope, to: RemoteRecipient) {
            val targets = when (to) {
                RemoteRecipient.All -> devs.keys.filter { it != from }
                is RemoteRecipient.Participant -> listOf(to.id).filter { it != from && it in devs }
            }
            for (t in targets) { log += Triple(from, t, env); queue += Triple(from, t, env) }
        }

        fun pump() {
            var guard = 0
            while (queue.isNotEmpty() && guard++ < 10_000) {
                val (from, to, env) = queue.removeFirst()
                devs[to]?.sync?.core?.receive(env, from)
            }
        }
    }

    private class Dev(val id: String, val net: Net, val clock: Clock, val skew: Double, unmixable: Set<String>, val caps: List<String>?) {
        var offsetToHost: Double? = null
        var live = true
        var rttMs = 2.0
        val startedHook = ArrayList<Int>()
        val now: () -> Double = { clock.t + skew }
        val port = FakePort(now)
        val session = object : MixSyncSession {
            override val localId get() = id
            override val hostId get() = net.hostId
            override val isSessionActive get() = live
            override val isListenTogether get() = true
            override val roster get() = net.devs.keys.toSet()
            override fun localNow() = now()
            override fun sharedNow() = if (net.hostId == id) now() else offsetToHost?.let { now() + it }
            override fun offsetToCurrentHost() = if (net.hostId == id) 0.0 else offsetToHost
            override fun peerCaps(id: String) = net.devs[id]?.caps
            override fun peerPlatform(id: String) = "test"
            override fun peerName(id: String) = "Dev $id"
            override fun send(envelope: RemoteEnvelope, to: RemoteRecipient) = net.route(id, envelope, to)
        }
        val sync = MixSync(
            session, object : MixSyncClockPort { override fun bestRttMs() = rttMs }, port,
            resolve = { e -> if (e.songId == null || e.songId in unmixable) null else MixLoadable(e.songId, e.title ?: e.songId, e.artist ?: "") },
            onMixStarted = { startedHook += 1 },
        )
    }

    private val clock = Clock()
    private val net = Net()

    private fun dev(id: String, skew: Double = 0.0, unmixable: Set<String> = emptySet(), caps: List<String>? = listOf("mix")): Dev {
        val d = Dev(id, net, clock, skew, unmixable, caps)
        net.devs[id] = d
        return d
    }

    private fun join(d: Dev, host: Dev) {
        d.offsetToHost = host.skew - d.skew
        d.sync.tick(); net.pump(); host.sync.tick(); net.pump()
    }

    private fun advance(ms: Double) { clock.t += ms }

    private fun twoDeviceMix(guestSkew: Double = 0.0): Pair<Dev, Dev> {
        val a = dev("A"); net.hostId = "A"; a.sync.tick()
        val b = dev("B", guestSkew); join(b, a)
        a.sync.tick(); a.sync.start(); net.pump()
        return a to b
    }

    private fun envOf(kind: String, body: String) =
        RemoteEnvelope(1, kind, java.util.Base64.getEncoder().encodeToString(body.toByteArray()))

    private fun sentKinds(from: String, kind: String) = net.log.filter { it.first == from && it.third.kind == kind }
    private fun sentCount(d: Dev, kind: String) = net.log.filter { it.first == d.id && it.third.kind == kind }.map { it.third }.distinct().size

    private inline fun <reified T> lastSent(d: Dev, kind: String, ser: kotlinx.serialization.KSerializer<T>): T? =
        sentKinds(d.id, kind).lastOrNull()?.third?.decode(ser)

    private fun beat(a: Dev, b: Dev) {
        advance(MixSyncTunables.HEARTBEAT_MS)
        a.sync.tick(); net.pump(); b.sync.tick()
    }

    private fun loadAndPlayA(a: Dev, b: Dev, from: Int = 0) {
        a.port.userLoad(Deck.A, "s1"); net.pump()
        a.port.userPlay(Deck.A, from); net.pump()
    }

    // ---------------- pure math ----------------

    @Test fun thresholdIsTheFloorOrBothClocksUncertaintyPlusMargin() {
        assertEquals(40, MixSyncDrift.threshold(1.0))
        assertEquals(40, MixSyncDrift.threshold(0.0, 0.0))
        assertEquals(120, MixSyncDrift.threshold(100.0))
        assertEquals(135, MixSyncDrift.threshold(100.0, 15.0))
        assertEquals("rounded UP", 141, MixSyncDrift.threshold(100.2, 20.5))
    }

    @Test fun offsetOnALoopingDeckIsThePhaseTheShortWayRound() {
        fun st(play: Int) = MixSyncDeckStatus("s", true, play, 200_000, 1.0, true, true, 10_500, 11_500)
        assertEquals(100, MixSyncDrift.offsetMs(st(10_600), 10_500))
        assertEquals(-100, MixSyncDrift.offsetMs(st(10_500), 10_600))
        // 10 900 vs 21 400 (one + a bit loops later) fold to the same phase region: +0
        assertEquals(0, MixSyncDrift.offsetMs(st(10_900), 10_900 + 3_000))
        // 40 ms behind the loop END looks 40 behind, not 960 ahead
        assertEquals(-80, MixSyncDrift.offsetMs(st(11_460), 11_540))
        assertEquals("wraps the short way: 10 530 is 60 past 11 470 in a 1 s loop", 60, MixSyncDrift.offsetMs(st(10_530), 11_470))
        // not looping: plain difference
        assertEquals(-5_000, MixSyncDrift.offsetMs(MixSyncDeckStatus("s", true, 1_000, 9_000, 1.0, true), 6_000))
    }

    @Test fun scheduledStartsAreClampedToTheMinimumAndMaximumLead() {
        assertEquals(1_060.0, MixSyncDrift.startInstant(900.0, 1_000.0), 0.0)
        assertEquals(1_500.0, MixSyncDrift.startInstant(1_500.0, 1_000.0), 0.0)
        assertEquals(3_000.0, MixSyncDrift.startInstant(99_000.0, 1_000.0), 0.0)
    }

    @Test fun tunablesMatchTheIosConstants() {
        assertEquals(300.0, MixSyncTunables.START_LEAD_MS, 0.0)
        assertEquals(60.0, MixSyncTunables.MIN_LEAD_MS, 0.0)
        assertEquals(2_000.0, MixSyncTunables.MAX_LEAD_MS, 0.0)
        assertEquals(4_000.0, MixSyncTunables.READY_TIMEOUT_MS, 0.0)
        assertEquals(40, MixSyncTunables.DRIFT_THRESHOLD_MS)
        assertEquals(20.0, MixSyncTunables.DRIFT_MARGIN_MS, 0.0)
        assertEquals(2, MixSyncTunables.DRIFT_STRIKES_NEEDED)
        assertEquals(250, MixSyncTunables.NUDGE_MAX_MS)
        assertEquals(0.01, MixSyncTunables.NUDGE_RATE, 0.0)
        assertEquals(4_000.0, MixSyncTunables.DRIFT_COOLDOWN_MS, 0.0)
        assertEquals(1_500.0, MixSyncTunables.STALE_BEAT_MS, 0.0)
    }

    // ---------------- anchored start ----------------

    @Test fun anchoredPlayConvertsSharedTimeWithClockOffset() {
        val (a, b) = twoDeviceMix(guestSkew = 4_000.0) // B's clock reads 4 s ahead
        a.port.userLoad(Deck.A, "s1"); net.pump()
        val hostNow = clock.t
        a.port.userPlay(Deck.A, 10_000); net.pump()
        assertEquals(1, b.port.plays.size)
        val p = b.port.plays[0]
        assertEquals(Deck.A, p.deck)
        // The host anchored the start 300 ms out on ITS clock; B's clock is +4 s.
        assertEquals(hostNow + MixSyncTunables.START_LEAD_MS + 4_000, p.atLocalMs, 0.001)
        assertEquals(10_000 + MixSyncTunables.START_LEAD_MS.toInt(), p.fromMs)
        advance(MixSyncTunables.START_LEAD_MS + 1_000)
        assertEquals(a.port.playhead(Deck.A), b.port.playhead(Deck.A)) // at the shared instant both read the same position
        assertTrue("the owner is the reference: never rescheduled", a.port.plays.isEmpty())
    }

    @Test fun farFutureAnchorIsClampedToTheMaxLead() {
        val (a, b) = twoDeviceMix()
        a.port.userLoad(Deck.A, "s1"); net.pump()
        val far = clock.t + 10_000
        val seq = b.sync.core.model.hostSeq + 1
        val msg = MixSyncEventMessage(0, "A", seq, b.sync.core.model.epoch, MixSyncEvent(
            MixSyncKind.PLAY, deck = "A", posMs = 50_000, anchor = MixSyncAnchor(50_000, far, true)))
        b.sync.core.receive(envOf(MixWireKind.EVENT, json.encodeToString(MixSyncEventMessage.serializer(), msg)), "A")
        val p = b.port.plays.last()
        assertTrue(p.atLocalMs <= clock.t + MixSyncTunables.MAX_LEAD_MS + 0.001)
        assertEquals(50_000 - (10_000 - MixSyncTunables.MAX_LEAD_MS.toInt()), p.fromMs) // sounds where the deck is by then
    }

    @Test fun aStartNotYetHeardIsPulledInToTheMinimumLeadAndPositionCorrected() {
        val (a, b) = twoDeviceMix()
        a.port.userLoad(Deck.A, "s1"); net.pump()
        val seq = b.sync.core.model.hostSeq + 1
        val late = clock.t - 500 // an anchor already 500 ms in the past
        val msg = MixSyncEventMessage(0, "A", seq, b.sync.core.model.epoch, MixSyncEvent(
            MixSyncKind.PLAY, deck = "A", anchor = MixSyncAnchor(20_000, late, true)))
        b.sync.core.receive(envOf(MixWireKind.EVENT, json.encodeToString(MixSyncEventMessage.serializer(), msg)), "A")
        val p = b.port.plays.last()
        assertEquals(clock.t + MixSyncTunables.MIN_LEAD_MS, p.atLocalMs, 0.001)
        assertEquals(20_000 + 560, p.fromMs)
    }

    // ---------------- drift ----------------

    @Test fun driftNeedsTwoBeatsThenNudgesSmallAndReseeksLarge() {
        val (a, b) = twoDeviceMix(guestSkew = -2_500.0)
        loadAndPlayA(a, b)
        assertEquals(1, b.port.plays.size)
        assertEquals("a 2 ms RTT keeps the 40 ms floor", 40, b.sync.driftThreshold())

        beat(a, b)
        assertEquals("in sync -> no correction", 0, b.sync.driftFixCount[Deck.A] ?: 0)

        b.port.d(Deck.A).posMs += 30 // under the 40 ms threshold
        beat(a, b)
        assertEquals(0, b.sync.driftFixCount[Deck.A] ?: 0)

        b.port.d(Deck.A).posMs += 70 // now 100 ms AHEAD
        beat(a, b)
        assertEquals("one beat is not enough (a stale relay)", 0, b.sync.driftFixCount[Deck.A] ?: 0)
        beat(a, b)
        assertEquals("two consecutive beats -> a correction", 1, b.sync.driftFixCount[Deck.A] ?: 0)
        assertEquals("small drift is NUDGED", 1, b.sync.nudgeCount[Deck.A] ?: 0)
        assertEquals("never stop/restarted", 1, b.port.plays.size)
        assertEquals("ahead -> 1 % slow", 1 - MixSyncTunables.NUDGE_RATE, b.port.nudges.last().second, 1e-9)
        assertEquals("the deck's own tempo is untouched", 1.0, b.port.d(Deck.A).rate, 0.0)

        advance(100 / MixSyncTunables.NUDGE_RATE) // exactly long enough to close 100 ms
        b.sync.tick()
        assertEquals("the nudge ends at exactly the deck's tempo", 1.0, b.port.nudges.last().second, 0.0)
        assertTrue("the nudge closed the gap", Math.abs(b.port.playhead(Deck.A) - a.port.playhead(Deck.A)) <= 1)

        b.port.d(Deck.A).posMs += 600 // large drift
        beat(a, b)
        assertEquals(1, b.port.plays.size)
        beat(a, b) // 2nd strike, >= cooldown after the nudge
        assertEquals(2, b.sync.driftFixCount[Deck.A] ?: 0)
        assertEquals("large drift re-seeks", 1, b.sync.nudgeCount[Deck.A] ?: 0)
        assertEquals(2, b.port.plays.size)
        advance(MixSyncTunables.START_LEAD_MS)
        assertEquals("re-seek lands on the owner's position", a.port.playhead(Deck.A), b.port.playhead(Deck.A))

        b.port.d(Deck.A).posMs += 600 // one bad beat...
        beat(a, b)
        b.port.d(Deck.A).posMs -= 600 // ...between good ones
        beat(a, b)
        b.port.d(Deck.A).posMs += 600
        beat(a, b)
        assertEquals("strikes must be CONSECUTIVE", 2, b.sync.driftFixCount[Deck.A] ?: 0)
    }

    @Test fun driftBehindSlidesTheDeckFastWithAOnePercentNudge() {
        val (a, b) = twoDeviceMix()
        loadAndPlayA(a, b)
        b.port.d(Deck.A).posMs -= 120 // 120 ms BEHIND
        beat(a, b); beat(a, b)
        assertEquals(1 + MixSyncTunables.NUDGE_RATE, b.port.nudges.last().second, 1e-9)
        advance(120 / MixSyncTunables.NUDGE_RATE)
        b.sync.tick()
        assertEquals(1.0, b.port.nudges.last().second, 0.0)
        assertTrue(Math.abs(b.port.playhead(Deck.A) - a.port.playhead(Deck.A)) <= 1)
    }

    @Test fun aPlayPauseMismatchReseeksNotNudges() {
        val (a, b) = twoDeviceMix()
        loadAndPlayA(a, b)
        b.port.d(Deck.A).let { it.posMs = b.port.playhead(Deck.A); it.at = b.now(); it.isPlaying = false } // B stopped on its own (no gesture)
        beat(a, b); beat(a, b)
        assertEquals(1, b.sync.driftFixCount[Deck.A] ?: 0)
        assertEquals(0, b.sync.nudgeCount[Deck.A] ?: 0)
        assertTrue("re-seeked: playing again", b.port.d(Deck.A).isPlaying)
        assertEquals(2, b.port.plays.size)
    }

    @Test fun driftThresholdWidensWithClockUncertainty() {
        val (a, b) = twoDeviceMix()
        b.rttMs = 200.0 // a relayed, slow path
        assertEquals("1/2 RTT + 20 ms margin", 120, b.sync.driftThreshold())
        assertEquals("the host's clock is exact", 40, a.sync.driftThreshold())
        loadAndPlayA(a, b)
        advance(MixSyncTunables.START_LEAD_MS)
        b.port.d(Deck.A).posMs += 100 // measurement noise at this RTT
        repeat(3) { beat(a, b) }
        assertEquals("100 ms under a 120 ms uncertainty is not drift", 0, b.sync.driftFixCount[Deck.A] ?: 0)
        b.port.d(Deck.A).posMs += 100 // now 200 off: past it
        repeat(2) { beat(a, b) }
        assertEquals(1, b.sync.driftFixCount[Deck.A] ?: 0)
    }

    @Test fun theBeatsOwnUncertaintyWidensTheThresholdToo() {
        val (a, b) = twoDeviceMix()
        loadAndPlayA(a, b)
        advance(MixSyncTunables.START_LEAD_MS)
        a.rttMs = 400.0 // a is the host: its beat reports 0 -> use B as the owner of deck B instead
        b.port.userLoad(Deck.B, "s2"); net.pump()
        b.port.userPlay(Deck.B, 0); net.pump()
        advance(MixSyncTunables.START_LEAD_MS)
        b.rttMs = 400.0 // the owner of B reports uncertainty 200; the host measures against it
        a.port.d(Deck.B).posMs += 150
        repeat(3) { advance(MixSyncTunables.HEARTBEAT_MS); b.sync.tick(); net.pump() }
        assertEquals("150 ms is inside 0 + 200 + 20", 0, a.sync.driftFixCount[Deck.B] ?: 0)
        a.port.d(Deck.B).posMs += 150 // 300 off
        repeat(2) { advance(MixSyncTunables.HEARTBEAT_MS); b.sync.tick(); net.pump() }
        assertEquals(1, a.sync.driftFixCount[Deck.B] ?: 0)
    }

    @Test fun aStaleBeatIsNeverTrustedForACorrection() {
        val (a, b) = twoDeviceMix()
        loadAndPlayA(a, b)
        advance(MixSyncTunables.START_LEAD_MS)
        val shared = b.session.sharedNow()!!
        val sid = "s1"
        fun staleBeat(ageMs: Double) = MixSyncBeat("A", sid, MixSyncAnchor(a.port.playhead(Deck.A) + 900, shared - ageMs, true), b.sync.core.model.epoch, 0.0)
        repeat(4) {
            advance(MixSyncTunables.DRIFT_COOLDOWN_MS)
            b.sync.core.receive(envOf(MixWireKind.BEAT, json.encodeToString(MixSyncBeat.serializer(), staleBeat(1_501.0))), "A")
        }
        assertEquals("beats older than 1.5 s are ignored", 0, b.sync.driftFixCount[Deck.A] ?: 0)
        repeat(2) {
            advance(MixSyncTunables.DRIFT_COOLDOWN_MS)
            val s = b.session.sharedNow()!!
            val fresh = MixSyncBeat("A", sid, MixSyncAnchor(a.port.playhead(Deck.A) + 900, s, true), b.sync.core.model.epoch, 0.0)
            b.sync.core.receive(envOf(MixWireKind.BEAT, json.encodeToString(MixSyncBeat.serializer(), fresh)), "A")
        }
        assertEquals("a fresh beat does", 1, b.sync.driftFixCount[Deck.A] ?: 0)
    }

    @Test fun theCooldownHoldsASecondCorrectionBack() {
        val (a, b) = twoDeviceMix()
        loadAndPlayA(a, b)
        b.port.d(Deck.A).posMs += 600
        beat(a, b); beat(a, b)
        assertEquals(1, b.sync.driftFixCount[Deck.A] ?: 0)
        advance(MixSyncTunables.START_LEAD_MS)
        b.port.d(Deck.A).posMs += 600 // drifts again right away
        b.sync.core.receive(envOf(MixWireKind.BEAT, json.encodeToString(MixSyncBeat.serializer(),
            MixSyncBeat("A", "s1", MixSyncAnchor(a.port.playhead(Deck.A), b.session.sharedNow(), true), b.sync.core.model.epoch, 0.0))), "A")
        b.sync.core.receive(envOf(MixWireKind.BEAT, json.encodeToString(MixSyncBeat.serializer(),
            MixSyncBeat("A", "s1", MixSyncAnchor(a.port.playhead(Deck.A), b.session.sharedNow(), true), b.sync.core.model.epoch, 0.0))), "A")
        assertEquals("2 strikes but still inside the 4 s cooldown", 1, b.sync.driftFixCount[Deck.A] ?: 0)
        advance(MixSyncTunables.DRIFT_COOLDOWN_MS)
        b.sync.core.receive(envOf(MixWireKind.BEAT, json.encodeToString(MixSyncBeat.serializer(),
            MixSyncBeat("A", "s1", MixSyncAnchor(a.port.playhead(Deck.A), b.session.sharedNow(), true), b.sync.core.model.epoch, 0.0))), "A")
        assertEquals(2, b.sync.driftFixCount[Deck.A] ?: 0)
    }

    @Test fun everyDeviceTakesTheAnchorFromTheOwnersBeat() {
        val (a, b) = twoDeviceMix()
        b.port.userLoad(Deck.B, "s2"); net.pump()
        b.port.userPlay(Deck.B, 0); net.pump()
        a.port.userLoad(Deck.A, "s1"); net.pump()
        a.port.userPlay(Deck.A, 0); net.pump()
        advance(MixSyncTunables.HEARTBEAT_MS)
        a.sync.tick(); b.sync.tick(); net.pump()
        val fromA = lastSent(a, MixWireKind.BEAT, MixSyncBeat.serializer())
        val fromB = lastSent(b, MixWireKind.BEAT, MixSyncBeat.serializer())
        assertEquals("A", fromA?.deck); assertEquals("B", fromB?.deck)
        assertEquals("a non-host folds the owner's beat in too", fromA?.anchor, b.sync.core.model.deck(Deck.A).anchor)
        assertEquals(fromB?.anchor, a.sync.core.model.deck(Deck.B).anchor)
        assertEquals("the owner reports 1/2 its RTT", 1.0, fromB?.uncertaintyMs ?: -1.0, 1e-9)
        assertEquals("the host's clock is exact", 0.0, fromA?.uncertaintyMs ?: -1.0, 1e-9)
        assertEquals("the owner's own mirror carries its beat too", fromA?.anchor, a.sync.core.model.deck(Deck.A).anchor)
    }

    // ---------------- sounding / readiness / held starts ----------------

    @Test fun ownerProposesPlayOnlyOnceSoundingAndHostHoldTimesOut() {
        val (a, b) = twoDeviceMix()
        b.port.loadsReady = false // B's deck is still buffering
        b.port.userLoad(Deck.B, "s2"); net.pump()
        assertEquals("s2", a.port.d(Deck.B).songId)
        b.port.userPlay(Deck.B, 0); net.pump()
        assertFalse(
            "a buffering owner doesn't anchor everyone to a playhead that isn't moving",
            sentKinds("B", MixWireKind.EVENT).any { it.third.decode(MixSyncEventMessage.serializer())?.event?.kind == "play" },
        )
        assertTrue(a.port.plays.isEmpty())

        advance(1_500.0) // the bytes land 1.5 s later
        b.port.d(Deck.B).at = b.now() // the held playhead starts moving only now
        b.port.d(Deck.B).ready = true
        b.sync.tick(); net.pump() // ready -> the start is proposed NOW
        assertEquals(1, a.port.plays.size)
        advance(MixSyncTunables.START_LEAD_MS)
        assertEquals("others start where the owner really is", b.port.playhead(Deck.B), a.port.playhead(Deck.B))

        // An owner that proposes while still loading (an older build): the host holds it, then times out and starts anyway.
        b.port.userLoad(Deck.B, "s3"); net.pump()
        assertEquals("s3", a.port.d(Deck.B).songId)
        assertEquals(MixSyncReady.Status.LOADING, a.sync.core.peerReadiness["B"]?.get("B")?.status)
        val old = MixSyncEventMessage(10_000, event = MixSyncEvent(MixSyncKind.PLAY, deck = "B", anchor = MixSyncAnchor(0, clock.t, true)))
        a.sync.core.receive(envOf(MixWireKind.EVENT, json.encodeToString(MixSyncEventMessage.serializer(), old)), "B")
        assertEquals("held for the owner's ready report", 1, a.port.plays.size)
        advance(MixSyncTunables.READY_TIMEOUT_MS)
        a.sync.tick()
        assertEquals(2, a.port.plays.size)
    }

    @Test fun aReadyReportReleasesAHeldStartBeforeTheTimeout() {
        val (a, b) = twoDeviceMix()
        b.port.loadsReady = false
        b.port.userLoad(Deck.B, "s2"); net.pump()
        val old = MixSyncEventMessage(10_000, event = MixSyncEvent(MixSyncKind.PLAY, deck = "B", anchor = MixSyncAnchor(0, clock.t, true)))
        a.sync.core.receive(envOf(MixWireKind.EVENT, json.encodeToString(MixSyncEventMessage.serializer(), old)), "B")
        assertTrue(a.port.plays.isEmpty())
        b.port.d(Deck.B).ready = true
        b.sync.tick(); net.pump() // reports READY: the host releases the held start at once
        assertEquals(1, a.port.plays.size)
    }

    @Test fun unavailableSongStaysSilentAndIsReported() {
        val a = dev("A"); net.hostId = "A"; a.sync.tick()
        val b = dev("B", unmixable = setOf("s9")); join(b, a)
        a.sync.start(); net.pump()
        assertTrue(b.sync.isActive)
        b.port.userLoad(Deck.A, "old") // a stale local deck (not a deck B owns): repaired, never proposed
        a.port.userLoad(Deck.A, "s9"); net.pump()
        assertEquals("T-s9", b.sync.unavailable[Deck.A])
        assertNull("an unmixable song leaves the deck empty (silent) here", b.port.d(Deck.A).songId)
        assertEquals(MixSyncReady.Status.UNAVAILABLE, a.sync.core.peerReadiness["B"]?.get("A")?.status)
        assertEquals(listOf("Dev B"), a.sync.unavailableDevices(Deck.A))
        a.port.userPlay(Deck.A); net.pump()
        assertTrue("nothing to start on a deck this device can't mix", b.port.plays.isEmpty())
        assertEquals(listOf("this device"), b.sync.unavailableDevices(Deck.A))
        // the UI words
        assertEquals("“T-s9” isn’t available on this device — this deck stays silent here.", MixTogetherCopy.deckNote(b.sync.ui.value, Deck.A))
        assertEquals("Silent on Dev B", MixTogetherCopy.deckNote(a.sync.ui.value, Deck.A))
        b.sync.tick() // a repair pass must not resurrect it
        assertNull(b.port.d(Deck.A).songId)
    }

    @Test fun anUnmixableSongFollowedByAMixableOneClearsTheNote() {
        val a = dev("A"); net.hostId = "A"; a.sync.tick()
        val b = dev("B", unmixable = setOf("s9")); join(b, a)
        a.sync.start(); net.pump()
        a.port.userLoad(Deck.A, "s9"); net.pump()
        assertNotNull(b.sync.unavailable[Deck.A])
        a.port.userLoad(Deck.A, "s1"); net.pump()
        assertNull(b.sync.unavailable[Deck.A])
        assertEquals("s1", b.port.d(Deck.A).songId)
        assertEquals(MixSyncReady.Status.READY, a.sync.core.peerReadiness["B"]?.get("A")?.status)
    }

    // ---------------- system causes stay local ----------------

    @Test fun systemPauseStaysLocalHoldsAndRejoinsAtTheAnchor() {
        val (a, b) = twoDeviceMix()
        loadAndPlayA(a, b)
        advance(MixSyncTunables.START_LEAD_MS)

        // B's lock screen / an interruption pauses B's copy of A's deck: this device only.
        val eventsBefore = sentCount(b, MixWireKind.EVENT)
        b.port.systemPause(Deck.A)
        b.sync.tick()
        assertEquals("a system pause is never proposed", eventsBefore, sentCount(b, MixWireKind.EVENT))
        assertTrue(Deck.A in b.sync.systemHeld)
        assertEquals(setOf(Deck.A), b.sync.ui.value.systemHeld)
        repeat(3) { beat(a, b) } // neither the repair loop nor the drift loop restarts it
        assertFalse("no repair while the system holds it (mid-call)", b.port.d(Deck.A).isPlaying)
        assertTrue("the owner never heard about it", a.port.d(Deck.A).isPlaying)
        assertEquals(1, b.port.plays.size)

        // The system resumes: B REJOINS at the anchored position, not where it stopped.
        b.port.systemPlay(Deck.A)
        b.sync.tick()
        assertFalse(Deck.A in b.sync.systemHeld)
        advance(MixSyncTunables.START_LEAD_MS)
        assertEquals(a.port.playhead(Deck.A), b.port.playhead(Deck.A))

        // The OWNER's own system pause: local to it; others keep playing, no heartbeat goes out.
        val beatsBefore = sentCount(a, MixWireKind.BEAT)
        a.port.systemPause(Deck.A)
        advance(MixSyncTunables.HEARTBEAT_MS)
        a.sync.tick(); net.pump()
        assertTrue(b.port.d(Deck.A).isPlaying)
        assertEquals("a held deck is nobody's reference", beatsBefore, sentCount(a, MixWireKind.BEAT))
        assertTrue(a.sync.core.model.deck(Deck.A).anchor?.isPlaying == true)

        // Engine housekeeping is ignored outright (not shared, not repaired).
        b.port.userLoad(Deck.B, "s2"); net.pump()
        b.port.userPlay(Deck.B); net.pump()
        val bEvents = sentCount(b, MixWireKind.EVENT)
        b.port.enginePause(Deck.B)
        b.sync.tick()
        assertEquals(bEvents, sentCount(b, MixWireKind.EVENT))
        assertTrue(b.sync.systemHeld.isEmpty())
    }

    @Test fun anyOwnPlayOrRejoinBringsBackEveryHeldDeck() {
        val (a, b) = twoDeviceMix()
        loadAndPlayA(a, b)
        advance(MixSyncTunables.START_LEAD_MS)
        b.port.userLoad(Deck.B, "s2"); net.pump()
        b.port.userPlay(Deck.B, 0); net.pump()
        b.sync.tick()

        // An interruption pauses both decks HERE (B's copy of A's deck + B's own).
        b.port.systemPause(Deck.A)
        b.port.systemPause(Deck.B)
        assertEquals(setOf(Deck.A, Deck.B), b.sync.systemHeld)
        b.sync.tick()
        assertFalse(b.port.d(Deck.A).isPlaying)

        // B presses play on ITS deck: the other DJ's deck rejoins too.
        b.port.userPlay(Deck.B)
        assertTrue(b.sync.systemHeld.isEmpty())
        b.sync.tick()
        assertTrue("the read-only deck rejoined with the DJ's own play", b.port.d(Deck.A).isPlaying)
        advance(MixSyncTunables.START_LEAD_MS)
        assertEquals("at the anchored position", a.port.playhead(Deck.A), b.port.playhead(Deck.A))

        // ...and the banner's Rejoin does it with no deck play at all.
        b.port.systemPause(Deck.A)
        assertEquals(setOf(Deck.A), b.sync.systemHeld)
        b.sync.rejoin()
        assertTrue(b.sync.systemHeld.isEmpty())
        assertTrue(b.port.d(Deck.A).isPlaying)
    }

    @Test fun aSystemPausedDeckIgnoresTheSessionsTransportUntilItRejoins() {
        val (a, b) = twoDeviceMix()
        loadAndPlayA(a, b)
        advance(MixSyncTunables.START_LEAD_MS)
        b.port.systemPause(Deck.A)
        a.port.userPause(Deck.A); net.pump()
        a.port.userPlay(Deck.A, 5_000); net.pump()
        assertEquals("never restarted mid-call", 1, b.port.plays.size)
        b.sync.rejoin()
        assertEquals(2, b.port.plays.size)
        assertTrue(b.port.d(Deck.A).isPlaying)
    }

    // ---------------- ownership: only the owner's gestures travel ----------------

    @Test fun aGestureOnADeckYouDontOwnIsRevertedAndNeverProposed() {
        val (a, b) = twoDeviceMix()
        a.port.userLoad(Deck.A, "s1"); net.pump()
        val before = sentCount(b, MixWireKind.EVENT)
        b.port.userSet("volume", Deck.A, 0.1)
        assertEquals(before, sentCount(b, MixWireKind.EVENT))
        b.sync.tick()
        assertNull("the deck's board is reconciled to the session's", b.port.value("volume", Deck.A))
        assertTrue(b.sync.canControl(Deck.B)); assertFalse(b.sync.canControl(Deck.A))
    }

    @Test fun continuousGesturesAreCoalescedWithATrailingSend() {
        val (a, b) = twoDeviceMix()
        b.port.userLoad(Deck.B, "s2"); net.pump()
        val before = sentCount(b, MixWireKind.EVENT)
        for (i in 1..10) b.port.userSet("volume", Deck.B, i / 10.0) // one drag burst
        assertEquals("the first move goes at once", before + 1, sentCount(b, MixWireKind.EVENT))
        advance(MixSyncTunables.CONTINUOUS_INTERVAL_MS)
        b.sync.tick()
        assertEquals("then ONE trailing send", before + 2, sentCount(b, MixWireKind.EVENT))
        net.pump()
        assertEquals(1.0, a.port.value("volume", Deck.B) ?: -1.0, 0.0)
    }

    @Test fun concurrentCrossfaderConvergesAndSnapshotsApplyTheCrossfader() {
        val (a, b) = twoDeviceMix()
        b.port.crossfader = 0.9
        b.port.tap(Gesture("crossfader", null, value = 0.9)); net.pump()
        assertEquals(0.9, a.port.crossfader, 1e-9)
        val c = dev("C"); join(c, a)
        net.pump()
        assertEquals("a joiner takes the session's crossfader from the snapshot", 0.9, c.port.crossfader, 1e-9)
    }

    // ---------------- loops ----------------

    @Test fun loopSyncsTheExactWindowAndJoinersSeekBeforeLooping() {
        val (a, b) = twoDeviceMix()
        a.port.userLoad(Deck.A, "s1"); net.pump()
        a.port.userPlay(Deck.A, 10_000); net.pump()
        assertEquals(1, b.port.plays.size)
        advance(MixSyncTunables.START_LEAD_MS + 500) // both at 10 800
        a.port.userLoop(Deck.A, 10_500, 11_500); net.pump()
        assertEquals("the owner's window, not one around B's playhead", 10_500 to 11_500, b.port.d(Deck.A).loop)
        advance(3_333.0)
        assertEquals("same phase inside the same window", a.port.playhead(Deck.A), b.port.playhead(Deck.A))
        repeat(3) { beat(a, b) } // in phase -> the drift loop leaves a looping deck alone
        assertEquals(0, b.sync.driftFixCount[Deck.A] ?: 0)

        // Out of phase on a looping deck IS drift (compared inside the window, the short way round).
        b.port.d(Deck.A).posMs += 150
        repeat(2) { beat(a, b) }
        assertEquals(1, b.sync.driftFixCount[Deck.A] ?: 0)

        // A late joiner: anchor (seek) FIRST, then the exact window, never a loop near 0:00.
        val c = dev("C"); join(c, a); net.pump()
        assertNotNull(c.port.d(Deck.A).loop)
        val iPlay = c.port.applied.indexOfFirst { it.startsWith("play:A") }
        val iLoop = c.port.applied.indexOf("loop:A:10500-11500")
        assertTrue(iPlay >= 0 && iLoop >= 0)
        assertTrue("play before loop", iPlay < iLoop)
        advance(MixSyncTunables.START_LEAD_MS)
        assertEquals(a.port.playhead(Deck.A), c.port.playhead(Deck.A))
    }

    @Test fun aScrubOnALoopingDeckSharesTheNewWindowFirst() {
        val (a, b) = twoDeviceMix()
        a.port.userLoad(Deck.A, "s1"); net.pump()
        a.port.userPlay(Deck.A, 10_000); net.pump()
        a.port.userLoop(Deck.A, 10_500, 11_500); net.pump()
        a.port.d(Deck.A).loop = 20_000 to 21_000
        a.port.tap(Gesture(MixSyncKind.SEEK, Deck.A, posMs = 20_200))
        net.pump()
        val kinds = sentKinds("A", MixWireKind.EVENT).mapNotNull { it.third.decode(MixSyncEventMessage.serializer())?.event?.kind }
            .filter { it == MixSyncKind.LOOP || it == MixSyncKind.SEEK }
        assertEquals(listOf(MixSyncKind.LOOP, MixSyncKind.SEEK), kinds.takeLast(2))
        assertEquals("the receivers' window moved before the seek landed", 20_000 to 21_000, b.port.d(Deck.A).loop)
    }

    // ---------------- seed / reconcile ----------------

    @Test fun seedCarriesTheWholeBoardAndReconcileResetsUnlistedControls() {
        val a = dev("A"); net.hostId = "A"; a.sync.tick()
        val b = dev("B"); join(b, a)
        a.port.d(Deck.A).songId = "s1"
        a.port.seeds[Deck.A] = listOf(
            MixSyncEvent(MixSyncKind.LOAD, deck = "A", songId = "s1", title = "T-s1"),
            MixSyncEvent(MixSyncKind.TEMPO, deck = "A", value = 1.05),
            MixSyncEvent("eq", deck = "A", param = "low", value = -6.0),
            MixSyncEvent("effectToggle", deck = "A", param = "reverb", flag = true, slot = 1),
            MixSyncEvent("stemMode", deck = "A", flag = true),
            MixSyncEvent(MixSyncKind.PAUSE, deck = "A", anchor = MixSyncAnchor(4_000, null, false)),
        )
        // B's own pre-session board on deck A must not survive the session's load.
        b.port.d(Deck.A).controls["eq:A:high"] = MixSyncEvent("eq", deck = "A", param = "high", value = 9.0)
        a.sync.start(); net.pump()
        assertTrue(b.sync.isActive)
        assertEquals("s1", b.port.d(Deck.A).songId)
        assertEquals(-6.0, b.port.d(Deck.A).controls["eq:A:low"]?.value ?: 0.0, 0.0)
        assertEquals(true, b.port.d(Deck.A).controls["effectToggle:A:#1"]?.flag)
        assertEquals(true, b.port.d(Deck.A).controls["stemMode:A:"]?.flag)
        assertEquals(1.05, b.port.d(Deck.A).rate, 0.0)
        assertNull("a joiner's load takes the SESSION's board", b.port.d(Deck.A).controls["eq:A:high"])
        assertEquals(4_000, b.port.playhead(Deck.A))
        assertEquals("the host's own seeded load is mirrored in its localSong", 1, a.startedHook.size)

        // A stray local change on a deck B doesn't own is fully reverted, including a control the session never set.
        b.port.userSet("volume", Deck.A, 0.1)
        b.port.userSet("tempo", Deck.A, 1.3)
        b.sync.tick()
        assertNull("an unlisted control goes back to default", b.port.value("volume", Deck.A))
        assertEquals(1.05, b.port.d(Deck.A).controls["rate:A"]?.value ?: 0.0, 0.0)
        assertEquals("no stray tempo left to trip the drift loop", 1.05, b.port.d(Deck.A).rate, 0.0)
    }

    @Test fun sessionStartBlocksAutoDjAndSuspendsPersistenceUntilItEnds() {
        val (a, b) = twoDeviceMix()
        assertEquals(MixSyncTunables.AUTO_DJ_BLOCKED_REASON, a.port.blockedReason)
        assertEquals(MixSyncTunables.AUTO_DJ_BLOCKED_REASON, b.port.blockedReason)
        assertTrue(a.port.sessionActive && b.port.sessionActive)
        a.sync.end(); net.pump()
        assertNull(a.port.blockedReason); assertNull(b.port.blockedReason)
        assertFalse(a.port.sessionActive || b.port.sessionActive)
        assertFalse(b.sync.ui.value.active)
    }

    @Test fun endingTheMixReturnsAnInFlightNudgeToTheDecksOwnTempo() {
        val (a, b) = twoDeviceMix()
        loadAndPlayA(a, b)
        b.port.d(Deck.A).posMs += 120
        beat(a, b); beat(a, b)
        assertEquals(1 - MixSyncTunables.NUDGE_RATE, b.port.nudges.last().second, 1e-9)
        a.sync.end(); net.pump()
        assertEquals(1.0, b.port.nudges.last().second, 0.0)
    }

    @Test fun endingTheMixClearsTheLocalSongAndDriftBookkeeping() {
        val (a, b) = twoDeviceMix()
        loadAndPlayA(a, b)
        beat(a, b); beat(a, b)
        fun field(name: String): Map<*, *> =
            b.sync.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(b.sync) as Map<*, *>
        assertTrue(field("localSong").isNotEmpty())
        a.sync.end(); net.pump()
        assertTrue("a stale song id would read as loaded in the next mix", field("localSong").isEmpty())
        assertTrue(field("lastBeatAt").isEmpty())
        assertTrue(field("lastDriftFixAt").isEmpty())
    }

    // ---------------- ui state ----------------

    @Test fun uiStateTracksOwnersLabelsAndTheStartGate() {
        val a = dev("A"); net.hostId = "A"; a.sync.tick()
        val b = dev("B"); join(b, a)
        assertTrue(a.sync.ui.value.let { it.canStart && !it.active })
        assertEquals(false, b.sync.ui.value.canStart)
        assertEquals("Only the session host can start a mix.", b.sync.ui.value.startBlockedReason)
        a.sync.start(); net.pump()
        val ui = a.sync.ui.value
        assertTrue(ui.active)
        assertEquals(mapOf(Deck.A to "A", Deck.B to "B"), ui.owners)
        assertEquals(mapOf(Deck.A to "You", Deck.B to "Dev B"), ui.ownerLabels)
        assertEquals(listOf(Deck.A), ui.myDecks)
        assertEquals(listOf("You", "Dev B"), ui.participantNames)
        assertEquals(setOf(Deck.A), ui.controllable)
        val bu = b.sync.ui.value
        assertEquals(listOf("Dev A", "You"), bu.participantNames)
        assertEquals(listOf(Deck.B), bu.myDecks)
        // claim / release
        b.sync.release(Deck.B); net.pump()
        assertEquals("Free", b.sync.ui.value.ownerLabels[Deck.B])
        assertFalse(Deck.B in b.sync.ui.value.controllable)
        a.sync.claim(Deck.B); net.pump()
        assertEquals("You", a.sync.ui.value.ownerLabels[Deck.B])
        assertEquals(listOf(Deck.A, Deck.B), a.sync.ui.value.myDecks)
    }

    @Test fun theMixEndsHereWhenTheRemoteSessionIsGoneAndTheDecksKeepTheirSongs() {
        val (a, b) = twoDeviceMix()
        a.port.userLoad(Deck.A, "s1"); net.pump()
        assertTrue(b.sync.isActive)
        b.live = false
        b.sync.tick()
        assertFalse(b.sync.isActive)
        assertNull(b.port.blockedReason)
        assertFalse(b.port.sessionActive)
        assertEquals("the decks keep playing locally", "s1", b.port.d(Deck.A).songId)
        assertFalse(b.sync.ui.value.active)
    }

    @Test fun uiCopyMatchesIos() {
        assertEquals("Mixing together", MixTogetherCopy.BANNER_TITLE)
        assertEquals("Paused on this device", MixTogetherCopy.PAUSED_HERE)
        assertEquals("Rejoin", MixTogetherCopy.REJOIN)
        assertEquals("No deck — claim one", MixTogetherCopy.yourDeckBanner(emptyList()))
        assertEquals("Your deck: A + B", MixTogetherCopy.yourDeckBanner(listOf(Deck.A, Deck.B)))
        assertEquals("None — claim a free deck in Mix", MixTogetherCopy.yourDeckSection(emptyList()))
        assertEquals("Deck A + Deck B", MixTogetherCopy.yourDeckSection(listOf(Deck.A, Deck.B)))
        assertEquals("Only the session host can start a mix.", MixTogetherCopy.footer("Only the session host can start a mix.", false))
        assertTrue(MixTogetherCopy.footer(null, false).startsWith("Two DJs, two decks"))
        assertTrue(MixTogetherCopy.footer(null, true).startsWith("Open the Mix tab."))
        assertEquals("“X” isn’t available on this device — this deck stays silent here.", MixTogetherCopy.unavailableHere("X"))
        assertEquals("Silent on Sam, Alex", MixTogetherCopy.silentOn(listOf("Sam", "Alex")))
        assertNull(MixTogetherCopy.deckNote(MixSyncUi(), Deck.A))
    }

    @Test fun installAdvertisesTheMixCapabilityAndBuildsTheDriverWhenASessionAttaches() = kotlinx.coroutines.test.runTest {
        assertTrue(com.levi.pocketdj.ParityFlags.MIX_TOGETHER)
        val c = com.levi.pocketdj.remote.RemoteSessionController(
            null, com.levi.pocketdj.remote.RemoteSongResolver(catalogItem = { com.levi.pocketdj.playback.sequencer.QueueItem(id = it) }),
            { "Dev" }, "test", com.levi.pocketdj.remote.SharedClock { 1.0 }, backgroundScope,
        )
        val z = dev("Z")
        var built = 0
        MixTogetherInstaller.install(c, build = { built++; z.sync }, ifBuilt = { if (built > 0) z.sync else null })
        assertEquals(listOf("mix"), c.localCaps)
        assertEquals(0, built)
        c.attach(com.levi.pocketdj.remote.LoopbackHub().join("Z"), com.levi.pocketdj.remote.RemoteSessionMode.LISTEN_TOGETHER, asHost = true, autoTick = false)
        assertEquals("the driver is built when a session goes live", 1, built)
    }
}
