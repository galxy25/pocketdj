import Foundation

/// The Demuxer (Producer tab, sixth sub-tab) takes ONE audio source — a burned catalog track, a
/// Studio item (sample/loop/sequence/instrumental), or an imported file — and derives per-audio
/// metadata that renders on a scrubbable, time-synced overlay of the audio:
///   • the TRANSCRIPT (sung/spoken words with per-word timestamps — Apple Speech, ON DEVICE),
///   • the CHORD TIMELINE (dominant maj/min chords as timed segments — on-device chromagram),
///   • the four Demucs STEMS when they exist (drums + bass stems ARE the rhythm view).
/// Everything here is a value type persisted by `DemuxStore` under `demux-cache/<key>.json`
/// (the LyricsStore disk-cache pattern), keyed by the source's stable id.
let demuxSchemaVersion = 1

/// Feature gates for the Demuxer.
///
/// LYRICS ARE HIDDEN (Levi 2026-07-18): on-device SFSpeech recognition over music is too
/// sparse to ship — the macOS probe over a real song heard only 20 words on the full mix
/// and 34–42 on the isolated vocals stem (45% token recall). The panel returns when
/// transcription moves to a CLOUD or LOCAL-MODEL engine (Whisper-class) that is
/// time-synced to the track. The full pipeline underneath — DemuxTranscriber's windowed/
/// resumable recognition, DemuxStore's incremental run machine, the karaoke view, and all
/// their tests — stays live behind this gate, ready for the engine swap.
enum DemuxFeatures {
    /// Dev re-enable seam: launch with PDJ_DEMUX_LYRICS=1 (UI tests keep the hidden
    /// path AND the gated karaoke path verified).
    static var lyricsEnabled: Bool {
        ProcessInfo.processInfo.environment["PDJ_DEMUX_LYRICS"] == "1"
    }
}

// MARK: - Source identity

/// What the Demuxer is looking at. The `key` is the persistence identity: catalog songs use the
/// song id (so the document survives re-burns), Studio items their studio id, imported files a
/// content-derived id minted at copy-in time (`dmx_<uuid>`).
enum DemuxSource: Equatable {
    case song(id: String, title: String, artist: String)
    case studio(id: String, name: String)
    case file(id: String, name: String)

    var key: String {
        switch self {
        case .song(let id, _, _): return id
        case .studio(let id, _): return id
        case .file(let id, _):   return id
        }
    }

    var displayName: String {
        switch self {
        case .song(_, let t, let a): return a.isEmpty ? t : "\(a) — \(t)"
        case .studio(_, let n):      return n
        case .file(_, let n):        return n
        }
    }

    /// Only catalog songs can have server-side Demucs stems (the rip-server pipeline is keyed by
    /// song id); Studio items and imported files degrade to "no stems" gracefully.
    var songId: String? {
        if case .song(let id, _, _) = self { return id }
        return nil
    }
}

// MARK: - Transcript

/// One recognized word, timed against the audio's own clock (ms from 0:00 of the analyzed file).
struct DemuxWord: Codable, Equatable, Identifiable {
    var text: String
    var startMs: Int
    var endMs: Int
    var id: Int { startMs }
}

/// A display line: words grouped by silence gaps (karaoke-style rows on the overlay).
struct DemuxLine: Identifiable, Equatable {
    var words: [DemuxWord]
    var id: Int { words.first?.startMs ?? 0 }
    var startMs: Int { words.first?.startMs ?? 0 }
    var endMs: Int { words.last?.endMs ?? 0 }
    var text: String { words.map(\.text).joined(separator: " ") }

    /// Group words into lines at silence gaps ≥ `gapMs` (default 1.2 s — verse-ish phrasing),
    /// capping a line at `maxWords` so a wall-to-wall rap verse still wraps into readable rows.
    static func lines(from words: [DemuxWord], gapMs: Int = 1_200, maxWords: Int = 12) -> [DemuxLine] {
        var lines: [DemuxLine] = []
        var current: [DemuxWord] = []
        for w in words {
            if let last = current.last, w.startMs - last.endMs >= gapMs || current.count >= maxWords {
                lines.append(DemuxLine(words: current))
                current = []
            }
            current.append(w)
        }
        if !current.isEmpty { lines.append(DemuxLine(words: current)) }
        return lines
    }
}

