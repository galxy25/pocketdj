import Foundation

/// On-disk schema version for the mix-sessions document (bump on a breaking change).
/// v2 adds `MixSession.recordings` (captured mix audio) — additive + optional, so a v1 doc
/// decodes unchanged (missing key ⇒ nil).
let mixSessionsSchemaVersion = 2

// MARK: - Event model

/// One recorded mix action, time-stamped RELATIVE to its session's start (`tMs`). The set is rich
/// enough to (a) render a human replay timeline and (b) reconstruct a mix for training a model —
/// so a `.load` carries the track's bpm/camelot, and every deck-scoped event carries the deck's
/// playhead (`posMs`) at the moment it fired.
struct MixSessionEvent: Identifiable, Codable, Hashable, Sendable {
    var id: String            // unique within its session (monotonic "e<seq>")
    var tMs: Int              // ms since the session's (re-anchored) start
    var kind: MixEventKind
    var deck: String?         // "A" / "B"; nil = a global action (crossfader)
    var songId: String?
    var title: String?
    var artist: String?
    var bpm: Double?          // load only
    var camelot: String?      // load only
    var param: String?        // effect or stem name (e.g. "reverb", "vocals")
    var value: Double?        // numeric payload (rate, semitones, 0…2 volume, 0…1 strength, seconds…)
    var flag: Bool?           // on/off, muted/unmuted, lead-set/cleared
    var posMs: Int?           // the deck's playhead (ms) when the event fired (deck events only)
    /// `.glide` only — the ramp's START value (`value` holds the END); optional so pre-glide docs
    /// decode unchanged.
    var fromValue: Double? = nil
    /// `.glide` only — the ramp's average rate of change (END−START units per second).
    var rate: Double? = nil
}

/// The kinds of recorded mix activity. `unknown(raw)` is the lenient-decode sink so an unrecognized
/// rawValue (e.g. a newer build's event read by an older one) never throws away the whole corpus —
/// and it CARRIES the original string so it round-trips intact: an older build that loads, then
/// re-saves, a file with a future kind preserves that kind rather than flattening it to "unknown".
enum MixEventKind: Codable, Hashable, Sendable {
    case load, play, pause, seek
    case tempo, pitch, volume, crossfader
    case effectToggle, effectStrength
    case stemMode, stemMute, stemVolume
    case lead, sync, resetDeck
    /// A machine (auto-mix) parametric RAMP compactly captured as from→to + average rate of change
    /// (`fromValue`/`value`/`rate`) — a lossless stand-in for a linear sweep that would otherwise be
    /// ~100 sampled points. `param` names what ramped: "tempo"/"pitch"/"crossfader"/an effect name.
    /// (Manual moves stay sampled per-change under their own kinds — a human's moves aren't linear.)
    case glide
    case unknown(String)

    private static let known: [String: MixEventKind] = [
        "load": .load, "play": .play, "pause": .pause, "seek": .seek,
        "tempo": .tempo, "pitch": .pitch, "volume": .volume, "crossfader": .crossfader,
        "effectToggle": .effectToggle, "effectStrength": .effectStrength,
        "stemMode": .stemMode, "stemMute": .stemMute, "stemVolume": .stemVolume,
        "lead": .lead, "sync": .sync, "resetDeck": .resetDeck, "glide": .glide,
    ]

    var rawValue: String {
        switch self {
        case .load: return "load";           case .play: return "play"
        case .pause: return "pause";          case .seek: return "seek"
        case .tempo: return "tempo";          case .pitch: return "pitch"
        case .volume: return "volume";        case .crossfader: return "crossfader"
        case .effectToggle: return "effectToggle"; case .effectStrength: return "effectStrength"
        case .stemMode: return "stemMode";    case .stemMute: return "stemMute"
        case .stemVolume: return "stemVolume"; case .lead: return "lead"
        case .sync: return "sync";            case .resetDeck: return "resetDeck"
        case .glide: return "glide"
        case .unknown(let raw): return raw
        }
    }

