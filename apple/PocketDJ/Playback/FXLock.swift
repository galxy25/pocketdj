import Foundation


/// FX LOCK — "keep my effects across tracks" for a Now Playing playback SESSION (the sibling of
/// `StemLock`; np-mix-mode §10).
///
/// Off (the default): the Now Playing mini-mix controls reset on every track change, exactly as
/// before (`NowPlayingDSP` controls are ephemeral; Levi's Q9). On: the EFFECTS state of the track
/// that is playing — every effect the panel's Effects group offers (comp / reverb / flanger /
/// filter), each one's on/off and its strength (the knob that drives its wet/dry and parameters)
/// — CARRIES to every following track. Tempo, pitch and gain do NOT carry: they still reset per
/// track. The carry is captured from USER effect actions only (`NowPlayingDSP.onUserEffectChange`).
///
/// Effects need the DSP to own the audio. With the lock carrying at least one effect that is ON,
/// a track that CAN be mixed (a local file, a Mix Mode growing file) engages the DSP at its start
/// — the same engage-at-start the Stem Lock does — and the carried effects RAMP IN
/// (`NowPlayingDSP.fxRampSeconds`) so a boundary never pops. A track the DSP can't own (an Apple
/// Music stream, a plain cloud stream, a live capture) plays dry under an honest "waiting"
/// indicator and the lock carries on; the effects come up the moment the DSP takes that track
/// over (a control touch, a Mix Mode swap-on-land, the Apple Music touch hand-off). While a
/// Mix-tab session is live the lock is DORMANT (one DSP surface at a time), like the Stem Lock.
///
/// SESSION scope, exactly like the Stem Lock: persisted in the durable session snapshot
/// (`PlaybackSessionStore.Snapshot.fxLock`), restored with it, cleared by a new session (a fresh
/// `SetlistPlayer.play`) and by `stop()`.
enum FXLock {
    /// One `fxlock` line: the remote DiagLog stream (song ids only, never titles) + the Now
    /// Playing trace (os_log `nowplaying`, Settings ▸ Debug capture).
    @MainActor
    static func log(_ message: String) {
        DiagLog.shared.log("fxlock", message)
        NPLog.trace("fxlock \(message)")
    }

    /// What the Now Playing surfaces show for the lock on the CURRENT track.
    enum Indicator: Equatable {
        /// The lock is off.
        case off
        /// Locked, carrying no effect that is on (or nothing playing yet): nothing to apply.
        case idle
        /// Locked with effects, and the DSP owns this track: the carried effects are on air.
        case applied
        /// Locked with effects, but THIS track plays outside the DSP (Apple Music / a plain
        /// stream / a live capture): dry for now — applied once the DSP takes it over.
        case waiting
        /// Locked with effects while a Mix-tab session is live: dormant (one DSP surface).
        case dormant
    }
}

/// The persisted FX Lock state of a session (the carried effects ride with it).
struct FXLockState: Codable, Equatable {
    /// One carried effect.
    struct Setting: Codable, Equatable {
        var on: Bool
        /// 0…1 — the panel's strength knob (`NowPlayingDSP.setEffectStrength`).
        var strength: Double
    }

    var enabled = false
    /// `MixEngine.Effect.rawValue` → its carried setting. Only effects moved off neutral (on, or a
    /// strength the listener set) are listed; an absent effect is off at the default strength.
    /// Unknown keys (an effect a newer build added) are kept on disk and ignored on apply.
    var effects: [String: Setting] = [:]

    init(enabled: Bool = false, effects: [String: Setting] = [:]) {
        self.enabled = enabled
        self.effects = effects
    }

    /// Lock on AND at least one carried effect ON: the only state that changes playback (it
    /// engages the DSP at a mixable track's start) or downloads (the next tracks' songs).
    var wantsFX: Bool { enabled && effects.values.contains { $0.on } }

    /// One-line summary for DiagLog (`fx=reverb:0.70,filter:0.30` — on effects only, sorted).
    var logSummary: String {
        let on = effects.filter { $0.value.on }.keys.sorted()
        guard !on.isEmpty else { return "fx=none" }
        return "fx=" + on.map { "\($0):\(String(format: "%.2f", effects[$0]?.strength ?? 0.5))" }.joined(separator: ",")
    }

    // Forward-tolerant decoding: a missing key decodes as its default (no schema bump ever).
    private enum CodingKeys: String, CodingKey { case enabled, effects }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        effects = try c.decodeIfPresent([String: Setting].self, forKey: .effects) ?? [:]
    }
}
