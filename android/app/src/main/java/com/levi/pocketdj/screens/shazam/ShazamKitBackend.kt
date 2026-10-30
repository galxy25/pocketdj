package com.levi.pocketdj.screens.shazam

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import com.levi.pocketdj.data.applemusic.MusicKitDeveloperTokenClient
import com.shazam.shazamkit.AudioSampleRateInHz
import com.shazam.shazamkit.DeveloperToken
import com.shazam.shazamkit.DeveloperTokenProvider
import com.shazam.shazamkit.MatchResult
import com.shazam.shazamkit.ShazamKit
import com.shazam.shazamkit.ShazamKitResult
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/** Terminal-ish outcome of one streamed query, free of ShazamKit types (testable with fakes). */
sealed interface StreamOutcome {
    data class Match(val info: ShazamHitInfo?) : StreamOutcome
    data object NoMatch : StreamOutcome
    data class Error(val message: String) : StreamOutcome
}

/** The slice of ShazamKit's StreamingSession the backend needs. */
interface ShazamStream {
    fun matchStream(audio: ByteArray, meaningfulLength: Int, timestampMs: Long)
    fun outcomes(): Flow<StreamOutcome>
}

/** Thrown by a [PcmSource] whose microphone could not be opened (held by a call, rejected params). */
class MicUnavailableException : IllegalStateException("Microphone unavailable. Is another app or a call using it?")

/** PCM16 mono source (AudioRecord in production). read returns bytes, <= 0 on failure/end. */
interface PcmSource {
    val bufferSize: Int
    fun start()
    fun read(buffer: ByteArray): Int
    fun release()
}

/** Pure driver: feed mic chunks into the stream until the first terminal outcome or timeout. */
object ShazamStreamDriver {
    const val DEFAULT_TIMEOUT_MS = 12_000L

    /** Bytes of PCM16 mono audio -> milliseconds at [sampleRate]. */
    fun durationMs(bytes: Long, sampleRate: Int): Long = bytes * 1000L / (sampleRate * 2L)

    suspend fun run(
        stream: ShazamStream,
        pcm: PcmSource,
        sampleRate: Int = 48_000,
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
        ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    ): RecognitionResult {
        val results = Channel<StreamOutcome>(Channel.UNLIMITED)
        try {
            return withTimeout(timeoutMs) {
                coroutineScope {
                    val collector = launch {
                        stream.outcomes().collect { results.trySend(it) }
                    }
                    val feeder = launch(ioDispatcher) {
                        try { pcm.start() } catch (e: CancellationException) { throw e } catch (t: Throwable) {
                            results.trySend(StreamOutcome.Error(t.message ?: "Microphone unavailable"))
                            return@launch
                        }
                        val buf = ByteArray(pcm.bufferSize.coerceAtLeast(1024))
                        var total = 0L
                        while (isActive) {
                            val n = pcm.read(buf)
                            if (n <= 0) {
                                results.trySend(StreamOutcome.Error("Microphone read failed ($n)"))
                                break
                            }
                            stream.matchStream(buf, n, durationMs(total, sampleRate))
                            total += n
                        }
                    }
                    val first = results.receive()
                    collector.cancel(); feeder.cancel()
                    when (first) {
                        is StreamOutcome.Match -> first.info?.let { RecognitionResult.Hit(it) } ?: RecognitionResult.NoMatch
                        StreamOutcome.NoMatch -> RecognitionResult.NoMatch
                        is StreamOutcome.Error -> RecognitionResult.Error(first.message)
                    }
                }
            }
        } catch (_: TimeoutCancellationException) {
            return RecognitionResult.NoMatch
        } finally {
            withContext(kotlinx.coroutines.NonCancellable) { runCatching { pcm.release() } }
        }
    }
}

