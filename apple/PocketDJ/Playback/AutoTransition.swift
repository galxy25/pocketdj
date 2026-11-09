import Foundation

/// AUTO TRANSITION — the decisions that define what an Auto-DJ transition IS, factored out of the
/// Mix tab's state machine (`MixEngine.beginAdvanceTransition` / `beginImmediateTransition` /
/// `beginGlideTransition` / `glidePhaseAlign` / `crossfadeFactor`) so the Mix decks and the Now
/// Playing DJ Mode conductor (docs/design/np-dj-mode.md §2) mix EXACTLY the same way. Shared, not
/// copied — like `GrowingFileSchedule` and `StemSync`. Pure functions on value inputs; no engine
/// state, no actor isolation (callable from any context).
///
/// What lives here:
///  • TIMING — the fade cap, glide pre-roll fit (with tempo headroom) and post-roll → `Plan`.
///  • TEMPO / PITCH — `glideParams` (octave-folded beat-match split + ±1-key Camelot bend).
///  • FX TEXTURE — `rollTexture` / `fxSeed` / `splitmix64`: filter / reverb / flanger at 0.5–0.8,
///    the same texture held for 3–5 transitions.
///  • RAMPS — the pre-roll (outgoing in) and post-roll (incoming back to natural) linear ramps.
///  • PHASE ALIGN — the incoming start offset that lands its beat phase on the outgoing's.
///  • CURVE — the equal-power cosine crossfade law.
///
/// The engines own everything stateful: WHEN to begin (the lead window + readiness), the clocks,
/// the decks/graph, and how a ramp value is applied.
enum AutoTransition {

    // MARK: Ranges (the Mix deck's — `MixEngine.rateRange` / `pitchRange` forward here)

    /// Tempo multiplier range (time-stretch, pitch preserved). 1.0 = original.
    static let rateRange: ClosedRange<Double> = 0.5...2.0
    /// Pitch range in semitones (frequency shift, tempo preserved). 0 = original.
    static let pitchRange: ClosedRange<Double> = -12...12

    // MARK: - Timing

    /// Mix Glide bends the OUTGOING deck's tempo up to ~+10%, so it consumes audio faster than
    /// wall-clock: the pre-roll fit divides the runway by this when Mix Glide (tempo/pitch) is on.
    static let glideTempoHeadroom: Double = 1.12
    /// Floor for a fade capped to a short runway (an advance with < fade seconds left).
    static let minRunwayFadeSeconds: Double = 0.5
    /// Floor for a one-off skip / hand-over fade.
    static let minImmediateFadeSeconds: Double = 0.2
    /// Margin kept between the pre-roll + fade and the end of the outgoing audio.
    static let preRollMarginSeconds: Double = 0.3
    /// A pre-roll / post-roll at or under this is treated as none (snap instead of ramp).
    static let minRampSeconds: Double = 0.05

    /// The timing of ONE transition.
    struct Plan: Equatable {
        /// True when an FX or Mix glide shapes the transition (pre/post-roll ramps apply).
        var isGlide: Bool
        /// Pre-roll on the outgoing (glide ramps in before the volume sweep). 0 ⇒ none.
        var preRollSeconds: Double
        /// The crossfade length for THIS transition (possibly capped / overridden).
        var fadeSeconds: Double
        /// Post-roll on the incoming (glide eases back to natural). 0 when not a glide.
        var postRollSeconds: Double
        /// When non-nil, the transition used a one-off fade: restore the configured fade to this
        /// baseline once the crossfade finishes. nil ⇒ nothing to restore (or a restore is
        /// already pending from an earlier override — the caller keeps that one).
        var fadeRestore: Double?

        /// A pre-roll long enough to ramp (else snap the outgoing glide + go straight to the fade).
        var hasPreRoll: Bool { preRollSeconds > AutoTransition.minRampSeconds }
        /// A post-roll long enough to ramp (else finish the glide at the fade's end).
        var hasPostRoll: Bool { isGlide && postRollSeconds > AutoTransition.minRampSeconds }
    }

    /// The tick's lead-window test: a transition into a ready next track may begin once the live
    /// track has `lead` seconds (or fewer) left.
    static func inLeadWindow(secondsLeft: Double, lead: Double) -> Bool { secondsLeft <= lead }

    /// The tempo headroom the pre-roll fit divides the runway by.
    static func headroom(mixGlide: Bool) -> Double { mixGlide ? glideTempoHeadroom : 1.0 }

