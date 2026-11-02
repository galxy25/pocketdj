import Foundation

/// NOW PLAYING MIX MODE (docs/design/np-mix-mode.md, phase 2) — "make the current and upcoming
/// rows LOCAL files so the F4 mini-panel (tempo / pitch / gain / FX / stems) works in any
/// playback session".
///
/// Mix Mode is SESSION state on `SetlistPlayer` (like the Stem Lock): persisted in the durable
/// session snapshot (`PlaybackSessionStore.Snapshot.npMixMode`), restored HELD (no buffering
/// until the first ▶), cleared by a new session (`play`) unless Settings ▸ "Start new sessions
/// in Mix Mode" is on, and by `stop()`.
///
/// What it does while ON:
///  • the Now Playing prefetch lane (`NowPlayingPrefetcher`) buffers the current row (when it is a
///    ripped stream) and the next rows — whole song, then stems — as TEMPORARY burns (phase-1
///    holds; they expire after the Settings TTL unless an explicit Download / Mix action pins
///    them), sized to the network (Wi-Fi: 3 ahead with stems; cellular: the next song; Low Data:
///    the current row only) and to the disk (free-space floor + the buffer cap);
///  • a current row streaming from its presigned rip URL moves onto the identical local file at
///    the same position once that file lands (`SetlistPlayer.handOffCurrentToLocal`, plain
///    AVPlayer — the DSP still engages on the first control TOUCH, Levi's Q2 default);
///  • it is SUSPENDED (buffering paused, chip "Paused — Mix tab is live") while a Mix-tab session
///    plays — one DSP surface at a time.
///
/// Phase 3: a ripped row that isn't local STARTS in the DSP on its growing buffer file (controls
/// live from the first second; "Buffering…" while it holds for bytes) — see `SetlistPlayer`
/// "Mix Mode phase 3".
///
/// Apple Music rows are not ripped or handed off yet (phase 4): they say so honestly
/// ("Apple Music only").
struct NPMixModeState: Codable, Equatable {
    var enabled = false
}

/// Settings ▸ Storage ▸ Mix Mode buffer: what Mix Mode downloads on a CELLULAR (expensive) path.
enum NPMixCellularPolicy: String, Codable, CaseIterable {
    /// Nothing beyond what the Stem Lock already fetches.
    case off
    /// The current row + the NEXT song (default). Stems only when asked for (Stem Lock / the
    /// Stems toggle on the playing track).
    case nextSong
    /// Like Wi-Fi: the whole window, stems included.
    case full

    var label: String {
        switch self {
        case .off: return "Off"
        case .nextSong: return "Next song only"
        case .full: return "Same as Wi-Fi"
        }
    }
}

enum NPMixMode {
    /// The `[npmix]` DiagLog lane (song ids only, never titles) + the Now Playing trace.
    @MainActor
    static func log(_ message: String) {
        DiagLog.shared.log("npmix", message)
        NPLog.trace("npmix \(message)")
    }

    /// The Settings ▸ "Buffer ahead" picker (rows past the current one, on Wi-Fi).
    static let bufferAheadOptions = [1, 3, 5, 10]
    static let defaultBufferAhead = 3

    /// The status chip on the Now Playing Mix panel header.
    enum Indicator: Equatable {
        /// Mix Mode off (no chip; the panel behaves exactly as F4).
        case off
        /// The current track is a local file — every control is live.
        case ready
        /// The DSP owns the audio.
        case engaged
        /// Phase 3: the DSP plays the row from its GROWING file and is holding for bytes (the
        /// playhead caught the download / a seek past it). Controls stay live. nil = size unknown.
        case holding(Double?)
        /// The current track's local copy is downloading (it plays from its stream meanwhile).
        /// nil = size not known yet.
        case buffering(Double?)
        /// The DSP is bringing the stems up.
        case stemsLoading
        /// Owner only: an Apple-Music-only row being ripped (phase 4 — never produced in phase 2).
        case ripping
        /// Nothing local can exist for this play ("Apple Music only", "Live capture", "Offline",
        /// "Download failed", "Storage full", "Not ripped").
        case unavailable(String)
        /// A Mix-tab session is live: buffering is paused (one DSP surface at a time).
        case suspended
        /// A restored (held) session: buffering starts on the first ▶.
        case waiting

