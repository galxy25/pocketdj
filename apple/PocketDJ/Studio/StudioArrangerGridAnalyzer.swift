import Foundation
import AVFoundation

/// Background, on-device BEAT-GRID analysis for the arranger's Beat Match mode. When clips are added
/// to an arrangement, each clip's source audio is analyzed (off the main actor, via the same
/// `BeatDetect` used by the sample/slice editors) to produce a `StudioGrid` (bpm + downbeat) cached on
/// the clip. Beat Match warps every clip so its detected tempo == the arrangement's master bpm and
/// snaps starts to the grid; until every clip is analyzed the Beat Match control stays greyed
/// ("Beat grid under construction" — see `StudioArrangement.beatGridReady`).
///
/// Idempotent + lazy: only clips with `grid == nil` are analyzed, and each result is written back
/// through the @MainActor store AFTER re-checking the clip still exists (a delete/trim between kickoff
/// and write-back must not resurrect it). A detection that returns nil (too short / quiet / aperiodic)
/// stores a zero-bpm SENTINEL grid so a single un-analyzable clip can't wedge the "ready" gate forever
/// — Beat Match simply leaves such clips un-warped. Fire-and-forget from `StudioStore.addClip`.
@MainActor
enum StudioArrangerGridAnalyzer {
    /// The sentinel written when detection fails — "analyzed, no usable tempo". `bpm == 0` means Beat
    /// Match leaves the clip at its natural rate (never warps it to a bogus tempo).
    static let unanalyzable = StudioGrid(bpm: 0)

    /// Analyze every not-yet-analyzed clip in an arrangement and cache each grid. Safe to call
    /// repeatedly (e.g. on each `addClip`) — already-analyzed clips are skipped.
    static func ensureGrids(forArrangement id: String, studio: StudioStore) async {
        guard let arr = studio.arrangement(id) else { return }
        // Snapshot the work up front (track id + clip id + file) so we don't hold a stale arrangement
        // value across the awaits; re-resolve from the store when writing back.
        let jobs: [(trackId: String, clipId: String, fileName: String)] = arr.tracks.flatMap { track in
            track.clips.filter { $0.grid == nil }.map { (track.id, $0.id, $0.fileName) }
        }
        guard !jobs.isEmpty else { return }

        for job in jobs {
            // Skip if it got analyzed by an overlapping run since the snapshot.
            guard clipNeedsGrid(id, trackId: job.trackId, clipId: job.clipId, studio: studio) else { continue }
            guard let url = studio.clipFileURL(job.fileName) else {
                // Unresolvable file → sentinel so `beatGridReady` can still open.
                studio.setClipGrid(arrangement: id, track: job.trackId, clip: job.clipId, unanalyzable)
                continue
            }
            let grid = await Task.detached(priority: .utility) {
                DrumPatternDetector.gridEstimate(url: url)
            }.value
            // Re-check existence before the write — the clip may have been deleted/trimmed mid-analyze.
            guard clipNeedsGrid(id, trackId: job.trackId, clipId: job.clipId, studio: studio) else { continue }
            studio.setClipGrid(arrangement: id, track: job.trackId, clip: job.clipId, grid ?? unanalyzable)
        }
    }

    private static func clipNeedsGrid(_ arrId: String, trackId: String, clipId: String,
                                      studio: StudioStore) -> Bool {
        guard let track = studio.arrangement(arrId)?.tracks.first(where: { $0.id == trackId }),
              let clip = track.clips.first(where: { $0.id == clipId }) else { return false }
        return clip.grid == nil
    }
}