    /// Plan the tick-driven ADVANCE (the normal, repeat-one and repeat-all lanes): cap the fade to
    /// the runway left, then fit the glide pre-roll into what's left after the fade + a margin.
    ///
    /// - Parameters:
    ///   - secondsLeft: audio left on the outgoing track.
    ///   - fadeSeconds: the configured (current) crossfade length.
    ///   - glideSeconds: the Mix-Glide length — the pre-roll ceiling AND the post-roll length.
    ///   - fxGlide / mixGlide: the two glide toggles (either ⇒ a glide transition).
    ///   - fadeOverridePending: a one-off fade override is already in effect (its restore is
    ///     pending) — the fade is then NOT capped again and no new restore is planned.
    static func advancePlan(secondsLeft: Double, fadeSeconds: Double, glideSeconds: Double,
                            fxGlide: Bool, mixGlide: Bool,
                            fadeOverridePending: Bool = false) -> Plan {
        var fade = fadeSeconds
        var restore: Double?
        // Slid to (say) 2 s from the end: crossfade over ~2 s so it completes before it runs out.
        if secondsLeft < fadeSeconds, !fadeOverridePending {
            restore = fadeSeconds
            fade = max(minRunwayFadeSeconds, secondsLeft)
        }
        let glide = fxGlide || mixGlide
        var preroll = 0.0
        if glide {
            preroll = max(0, min(glideSeconds,
                                 secondsLeft / headroom(mixGlide: mixGlide) - fade - preRollMarginSeconds))
        }
        return Plan(isGlide: glide, preRollSeconds: preroll, fadeSeconds: fade,
                    postRollSeconds: glide ? glideSeconds : 0, fadeRestore: restore)
    }

    /// Plan an IMMEDIATE transition (manual skip / stall hand-over): no pre-roll, a one-off fade
    /// (floored at `minImmediateFadeSeconds`) whose baseline is restored after the crossfade.
    static func immediatePlan(fadeSeconds requested: Double, baselineFadeSeconds: Double,
                              glideSeconds: Double, fxGlide: Bool, mixGlide: Bool,
                              fadeOverridePending: Bool = false) -> Plan {
        let glide = fxGlide || mixGlide
        return Plan(isGlide: glide, preRollSeconds: 0,
                    fadeSeconds: max(minImmediateFadeSeconds, requested),
                    postRollSeconds: glide ? glideSeconds : 0,
                    fadeRestore: fadeOverridePending ? nil : baselineFadeSeconds)
    }

    // MARK: - Equal-power crossfade

    /// The equal-power (cosine) crossfade law. `progress` 0 = all outgoing, 1 = all incoming;
    /// `outgoing² + incoming² = 1` throughout, so the summed power stays constant (−3 dB each at
    /// the midpoint). The Mix crossfader is this law with deck A = outgoing, deck B = incoming.
    static func equalPowerGains(progress: Float) -> (outgoing: Float, incoming: Float) {
        (cosf(.pi / 2 * progress), cosf(.pi / 2 * (1 - progress)))
    }

    // MARK: - Tempo / pitch (Mix Glide)

    /// 1 Camelot "key" (wheel hour) as a pitch shift in SEMITONES, at the 10%-per-key convention:
    /// a +10% frequency ratio is `12·log2(1.1)` ≈ 1.65 semitones.
    static let semitonesPerKey: Double = 12 * log2(1.1)

    /// Octave-fold a tempo ratio into `rateRange` (×2 / ÷2 = half/double-time match), then clamp.
    /// A non-finite / non-positive ratio (missing BPM) folds to 1.0 (no change).
    static func octaveFolded(_ ratio: Double) -> Double {
        guard ratio.isFinite, ratio > 0 else { return 1 }
        var r = ratio
        while r > rateRange.upperBound { r /= 2 }
        while r < rateRange.lowerBound { r *= 2 }
        return min(max(r, rateRange.lowerBound), rateRange.upperBound)
    }

    /// The follower tempo multiplier that matches the Lead's effective BPM (octave-folded).
    static func syncRate(leadBPM: Double, leadRate: Double, followerBPM: Double) -> Double {
        guard followerBPM > 0 else { return 1 }
        return octaveFolded(leadBPM * leadRate / followerBPM)
    }

    /// Signed Camelot-hour distance a→b, wrapped to the shortest way round the 12-hour wheel (−6…+6).
    /// nil if either code is unparseable. Positive ⇒ b is "higher" (glide the outgoing deck up to it).
    static func signedCamelotSteps(_ a: String?, _ b: String?) -> Int? {
        guard let pa = Camelot.parse(a), let pb = Camelot.parse(b) else { return nil }
        var d = pb.num - pa.num
        if d > 6 { d -= 12 } else if d < -6 { d += 12 }
        return d
    }

