import Foundation
import AVFoundation

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
        // 1. BURN it to offline-playable audio so it plays the moment it's in the collection: an
        //    instrumental renders its notes; a sequence bounces its pattern (a dirty/un-bounced
        //    sequence resolves to nil in playback — the "couldn't play until I bounced it" bug).
        //    Loops + samples already carry a rendered/raw file.
        if id.hasPrefix("tk_"), let packs {
            await StudioTakeRenderer.ensureRendered(takeId: id, studio: studio, packs: packs)
        } else if id.hasPrefix("ptn_") {
            await StudioPatternBouncer.ensureBounced(patternId: id, studio: studio)
        }
        // 2. Detect + store its key for Mix glide (uses the burned audio for sequences/audio items).
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

// MARK: - Sequence bounce (burn a pattern to offline audio)

/// Bounces a sequencer pattern to offline audio (`pattern-<id>.m4a`) so it's immediately playable
/// in a collection — the automatic version of the sequencer's "Bounce for offline" button. A
/// dirty / never-bounced pattern resolves to nil in `localURLForPlayback`, so without this an
/// added sequence silently skips until the user bounces it by hand. Shares the view's buffer-prep
/// + `StudioRender.bouncePattern` recipe.
@MainActor
enum StudioPatternBouncer {
    static func ensureBounced(patternId: String, studio: StudioStore) async {
        guard let pattern = studio.pattern(patternId) else { return }
        if pattern.fileName != nil, !pattern.bounceDirty { return }   // already bounced + fresh
        // Pre-render each active row's buffer, keyed by TARGET id (bouncePattern's contract),
        // deduped so a sample used twice decodes once.
        var buffers: [String: AVAudioPCMBuffer] = [:]
        for row in pattern.rows.prefix(StudioEngine.maxPatternRows) where !row.isSilent {
            guard studio.targetExists(row.targetId), buffers[row.targetId] == nil else { continue }
            if let buf = await preparedBuffer(for: row.targetId, studio: studio) {
                buffers[row.targetId] = buf
            }
        }
        guard !buffers.isEmpty else { return }   // nothing sounding → nothing to bounce
        let bm = studio.bookmark(for: .sequences)
        guard let dest = StudioFolders.folder(.sequences, bookmark: bm) else { return }
        defer { dest.release?() }
        let name = StudioFolders.fileName(.sequences, id: patternId)
        do {
            _ = try await StudioRender.shared.bouncePattern(pattern, buffers: buffers,
                                                            to: dest.url.appendingPathComponent(name))
            // Bless the bounce only if the pattern still matches what was rendered (an edit
            // mid-render would leave the file stale — the sequencer's own guard).
            if let now = studio.pattern(patternId), now.rows == pattern.rows, now.bpm == pattern.bpm {
                studio.setPatternBounced(patternId, fileName: name, wasUserFolder: dest.isUserFolder)
            }
        } catch { /* silent — the sequencer's Bounce button surfaces failures interactively */ }
    }

    /// Decode a loop/sample target into a PCM buffer for the bounce (the sequencer's `preparedBuffer`
    /// minus the sample edit-bake — the raw/rendered file is what collection playback uses anyway).
    private static func preparedBuffer(for targetId: String, studio: StudioStore) async -> AVAudioPCMBuffer? {
        guard let got = studio.localURLForPlayback(id: targetId) else { return nil }
        let decoded = try? await StudioRender.shared.decodeBuffer(url: got.url)
        got.release?()
        guard let decoded else { return nil }
        if targetId.hasPrefix("lp_"), let loop = studio.loop(targetId), loop.frames > 0 {
            return StudioAudio.trimmedOrPadded(decoded, to: loop.frames)   // exact loop length (seamless)
        }
        return decoded
    }
}
