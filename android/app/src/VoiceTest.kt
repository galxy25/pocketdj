
class VoiceRegressionTest {
    private fun Voice.settle(rounds: Int = 6) {
        val scratch = FloatArray(2)
        repeat(rounds) { pump(); read(scratch, 0, Long.MIN_VALUE / 2); while (pump()) { } }
    }

    @Test fun monoAndResampledSourcesWithRoundedLengthReachEnded() {
        for ((rate, ch) in listOf(22_050 to 1, 32_000 to 2, 44_100 to 1)) {
            val v = Voice(SyntheticPcmSource(rate, ch, 1001) { f, _ -> f * 1e-4f })
            v.schedule(0); v.settle(); v.play()
            val out = FloatArray(4096 * 2)
            var st = v.read(out, 4096, 0)
            repeat(3) { v.settle(); st = v.read(out, 4096, 0) }
            assertEquals("rate=$rate ch=$ch", Voice.Status.ENDED, st)
        }
    }

    @Test fun setLoopRightAfterASeekUsesTheSeekTargetNotTheStalePosition() {
        val v = Voice(SyntheticPcmSource.counter(100_000))
        v.schedule(0); v.settle(); v.play()
        v.seek(5000)           // not yet acknowledged by the render thread
        v.setLoop(5000, 5100)
        v.settle()
        val out = FloatArray(10 * 2)
        v.read(out, 10, 0)
        assertEquals((5000L until 5010L).toList(), (0 until 10).map { SyntheticPcmSource.frameOf(out[2 * it]) })
    }

    @Test fun redundantSetLoopDoesNotFlushTheRing() {
        val v = Voice(SyntheticPcmSource.counter(100_000))
        v.schedule(1000); v.settle(); v.setLoop(1000, 1500); v.settle(); v.play()
        v.read(FloatArray(128), 64, 0)
        val before = v.bufferedFrames
        v.setLoop(1000, 1500)
        assertEquals(before, v.bufferedFrames)
        assertEquals(Voice.Status.PLAYING, v.read(FloatArray(128), 64, 64))
    }

    @Test fun gainRampStaysSmoothAcrossAScheduledStartLead() {
        val v = Voice(SyntheticPcmSource(44_100, 2, 100_000) { _, _ -> 1f })
        v.schedule(0); v.settle()
        v.setGain(0f)
        v.play(atRenderFrame = 100)
        val n = 256
        val a = FloatArray(n * 2); val b = FloatArray(n * 2)
        v.read(a, n, 0); v.read(b, n, n.toLong())
        val series = (100 until n).map { a[2 * it] } + (0 until n).map { b[2 * it] }
        var maxStep = 0f
        for (i in 1 until series.size) maxStep = maxOf(maxStep, kotlin.math.abs(series[i] - series[i - 1]))
        assertTrue("step $maxStep", maxStep <= 1f / n + 1e-5f)
    }
}