    /// Tempo multiplier for a glide of `keys` (Camelot hours; 1 key = ±10%), clamped to `rateRange`.
    static func glideRate(keys: Double) -> Double {
        min(max(1 + 0.10 * keys, rateRange.lowerBound), rateRange.upperBound)
    }
    /// Pitch shift (semitones) for a glide of `keys`, clamped to `pitchRange`.
    static func glidePitch(keys: Double) -> Double {
        min(max(keys * semitonesPerKey, pitchRange.lowerBound), pitchRange.upperBound)
    }

    /// The identity glide (no tempo / pitch bend) — Mix Glide off, or Tempo/Key matching masked off.
    static let identityGlide: (outRate: Double, outPitch: Double, inRate: Double, inPitch: Double) = (1, 0, 1, 0)

    /// Per-deck tempo/pitch targets for a transition A(out)→B(in). Two INDEPENDENT, data-gated bends
    /// (no default — with neither datum it's identity, i.e. just the volume crossfade):
    ///   • PITCH — only when BOTH Camelot keys are known: harmonic bend toward each other (≤1 key each,
    ///     1 key = ~1.65 st), so the overlap meets in the middle; the incoming then settles back.
    ///   • TEMPO — only when BOTH BPMs are known: a real BEAT-MATCH toward the middle. Using the SAME
    ///     octave-folded ratio the Lead/Sync buttons use (`octaveFolded`, fed the measured grid BPM by
    ///     the caller), the full match is SPLIT between the two decks so they meet at a common
    ///     effective BPM — their beats lock during the overlap (the caller then phase-aligns).
    static func glideParams(fromCamelot a: String?, toCamelot b: String?,
                            fromBPM: Double?, toBPM: Double?)
        -> (outRate: Double, outPitch: Double, inRate: Double, inPitch: Double) {
        var outPitch = 0.0, inPitch = 0.0, outRate = 1.0, inRate = 1.0
        // PITCH — Camelot harmonic bend (both keys known + not identical).
        if let d = signedCamelotSteps(a, b), abs(d) >= 1 {
            let mag = min(1.0, Double(abs(d)) / 2.0)
            let dir = d > 0 ? 1.0 : -1.0
            outPitch = glidePitch(keys: dir * mag)        // outgoing bends toward incoming
            inPitch = glidePitch(keys: -dir * mag)        // incoming starts opposite, settles back
        }
        // TEMPO — beat-match, split between the decks so they MEET (octave-folded like Sync).
        if let ra = fromBPM, let rb = toBPM, ra > 0, rb > 0 {
            let split = octaveFolded(ra / rb).squareRoot()   // incoming's full match to outgoing, halved
            inRate = min(max(split, rateRange.lowerBound), rateRange.upperBound)
            outRate = min(max(1 / split, rateRange.lowerBound), rateRange.upperBound)
        }
        return (outRate, outPitch, inRate, inPitch)
    }

    // MARK: - Glide ramps (linear; `p` 0→1)

    /// PRE-ROLL step on the OUTGOING: tempo/pitch bend in toward the glide target, FX sweep in.
    static func outgoingRamp(_ p: Double, outRate: Double, outPitch: Double, fxPeak: Double)
        -> (rate: Double, pitch: Double, fxStrength: Double) {
        (1 + (outRate - 1) * p, outPitch * p, p * fxPeak)
    }

    /// POST-ROLL step on the INCOMING: tempo/pitch ease back to natural, FX sweep out.
    static func incomingRamp(_ p: Double, inRate: Double, inPitch: Double, fxPeak: Double)
        -> (rate: Double, pitch: Double, fxStrength: Double) {
        (inRate + (1 - inRate) * p, inPitch * (1 - p), (1 - p) * fxPeak)
    }

    // MARK: - FX texture (FX Glide)

    /// The sweepy effects a transition textures with (no compressor — that's dynamics, not a sweep).
    /// Raw values match `MixEngine.Effect`'s.
    enum TextureEffect: String, CaseIterable, Sendable { case filter, reverb, flanger }

    /// The texture pool, in roll order (the order is part of the determinism contract).
    static let texturePool: [TextureEffect] = [.filter, .reverb, .flanger]
    /// Texture peak strength = `texturePeakMin + u · texturePeakSpan`, u ∈ [0, 1) ⇒ 0.5…0.8.
    static let texturePeakMin: Double = 0.5
    static let texturePeakSpan: Double = 0.3
    /// A rolled texture is held for `textureRunMin + (0 ..< textureRunChoices)` transitions ⇒ 3…5.
    static let textureRunMin: Int = 3
    static let textureRunChoices: Int = 3

