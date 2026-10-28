package com.levi.pocketdj.mix.graph

import android.content.Context
import android.media.AudioManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.levi.pocketdj.audio.core.AudioTrackSink
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.audio.core.VoicePump
import com.levi.pocketdj.mix.model.Deck
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Proves the render thread runs on the emulator even with -no-audio (compile-verified only here). */
@RunWith(AndroidJUnit4::class)
class MixGraphSmokeInstrumentedTest {
    @Test fun tapPulseAdvancesWhileAToneRendersOnTheAudioTrackSink() {
        val am = InstrumentationRegistry.getInstrumentation().targetContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val sink = AudioTrackSink(am)
        val graph = MixGraph(sink.sampleRate)
        val total = 44_100L * 10
        val v = Voice(SyntheticPcmSource.tone(441.0, total, 44_100, 0.5f), 44_100).also { it.setLoop(0, total) }
        val pump = VoicePump(v).start()
        graph.setMain(Deck.A, v)
        ParamsComposer(graph).setCrossfader(0f)
        v.schedule(0); v.play()
        graph.attach(sink)
        try {
            Thread.sleep(500)
            val t1 = graph.pulse.lastAudibleAt
            Thread.sleep(1500)
            val t2 = graph.pulse.lastAudibleAt
            assertTrue("audible stamp must advance ($t1 -> $t2)", t1 > 0 && t2 > t1)
        } finally {
            sink.stop(); sink.release(); pump.stop()
        }
    }
}