// MARK: - Chords

/// One detected chord, held over [startMs, endMs). Maj/min triads only — the sweet spot of what a
/// chromagram resolves reliably on real mixes (extensions collapse onto their triad).
struct DemuxChordSegment: Codable, Equatable, Identifiable {
    /// Root pitch class, 0 = C … 11 = B.
    var rootPC: Int
    var minor: Bool
    var startMs: Int
    var endMs: Int
    /// Mean template-match score over the segment's frames, 0…1.
    var confidence: Double
    var id: Int { startMs }

    static let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    /// Chord symbol — "C", "F♯m", "B♭" …
    var name: String { Self.noteNames[((rootPC % 12) + 12) % 12] + (minor ? "m" : "") }

    /// Triad pitch classes (root, third, fifth) — the harmonic identity.
    var pitchClasses: [Int] {
        let r = ((rootPC % 12) + 12) % 12
        return [r, (r + (minor ? 3 : 4)) % 12, (r + 7) % 12]
    }

    /// Concrete MIDI notes for staff rendering: a close-position triad rooted in the octave
    /// starting at `base` (treble clef default C4=60; pass 48 for a bass-clef voicing).
    func midiNotes(base: Int = 60) -> [Int] {
        let r = base + ((rootPC - base) % 12 + 12) % 12
        return [r, r + (minor ? 3 : 4), r + 7]
    }

    /// Guitar voicing as 6 fret numbers, low-E → high-e (nil = string not played). Uses the
    /// movable E-form (major) / Em-form (minor) barre so EVERY root has a real shape; roots at
    /// E give the open-position chord (fret 0 barre = the nut).
    var guitarFrets: [Int?] {
        let barre = ((rootPC - 4) % 12 + 12) % 12   // E (pc 4) shape moved up to the root
        let shape = minor ? [0, 2, 2, 0, 0, 0] : [0, 2, 2, 1, 0, 0]
        return shape.map { $0 + barre }
    }

    /// Tab-style text of the voicing — "1-3-3-2-1-1" (low-E → high-e).
    var tabText: String { guitarFrets.map { $0.map(String.init) ?? "x" }.joined(separator: "-") }
}

// MARK: - Document (persisted)

/// Per-artifact lifecycle. `unavailable` is a terminal "can't on this device/source" (e.g. speech
/// recognition unsupported for the locale); `failed` is retryable. `running` is PERSISTED while
/// an analysis is in flight — a doc found `running` with no live run means the app died mid-run,
/// and the next kickoff RESUMES from `transcriptCoveredMs` instead of starting over.
enum DemuxArtifactStatus: String, Codable {
    case none, done, failed, unavailable, running
}

/// Everything the Demuxer derived for one audio source. One JSON file per source key.
struct DemuxDocument: Codable, Equatable {
    var schemaVersion: Int = demuxSchemaVersion
    var sourceKey: String
    var displayName: String
    var durationMs: Int = 0

    var transcriptStatus: DemuxArtifactStatus = .none
    var words: [DemuxWord] = []
    /// How far (ms into the FILE) transcription has progressed — words land per finished
    /// window, so a killed/suspended run resumes here instead of starting over. Optional so
    /// pre-existing cached docs (no key) still decode.
    var transcriptCoveredMs: Int?
    /// Human-readable note when a run was IMPERFECT (some windows failed) — surfaced next to
    /// the lyrics so a partial result is legible, and invaluable in field debugging.
    var transcriptDiag: String?

    var chordStatus: DemuxArtifactStatus = .none
    var chords: [DemuxChordSegment] = []

    /// For `.file` sources only: the copied-in audio's filename inside the demux-cache audio
    /// folder (catalog/Studio sources re-resolve their audio through their own stores).
    var importedFileName: String?

    init(sourceKey: String, displayName: String) {
        self.sourceKey = sourceKey
        self.displayName = displayName
    }
}