    /// splitmix64 — a tiny deterministic PRNG so texture selection is reproducible + unit-testable.
    static func splitmix64(_ state: inout UInt64) -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Roll the next FX-Glide texture: an effect from the pool, a peak strength (0.5…0.8), and a run
    /// length (3…5 transitions to keep it). Pure + deterministic given `state`.
    static func rollTexture(_ state: inout UInt64) -> (effect: TextureEffect, peak: Double, run: Int) {
        let a = splitmix64(&state), b = splitmix64(&state), c = splitmix64(&state)
        let effect = texturePool[Int(a % UInt64(texturePool.count))]
        let peak = texturePeakMin + Double(b % 1000) / 1000.0 * texturePeakSpan
        let run = textureRunMin + Int(c % UInt64(textureRunChoices))
        return (effect, peak, run)
    }

    /// A stable per-session seed (FNV-1a over the first song id ⊕ count) — deterministic, so a given
    /// track set always textures the same way, without wall-clock randomness.
    static func fxSeed(firstSongId: String?, count: Int) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (firstSongId ?? "seed").utf8 {
            h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return h ^ UInt64(count)
    }

    // MARK: - Phase align (beat sync)

    /// What phase alignment needs to know about one track's beat lattice. All optional: a missing
    /// BPM disables alignment; a missing downbeat is treated as 0 (beat-0 at the song start).
    struct BeatRef: Equatable, Sendable {
        /// The BPM to match on (the measured grid BPM when known, else the catalog BPM).
        var bpm: Double?
        var firstDownbeatMs: Int?
        /// Measured beat times (ms, ascending). When it brackets the playhead, the phase is read
        /// off the grid (exact, tempo-drift aware); otherwise the BPM lattice is used.
        var beatsMs: [Int]?

        init(bpm: Double?, firstDownbeatMs: Int? = nil, beatsMs: [Int]? = nil) {
            self.bpm = bpm
            self.firstDownbeatMs = firstDownbeatMs
            self.beatsMs = beatsMs
        }
    }

    /// The beat phase (fraction of a beat) at `position` seconds, and the beat length (seconds)
    /// there. nil when the track has no usable BPM.
    ///
    /// BPM lattice: `((position − firstDownbeat) / beat) mod 1` — `truncatingRemainder`, so a
    /// playhead BEFORE its first downbeat has a NEGATIVE phase (−1, 0]. That is the Mix engine's
    /// long-standing math and is preserved on purpose: see `phaseAlignOffset`.
    static func beatPhase(_ ref: BeatRef, at position: Double) -> (phase: Double, beatSeconds: Double)? {
        guard let bpm = ref.bpm, bpm > 0, bpm.isFinite else { return nil }
        if let beats = ref.beatsMs, beats.count >= 2 {
            let ms = position * 1000
            if ms >= Double(beats[0]), ms < Double(beats[beats.count - 1]) {
                // Last beat at/before the playhead (binary search; beats ascending).
                var lo = 0, hi = beats.count - 1
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if Double(beats[mid]) <= ms { lo = mid } else { hi = mid }
                }
                let len = Double(beats[lo + 1] - beats[lo])
                if len > 0 { return ((ms - Double(beats[lo])) / len, len / 1000) }
            }
        }
        let beat = 60.0 / bpm
        let db = Double(ref.firstDownbeatMs ?? 0) / 1000.0
        return (((position - db) / beat).truncatingRemainder(dividingBy: 1), beat)
    }

    /// How far (SECONDS) to move the INCOMING playhead so its beat phase lands on the OUTGOING's.
    /// Returns 0 when either track has no BPM. The caller seeks the incoming to
    /// `max(0, incomingPosition + offset)`.
    ///
    /// Bound: |offset| ≤ ½ incoming beat whenever both playheads are at/after their first downbeat
    /// (the steady state). With a playhead BEFORE its first downbeat (an incoming just started on a
    /// track whose downbeat is > 0), the preserved single-wrap math can return up to one beat
    /// FORWARD instead — which is what keeps the `max(0, …)` clamp from swallowing the alignment
    /// at the very start of a song. Overall the result lies in (−1, +1) beat.
    static func phaseAlignOffset(outgoing: BeatRef, outgoingPosition: Double,
                                 incoming: BeatRef, incomingPosition: Double) -> Double {
        guard let lead = beatPhase(outgoing, at: outgoingPosition),
              let fol = beatPhase(incoming, at: incomingPosition) else { return 0 }
        var delta = lead.phase - fol.phase
        if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }
        return delta * fol.beatSeconds
    }

    /// `phaseAlignOffset` in MILLISECONDS, with playheads in milliseconds.
    static func phaseAlignOffsetMs(outgoing: BeatRef, outgoingPositionMs: Double,
                                   incoming: BeatRef, incomingPositionMs: Double) -> Double {
        phaseAlignOffset(outgoing: outgoing, outgoingPosition: outgoingPositionMs / 1000,
                         incoming: incoming, incomingPosition: incomingPositionMs / 1000) * 1000
    }
}
