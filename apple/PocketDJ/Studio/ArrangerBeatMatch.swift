import Foundation

/// Pure Beat Match geometry, shared by BOTH arranger read paths — `MultitrackPlayer.play` (live) and
/// `ArrangerBouncer.plan` (bounce) — so a bounce can never drift from what plays (the two-read-path
/// WYSIWYG invariant). Beat Match warps every clip so its detected tempo == the master bpm and snaps
/// clip starts to the master beat grid; both operations live here as tiny testable functions.
enum ArrangerBeatMatch {
    /// The combined playback rate for a clip = the Beat-Match warp (master ÷ clip bpm) × the per-track
    /// tempo knob. `rate > 1` = faster/shorter. Beat Match off, or a clip with no usable grid
    /// (`clipBpm <= 0` — unanalyzed or the zero-bpm sentinel), contributes a warp of 1× so only the
    /// per-track tempo applies. Clamped to `AVAudioUnitTimePitch`'s legal 1/32…32 (transformBuffer
    /// clamps too, but keeping it here means the "needs a bake?" test upstream sees the real rate).
    static func rate(clipBpm: Double, masterBpm: Double, tempoRatio: Double, beatMatch: Bool) -> Double {
        let warp = (beatMatch && clipBpm > 0 && masterBpm > 0) ? masterBpm / clipBpm : 1
        return min(32, max(1.0 / 32, warp * tempoRatio))
    }

    /// Snap a clip's start frame to the nearest master beat when beat-matching (else unchanged). All
    /// clips share the master tempo once warped, so grid-aligned starts keep them locked beat-to-beat.
    static func snappedStartFrame(_ frame: Int, beatFrames: Double, beatMatch: Bool) -> Int {
        guard beatMatch, beatFrames > 0 else { return frame }
        return Int((Double(frame) / beatFrames).rounded() * beatFrames)
    }
}