/** MediaItem fields -> hit info. [artwork] etc. are plain strings so tests need no ShazamKit types. */
fun hitInfoOf(title: String?, artist: String?, artwork: String?, appleMusicId: String?): ShazamHitInfo =
    ShazamHitInfo(title?.takeIf { it.isNotBlank() }, artist?.takeIf { it.isNotBlank() }, artwork, appleMusicId?.takeIf { it.isNotBlank() })

/**
 * Live recognizer: shazam catalog (developer token = rip-server /musickit-token, shared with MusicKit) +
 * StreamingSession fed by AudioRecord 48 kHz mono PCM16. Device-only; the logic lives in [ShazamStreamDriver].
 */
class ShazamKitBackend(
    private val tokens: MusicKitDeveloperTokenClient,
    private val timeoutMs: Long = ShazamStreamDriver.DEFAULT_TIMEOUT_MS,
    private val sessionFactory: suspend (DeveloperTokenProvider) -> ShazamStream = ::createRealStream,
    private val pcmFactory: () -> PcmSource = { AudioRecordPcm() },
) : RecognitionBackend {

    override suspend fun recognize(): RecognitionResult {
        // The SDK callback is synchronous: warm the token first (cached after the first call).
        val token = try { tokens.developerToken() } catch (e: CancellationException) { throw e } catch (t: Throwable) {
            return RecognitionResult.Error("Couldn’t reach the import server for a Shazam token. Check Settings.")
        }
        val provider = DeveloperTokenProvider { DeveloperToken(tokens.cachedTokenOrNull() ?: token) }
        val stream = try { sessionFactory(provider) } catch (e: CancellationException) { throw e } catch (t: Throwable) {
            return RecognitionResult.Error(t.message ?: "Couldn’t start recognition")
        }
        return ShazamStreamDriver.run(stream, pcmFactory(), SAMPLE_RATE, timeoutMs)
    }

    companion object {
        const val SAMPLE_RATE = 48_000

        suspend fun createRealStream(provider: DeveloperTokenProvider): ShazamStream {
            val catalog = ShazamKit.createShazamCatalog(provider, Locale.getDefault())
            val size = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
                .coerceAtLeast(4096)
            return when (val r = ShazamKit.createStreamingSession(catalog, AudioSampleRateInHz.SAMPLE_RATE_48000, size)) {
                is ShazamKitResult.Success -> RealStream(r.data)
                is ShazamKitResult.Failure -> error(r.reason.message ?: "Shazam session failed")
            }
        }
    }
}

private class RealStream(private val s: com.shazam.shazamkit.StreamingSession) : ShazamStream {
    override fun matchStream(audio: ByteArray, meaningfulLength: Int, timestampMs: Long) =
        s.matchStream(audio, meaningfulLength, timestampMs)

    override fun outcomes(): Flow<StreamOutcome> = kotlinx.coroutines.flow.flow {
        s.recognitionResults().collect { r ->
            emit(
                when (r) {
                    is MatchResult.Match -> {
                        val m = r.matchedMediaItems.firstOrNull()
                        StreamOutcome.Match(m?.let { hitInfoOf(it.title, it.artist, it.artworkURL?.toString(), it.appleMusicID) })
                    }
                    is MatchResult.NoMatch -> StreamOutcome.NoMatch
                    is MatchResult.Error -> StreamOutcome.Error(r.exception.message ?: "Recognition failed")
                },
            )
        }
    }
}

@SuppressLint("MissingPermission") // the UI layer gates on MicPermission before recognize()
private class AudioRecordPcm : PcmSource {
    private val size = AudioRecord.getMinBufferSize(
        ShazamKitBackend.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
    ).coerceAtLeast(4096)
    private val rec = AudioRecord(
        MediaRecorder.AudioSource.MIC,
        ShazamKitBackend.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, size * 2,
    )
    override val bufferSize: Int get() = size
    override fun start() {
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw MicUnavailableException()
        }
        rec.startRecording()
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) throw MicUnavailableException()
    }
    override fun read(buffer: ByteArray): Int = rec.read(buffer, 0, buffer.size)
    override fun release() { runCatching { rec.stop() }; rec.release() }
}
