import Foundation
import AVFoundation

/// Bakes a studio source (sample / loop / sequence / instrumental) into an IMMUTABLE arranger clip
/// snapshot — `clip-<id>.m4a` in the app-managed arrangements dir. Mirrors `StudioPatternBouncer` /
/// `StudioTakeRenderer` (a static `@MainActor` helper): first make the source offline-playable
/// (`StudioAnalyzer.prepare` bounces a dirty pattern / renders an un-rendered take — a no-op for
/// samples & loops), resolve its local file, then whole-file import → canonical AAC into the clip
/// file. The clip owns its audio forever, so later edits to (or deletion of) the source never touch
/// a placed clip — the locked "immutable snapshot" decision.
@MainActor
enum ArrangerClipBaker {
    /// Returns a ready-to-file `StudioClip` (audio already written to disk) positioned at `startMs`,
    /// or nil when the source can't be resolved/baked (a placeholder instrumental with no pack, a
    /// deleted source, a DRM file). The caller files it via `StudioStore.addClip`.
    static func bake(sourceId: String, kind: StudioClipSource, startMs: Int,
                     studio: StudioStore, packs: InstrumentPackStore?) async -> StudioClip? {
        // 1. Make the source offline-playable (bounces a dirty ptn_, renders an un-rendered tk_).
        await StudioAnalyzer.prepare(forStudioId: sourceId, studio: studio, packs: packs)
        // 2. Resolve its local file — HOLD the security scope across the read, release after.
        guard let handle = studio.localURLForPlayback(id: sourceId) else { return nil }
        let sourceURL = handle.url
        let title = handle.title
        // 3. Bake a snapshot into the arrangements dir (whole-file decode → canonical AAC).
        let clipId = StudioFactory.newClipId()
        let fileName = StudioStore.clipFileName(clipId)
        guard let dir = try? StudioStore.arrangementsDir() else { handle.release?(); return nil }
        let baked = try? await StudioRender.shared.importAudioFile(
            sourceURL: sourceURL, to: dir.appendingPathComponent(fileName))
        handle.release?()
        guard let baked, baked.durationMs > 0 else { return nil }
        return StudioClip(id: clipId, name: title, fileName: fileName, startMs: max(0, startMs),
                          durationMs: baked.durationMs, source: kind, sourceId: sourceId,
                          createdAt: Date().timeIntervalSince1970 * 1000)
    }
}
