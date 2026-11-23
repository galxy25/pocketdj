package com.levi.pocketdj.playback

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/**
 * FR1 (iOS `supersedePendingPlay`): run an Apple Music start so that a CANCELLATION (stall hop, skip, supersede)
 * is never swallowed and never leaves the SDK preparing. [abort] runs in a [NonCancellable] block - it stops the
 * SDK, clears the pending confirm/current and restores the prior backend - then the cancellation is rethrown.
 * Any other failure is a plain `false` (the caller's preview fallback). Pure so the JVM can pin it.
 */
internal suspend fun runCancellableAppleMusicStart(
    play: suspend () -> Boolean,
    abort: suspend () -> Unit,
): Boolean = try {
    play()
} catch (e: CancellationException) {
    withContext(NonCancellable) { abort() }
    throw e
} catch (e: Exception) {
    false
}
