package com.levi.pocketdj.playback.sequencer

/** A row streamed by the Apple Music SDK's own engine (full track; device-only). */
data class AppleMusicSource(val appleMusicId: String, val songId: String) : RowSource {
    override val backend: String get() = "appleMusic"
}

/**
 * Rung 3 of the ladder (after local file and manifest rip, before rip-on-demand): an Apple Music
 * row inside a run plays through the SDK when the engine can run here (arm ABI + signed in + token).
 * On the emulator / signed-out [canPlayFullTrack] is false and this rung returns null, so the row
 * falls through: rip-on-demand for ordinary rows, the 30 s preview for game rows (the adapter is never constructed there).
 *
 * iOS `ripStartsNow`: when a manifest rip makes the row start instantly, an Apple Music rung defers
 * unless the row is Apple-Music-sourced ([isAppleMusicSourced]).
 */
class AppleMusicRowResolver(
    private val appleMusicIdFor: (QueueItem) -> String?,
    private val canPlayFullTrack: suspend () -> Boolean,
    private val isAppleMusicSourced: (QueueItem) -> Boolean = { false },
) : RowSourceResolver {
    override val id: String = "apple-music"
    override val rung: Rung = Rung.APPLE_MUSIC

    override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? {
        // Q36: game-run rows (runTag != null) are eligible like any other row. When the engine cannot run
        // (emulator / signed out) this returns null and the row falls to GamePreviewRowResolver (Rung.FALLBACK).
        // Game rows never reach the rip-on-demand rung (CloudRowResolver refuses runTag rows).
        val amId = appleMusicIdFor(item)?.takeIf { it.isNotBlank() } ?: return null
        if (ctx.ripStartsNow && !isAppleMusicSourced(item)) return null
        if (!canPlayFullTrack()) return null
        return AppleMusicSource(amId, item.id)
    }
}