    var isUnknown: Bool { if case .unknown = self { return true } else { return false } }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.known[raw] ?? .unknown(raw)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Slider-drag-driven kinds that fire continuously: coalesced to ~one event / 120 ms bucket and
    /// saved on a debounce (vs. discrete kinds, which append + save immediately).
    var isContinuous: Bool {
        switch self {
        case .tempo, .pitch, .volume, .crossfader, .effectStrength, .stemVolume: return true
        default: return false
        }
    }
}

// MARK: - Recording model

/// One captured audio recording of a mix session — the mixed house output written to the session's
/// FOLDER (`mix-sessions/<sessionId>/`, or the user-picked session folder). A session can hold more
/// than one take. The file lives on disk under the session folder; this is only its lightweight
/// metadata (so the Sessions screen can list + play recordings without touching disk).
struct MixRecording: Identifiable, Codable, Hashable, Sendable {
    var id: String            // unique within its session ("rec<seq>")
    var fileName: String      // the audio file's name WITHIN the session folder (e.g. "recording-1.m4a")
    var startedAt: Double     // epoch ms when capture began
    var durationMs: Int       // capture length (wall-clock)
    /// Where the session folder lived when this was written: true ⇒ the user-picked session folder
    /// (resolve via its security-scoped bookmark), false ⇒ app-managed Application Support storage.
    /// Mirrors `BurnItem.wasAppStorage` so a recording resolves from the dir it was ACTUALLY written to.
    var wasUserFolder: Bool
}

// MARK: - Session model

/// A recording of one mix "session" — it lasts until the user hits Reset, which finalizes it
/// (`endedAt`) and starts a fresh one. `events`/`playedSongIds` are the SAVED snapshot; for the
/// CURRENT session the live truth lives in the store's hot buffer and is folded in on save/reset.
struct MixSession: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var startedAt: Double           // epoch ms — the timeline's t0 (re-anchored to first activity)
    var endedAt: Double?            // set when the session is finalized (a new one begins)
    var events: [MixSessionEvent]
    var playedSongIds: [String]     // ordered, unique — songs whose playback started this session
    /// Captured mix audio for this session (0+ takes). Optional so a v1 doc (no key) decodes as nil;
    /// treat nil as "no recordings" everywhere via the non-optional accessor below.
    var recordings: [MixRecording]? = nil

    /// The session's recordings, nil-coalesced (a v1 doc / a session with no takes ⇒ []).
    var recordingsList: [MixRecording] { recordings ?? [] }

    /// Wall-clock length (ms): finalized → endedAt−startedAt; else the last event's tMs.
    var durationMs: Int {
        if let endedAt { return max(0, Int(endedAt - startedAt)) }
        return events.last?.tMs ?? 0
    }
}

/// The versioned persistence envelope (mirrors `CollectionsDocument`).
struct MixSessionsDocument: Codable, Sendable {
    var schemaVersion: Int = mixSessionsSchemaVersion
    var sessions: [MixSession] = []
    var currentId: String?
    var counter: Int = 0            // monotonic "Session N" allocator (survives rename/delete/relaunch)
}

// MARK: - Recorder seam

/// The narrow sink `MixEngine` emits into. The engine describes WHAT happened; the store owns the
/// timeline (t0, tMs), coalescing, the played-set, and persistence. Weakly held by the engine, so
/// recording is a no-op until a store is wired (and in tests).
@MainActor
protocol MixSessionRecorder: AnyObject {
    func logEvent(_ kind: MixEventKind, deck: String?, songId: String?, title: String?,
                  artist: String?, bpm: Double?, camelot: String?, param: String?,
                  value: Double?, flag: Bool?, posMs: Int?)
    /// A compact `.glide` ramp (auto-mix machine sweep). `deck`/`posMs` are nil for a global param
    /// (the crossfader).
    func logGlide(deck: String?, param: String, songId: String?, title: String?, artist: String?,
                  from: Double, to: Double, rate: Double, posMs: Int?)
    func notePlayed(songId: String)
}

// MARK: - Navigation routes (shared by RootView, MixView, MixSessionsView)

/// Push target for the sessions LIST (the Mix tab's "Sessions" button / title menu).
struct MixSessionsRoute: Hashable {}
/// Push target for one session's replay timeline.
struct MixSessionRoute: Hashable { let sessionId: String }
