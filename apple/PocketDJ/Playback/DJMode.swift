import Foundation

/// Now Playing DJ Mode (docs/design/np-dj-mode.md). Session state on `SetlistPlayer`, a sibling of
/// Mix Mode's `NPMixModeState`; persisted in the playback snapshot as an optional `djMode`.
struct DJModeState: Codable, Equatable {
    var enabled = false
    /// The selector's wave + pocket position (`DJSetPlanner.State`, seeded per session) — rides the
    /// snapshot so a restored session keeps building the same wave. Optional: nil until the first
    /// plan (and in snapshots written before it existed).
    var planner: DJSetPlanner.State? = nil
}

/// The Settings ▸ DJ Mode toggles as one value (np-dj-mode §6). Every part defaults ON; the
/// player reads this through its `djModeSettings` closure (like `mixModeSettings`), and the
/// toggles MASK parts of the orchestration off — they never change the shared Mix-tab timings.
struct DJModeSettings: Equatable, Sendable {
    /// DJ transitions (crossfade orchestration). Off ⇒ every advance is a normal advance.
    var transitions = true
    /// FX texture sweep during a transition. Off ⇒ no texture.
    var effectSweeps = true
    /// Tempo meet-in-the-middle. Off ⇒ rate targets 1.
    var tempoMatch = true
    /// ±1 key pitch bend. Off ⇒ pitch 0.
    var keyMatch = true
    /// Loudness leveling toward `LoudnessLeveling.targetLufs`.
    var volumeLeveling = true
    /// The selector's 10-BPM tempo waves.
    var tempoWaves = true
    /// The selector's genre / year / collection pockets.
    var pockets = true

    static let allOn = DJModeSettings()

    /// The selector-facing subset (`DJSetPlanner.Options`). Key fit in the planner follows
    /// `keyMatch` — the "Key/pitch match" toggle governs both the bend and key-aware ordering.
    var plannerOptions: DJSetPlanner.Options {
        DJSetPlanner.Options(tempoWaves: tempoWaves, pockets: pockets, key: keyMatch)
    }
}

enum DJMode {
    /// The `[dj]` DiagLog lane (song ids only, never titles) + the Now Playing trace — plan,
    /// transition start / decline reasons, leveling gains.
    @MainActor
    static func log(_ message: String) {
        DiagLog.shared.log("dj", message)
        NPLog.trace("dj \(message)")
    }
}

// MARK: - Integration values (np-dj-mode §1 / §2 / §4 / §7)

extension DJMode {
    /// The shared Mix-tab transition lengths DJ Mode reuses (Settings ▸ Mix: lead, fade, glide —
    /// np-dj-mode §2). The toggles mask parts off; these never change per mode.
    struct Timings: Equatable, Sendable {
        /// `autoMixLeadSeconds` — a transition may begin with this much (or less) left.
        var lead: Double = 15
        /// `autoMixFadeSeconds` — the equal-power crossfade.
        var fade: Double = 3
        /// `mixGlideSeconds` — the glide pre-roll ceiling and the post-roll length.
        var glide: Double = 10
    }

    /// The catalog facts the selector + the transition read for one song — all optional
    /// (np-dj-mode §4 "Features, all optional"). `genre` is the RAW album genre (the planner maps
    /// it through `Genre.category`); `year` is the song's, else its album's.
    struct SongFacts: Equatable, Sendable {
        var bpm: Double?
        var camelot: String?
        var genre: String?
        var year: Int?

        init(bpm: Double? = nil, camelot: String? = nil, genre: String? = nil, year: Int? = nil) {
            self.bpm = bpm; self.camelot = camelot; self.genre = genre; self.year = year
        }
    }

    /// Song id → the ids of every collection it belongs to, inverted from the flattened membership
    /// (`CollectionFlattener` via `ListeningPocketsCollections.flattened`). Pure, off-main safe.
    nonisolated static func membership(_ collections: [CollectionFlattener.Collection]) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for c in collections {
            for id in c.songIds { out[id, default: []].insert(c.id) }
        }
        return out
    }

    /// What the Now Playing Mix panel's DJ status shows (np-dj-mode §7).
    enum Indicator: Equatable {
        case off
        /// A Mix-tab session is live: DJ Mode waits (np-dj-mode §1, like Mix Mode).
        case suspended
        /// A Remote (SharePlay Listen Together / Backseat) session is attached: DJ Mode waits
        /// until it ends (np-dj-mode §9).
        case suspendedRemote
        /// This song's end won't mix (the words say why: transitions off, repeating, an album
        /// playing through, the set repeats, …) — the same reasons the decision declines on.
        case noMix(String)
        /// A DJ transition is in flight (pre-roll, crossfade or post-roll).
        case mixing
        /// The next row is a complete local file — the end of this song mixes into it.
        case nextReady
        /// The next row is still becoming local (byte progress 0…1 when known).
        case bufferingNext(Double?)
        /// Nothing queued after this song.
        case lastTrack

        var chipText: String? {
            switch self {
            case .off: return nil
            case .suspended: return "DJ — paused while the Mix tab plays"
            case .suspendedRemote: return "DJ — paused · SharePlay session"
            case .noMix(let why): return "DJ — \(why)"
            case .mixing: return "DJ — mixing"
            case .nextReady: return "DJ — next mixes in"
            case .bufferingNext(let f):
                guard let f else { return "DJ — buffering next" }
                return "DJ — buffering next \(Int((min(1, max(0, f)) * 100).rounded()))%"
            case .lastTrack: return "DJ — last song"
            }
        }

        /// Re-read on a timer while true (byte progress isn't observable).
        var isBuffering: Bool { if case .bufferingNext = self { return true } else { return false } }
    }
}