        /// The chip's text (nil = no chip).
        var chipText: String? {
            switch self {
            case .off: return nil
            case .ready: return "Ready"
            case .engaged: return "Mixing"
            case let .holding(f): return f.map { "Buffering \(Int(($0 * 100).rounded(.down)))%" } ?? "Buffering…"
            case let .buffering(f): return f.map { "Buffering \(Int(($0 * 100).rounded(.down)))%" } ?? "Buffering…"
            case .stemsLoading: return "Loading stems…"
            case .ripping: return "Ripping — mixable next play"
            case let .unavailable(why): return why
            case .suspended: return "Paused — Mix tab is live"
            case .waiting: return "Buffers on ▶"
            }
        }

        /// The controls are usable (the current track is, or can be swapped onto, a local file).
        var controlsLive: Bool {
            switch self {
            case .ready, .engaged, .holding, .stemsLoading: return true
            default: return false
            }
        }

        /// The accessibility value of the chip (stable, for UI tests).
        var a11yValue: String {
            switch self {
            case .off: return "off"
            case .ready: return "ready"
            case .engaged: return "engaged"
            case .holding: return "holding"
            case .buffering: return "buffering"
            case .stemsLoading: return "stemsLoading"
            case .ripping: return "ripping"
            case .unavailable: return "unavailable"
            case .suspended: return "suspended"
            case .waiting: return "waiting"
            }
        }
    }

    /// The inputs the indicator is a pure function of (unit-tested table).
    struct IndicatorInput: Equatable {
        var enabled: Bool
        var running: Bool
        var held: Bool
        var mixTabLive: Bool
        var engaged: Bool
        var stemsLoading: Bool
        var mixable: Bool
        var onAppleMusic: Bool
        var live: Bool
        var offline: Bool
        var ripped: Bool
        var deviceMode: Bool
        var bufferFraction: Double?
        var buffering: Bool
        var failed: Bool
        var storageFull: Bool
        /// This network adds no Mix Mode downloads (cellular policy Off).
        var cellularOff: Bool = false
        /// Phase 3: the engaged DSP is holding its growing file for bytes.
        var dspHolding: Bool = false
    }

    /// THE CHIP. Order matters: "off" and "not running" first, then the session-wide states
    /// (held, suspended), then what the DSP is doing, then what the current track is.
    static func indicator(_ i: IndicatorInput) -> Indicator {
        guard i.enabled, i.running else { return .off }
        if i.held { return .waiting }
        if i.mixTabLive { return .suspended }
        if i.engaged {
            if i.dspHolding { return .holding(i.bufferFraction) }
            return i.stemsLoading ? .stemsLoading : .engaged
        }
        if i.mixable { return .ready }
        if i.onAppleMusic { return .unavailable("Apple Music only") }
        if i.live { return .unavailable("Live capture") }
        if i.storageFull { return .unavailable("Storage full") }
        if i.failed { return .unavailable("Download failed") }
        if i.buffering { return .buffering(i.bufferFraction) }
        if i.deviceMode { return .unavailable("Device mode — downloads only") }
        if i.offline { return .unavailable("Offline") }
        if !i.ripped { return .unavailable("Not ripped") }
        if i.cellularOff { return .unavailable("Cellular — buffering off") }
        return .buffering(i.bufferFraction)       // ripped + allowed: the lane is about to take it
    }

    /// One row of the buffer strip under the controls (● local · ◐ buffering · ○ queued ·
    /// ⨯ unavailable).
    struct BufferRow: Identifiable, Equatable {
        let id: UUID
        let title: String
        let dot: BufferDot
    }

    enum BufferDot: String, Equatable {
        case local, buffering, queued, unavailable

        var glyph: String {
            switch self {
            case .local: return "●"
            case .buffering: return "◐"
            case .queued: return "○"
            case .unavailable: return "⨯"
            }
        }
    }
}
