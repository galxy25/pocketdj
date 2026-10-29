package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.data.rips.PlayAction
import kotlinx.coroutines.CancellationException

/**
 * Q36 safety net: a game row (runTag != null) that the ladder routed to the Apple Music SDK but
 * whose start FAILED (lapsed subscription, region lock, 10 s confirm timeout) degrades to the cached
 * 30 s preview instead of throwing (which would make the sequencer skip the row). Ordinary rows
 * keep the old throw-and-advance behaviour. A null preview rethrows the original failure.
 */
class GamePreviewFallbackPort(
    private val delegate: PlayerPort,
    private val previewUrl: suspend (songId: String) -> String?,
) : PlayerPort by delegate {
    override suspend fun load(request: PlayRequest) {
        if (request.source !is AppleMusicSource || request.item.runTag == null) return delegate.load(request)
        try {
            delegate.load(request)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val url = runCatching { previewUrl(request.item.id) }.getOrNull() ?: throw e
            delegate.load(request.copy(source = StreamSource(PlayAction.Stream(url))))
        }
    }
}
