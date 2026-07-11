import Foundation

/// Runs on-device AUDIO ANALYSIS on a performance item when it enters a collection, so Mix mode has
/// what it needs to mix it: the beat grid (derived from the item's KNOWN bpm — see
/// `StudioStore.mixInfo`) and the musical KEY (Camelot) for harmonic glide. The beat grid needs no
/// computation (the bpm is already exact); the KEY is detected here via `KeyDetector`:
///   • instrumentals — from their EXACT MIDI notes;
///   • samples / loops / sequences — from an on-device chromagram of their rendered audio.
/// Idempotent + lazy: a no-op once a key is stored. Pairs with `StudioTakeRenderer.ensureRendered`
/// (an instrumental must have real audio before it — and Mix — can play it).
@MainActor
enum StudioAnalyzer {
    /// Prepare a performance item for a collection: render an instrumental's real audio (needs its
    /// pack), then detect + store its key. `packs` is required only for `tk_`; pass nil for audio
    /// items. Fire-and-forget from an "Add to…" action.
    static func prepare(forStudioId id: String, studio: StudioStore, packs: InstrumentPackStore?) async {
        if id.hasPrefix("tk_"), let packs {
            await StudioTakeRenderer.ensureRendered(takeId: id, studio: studio, packs: packs)
        }
        await ensureKey(forStudioId: id, studio: studio)
    }

    /// Detect + store a performance item's key (Camelot) if not already known. No-op when already
    /// analyzed, or when an audio item's file can't be resolved yet (a placeholder instrumental that
    /// hasn't rendered — call after `ensureRendered`).
    static func ensureKey(forStudioId id: String, studio: StudioStore) async {
        guard studio.camelot(forStudioId: id) == nil else { return }
        // Instrumental: EXACT key straight from the played notes — no audio decode needed.
        if id.hasPrefix("tk_") {
            if let take = studio.take(id), let r = KeyDetector.detect(noteEvents: take.scoreEvents) {
                studio.setCamelot(r.camelot, forStudioId: id)
            }
            return
        }
        // Audio item: chromagram of the resolved local file (decode + FFT off the main actor). The
        // security scope is held across the decode, then released.
        guard let handle = studio.localURLForPlayback(id: id) else { return }
        let url = handle.url
        let release = handle.release
        let camelot: String? = await Task.detached(priority: .utility) {
            guard let buf = try? StudioRender.decodeFileSync(url: url) else { return nil }
            return KeyDetector.detect(audio: buf)?.camelot
        }.value
        release?()
        if let camelot { studio.setCamelot(camelot, forStudioId: id) }
    }
}
