import Foundation
import AVFoundation

// MARK: - Effect variants

/// One concrete flavour of a `MixEngine.Effect` family — the "variety" a rack slot is set to.
///
/// Deliberately a FLAT enum rather than one nested per family: a single String rawValue is what
/// persistence (`FXSlotSnapshot.variant`) and the session timeline (`param`) carry, and a single
/// exhaustive switch drives the node parameters (`MixEngine.applySlot`). The `effect` property is
/// the invariant — a variant ALWAYS belongs to exactly one family, and `FXSlot` enforces that a
/// slot's variant matches its effect.
///
/// The `default(for:)` picks are chosen so a fresh rack sounds EXACTLY like the pre-rack build:
/// `.punch` reproduces the old compressor curve, `.hall` is the `.mediumHall` preset the engine
/// used to load at build, `.flange` is the old 4 ms comb, `.lowPass` was the only filter shape.
enum EffectVariant: String, Codable, CaseIterable, Identifiable, Sendable {
    // filter
    case lowPass, highPass, bandPass
    // reverb
    case room, hall, plate, cathedral
    // modulation (MixEngine.Effect.flanger — the family kept its legacy rawValue)
    case flange, chorus, echo
    // compressor
    case punch, glue, limit

    var id: String { rawValue }

    /// The family this variant belongs to. Total + exhaustive: adding a case forces a decision here.
    var effect: MixEngine.Effect {
        switch self {
        case .lowPass, .highPass, .bandPass:        return .filter
        case .room, .hall, .plate, .cathedral:      return .reverb
        case .flange, .chorus, .echo:               return .flanger
        case .punch, .glue, .limit:                 return .compressor
        }
    }

    /// Short chip-width label (the rack chip shows this, not the family name — "Hall"/"HP"/"Glue"
    /// says more in the same pixels than "Reverb"/"Filter"/"Comp").
    var label: String {
        switch self {
        case .lowPass:    return "LP"
        case .highPass:   return "HP"
        case .bandPass:   return "BP"
        case .room:       return "Room"
        case .hall:       return "Hall"
        case .plate:      return "Plate"
        case .cathedral:  return "Cathedral"
        case .flange:     return "Flanger"
        case .chorus:     return "Chorus"
        case .echo:       return "Echo"
        case .punch:      return "Punch"
        case .glue:       return "Glue"
        case .limit:      return "Limit"
        }
    }

    /// Longer label for menus / VoiceOver, where there's room to disambiguate the filter shapes.
    var longLabel: String {
        switch self {
        case .lowPass:  return "Low-pass"
        case .highPass: return "High-pass"
        case .bandPass: return "Band-pass"
        default:        return label
        }
    }

    /// Every variant of one family, in menu order.
    static func all(for effect: MixEngine.Effect) -> [EffectVariant] {
        allCases.filter { $0.effect == effect }
    }

    /// The variant a slot lands on when it's switched TO `effect` — each reproduces the pre-rack
    /// behaviour of that effect, so swapping in a family never surprises with a new sound.
    static func `default`(for effect: MixEngine.Effect) -> EffectVariant {
        switch effect {
        case .compressor: return .punch
        case .reverb:     return .hall
        case .flanger:    return .flange
        case .filter:     return .lowPass
        }
    }
}

// MARK: - A rack slot

/// One of the deck's four FX rack slots: which effect family it holds, which variety of it, and
/// that effect's on/off + strength. Slots are positional — index == rack position — and DUPLICATES
/// ARE LEGAL (two compressors, or a low-pass in slot 0 and a high-pass in slot 2, is a valid rack).
///
/// `effect`/`variant` are `private(set)` and only move through the mutators, which maintain the
/// invariant `variant.effect == effect`.
struct FXSlot: Equatable, Sendable {
    private(set) var effect: MixEngine.Effect
    private(set) var variant: EffectVariant
    var enabled: Bool
    /// 0…1 — clamped by `setStrength`. Always stored; only audible while `enabled`.
    var strength: Double

    init(_ effect: MixEngine.Effect,
         variant: EffectVariant? = nil,
         enabled: Bool = false,
         strength: Double = 0.5) {
        self.effect = effect
        // A mismatched variant (corrupt/hand-edited session) falls back to the family default
        // rather than trapping — restore must never be able to crash the app.
        let v = variant ?? .default(for: effect)
        self.variant = v.effect == effect ? v : .default(for: effect)
        self.enabled = enabled
        self.strength = min(max(strength, 0), 1)
    }

    /// Swap this slot to a different effect family. The variant resets to that family's default —
    /// a variant of the OLD family would violate the invariant.
    mutating func setEffect(_ e: MixEngine.Effect) {
        guard e != effect else { return }
        effect = e
        variant = .default(for: e)
    }

    /// Pick a different variety of the SAME family. A cross-family variant is ignored (the UI only
    /// ever offers `EffectVariant.all(for: effect)`, so this is a belt-and-braces guard).
    mutating func setVariant(_ v: EffectVariant) {
        guard v.effect == effect else { return }
        variant = v
    }

    mutating func setStrength(_ v: Double) { strength = min(max(v, 0), 1) }
}

// MARK: - Variant → AU parameters

/// The pure variant→parameter mapping for every effect family. Kept as plain value-returning
/// statics (no AVAudioUnit touched) so the whole table is unit-testable on a headless host with no
/// audio device — `MixEngine.applySlot` is the only thing that writes these onto real nodes.
enum FXParams {
    // MARK: Filter — AVAudioUnitEQ, one band

    /// Cutoff/centre frequency (Hz) for a filter variant at strength `s` (0…1).
    /// LP and HP reproduce the pre-rack curves EXACTLY; BP sweeps its centre down like LP.
    static func filterFrequency(_ v: EffectVariant, _ s: Double) -> Float {
        let s = min(max(s, 0), 1)
        switch v {
        // Strength sweeps the cutoff log-down from ~18 kHz (subtle) to ~250 Hz (heavy) —
        // classic DJ build-DOWN (cuts highs as strength rises).
        case .lowPass:  return Float(18_000 * pow(250.0 / 18_000.0, s))
        // Log-up from ~30 Hz to ~2 kHz — classic DJ build-UP (cuts bass as strength rises).
        case .highPass: return Float(30.0 * pow(2_000.0 / 30.0, s))
        // Centre sweeps down 4 kHz → 300 Hz; combined with the narrowing bandwidth below this
        // walks from "airy" to a tight telephone/radio honk.
        case .bandPass: return Float(4_000 * pow(300.0 / 4_000.0, s))
        default:        return 1_000
        }
    }

    /// Filter bandwidth in octaves. LP/HP keep the pre-rack 0.5; BP tightens as you push it.
    static func filterBandwidth(_ v: EffectVariant, _ s: Double) -> Float {
        v == .bandPass ? Float(1.5 - 1.0 * min(max(s, 0), 1)) : 0.5
    }

    static func filterType(_ v: EffectVariant) -> AVAudioUnitEQFilterType {
        switch v {
        case .highPass: return .resonantHighPass
        case .bandPass: return .bandPass
        default:        return .resonantLowPass
        }
    }

    // MARK: Reverb — AVAudioUnitReverb factory presets

    static func reverbPreset(_ v: EffectVariant) -> AVAudioUnitReverbPreset {
        switch v {
        case .room:      return .mediumRoom
        case .plate:     return .plate
        case .cathedral: return .cathedral
        default:         return .mediumHall     // .hall — the pre-rack build-time preset
        }
    }

    // MARK: Modulation — AVAudioUnitDelay
    //
    // NOTE: `AVAudioUnitDelay` has no LFO, so Flanger and Chorus are STATIC combs at different
    // delay lengths rather than swept modulation (the pre-rack code already noted this: "a true
    // LFO flanger is future work"). Echo is a genuine feedback delay. The three are audibly
    // distinct, but don't describe Flanger/Chorus as "modulating" in UI copy.

    /// Delay time (seconds).
    static func modDelayTime(_ v: EffectVariant, _ s: Double) -> TimeInterval {
        let s = min(max(s, 0), 1)
        switch v {
        case .flange: return 0.004                  // ~4 ms comb (the pre-rack flanger)
        case .chorus: return 0.012 + 0.013 * s      // 12→25 ms detune comb
        case .echo:   return 0.15 + 0.35 * s        // 150→500 ms repeats
        default:      return 0.004
        }
    }

    /// Feedback (%).
    static func modFeedback(_ v: EffectVariant, _ s: Double) -> Float {
        let s = Float(min(max(s, 0), 1))
        switch v {
        case .flange: return s * 60
        case .chorus: return s * 15                 // low — chorus should thicken, not ring
        case .echo:   return s * 70                 // high — audible repeat tail
        default:      return s * 60
        }
    }

    /// Wet/dry mix (%).
    static func modWetDryMix(_ v: EffectVariant, _ s: Double) -> Float {
        let s = Float(min(max(s, 0), 1))
        switch v {
        case .flange: return s * 50
        case .chorus: return s * 45
        case .echo:   return s * 50
        default:      return s * 50
        }
    }

    /// Low-pass cutoff (Hz) inside the delay — darkens successive repeats.
    static func modLowPassCutoff(_ v: EffectVariant) -> Float {
        switch v {
        case .chorus: return 12_000
        case .echo:   return 8_000                  // darkening tail, classic dub feel
        default:      return 15_000                 // .flange — the pre-rack value
        }
    }

    // MARK: Compressor — Apple DynamicsProcessor AU
    //
    // `.punch` reproduces the pre-rack threshold/makeup curve exactly. Attack/release/headroom
    // were previously left at the AU defaults; they're now set explicitly per variant.

    /// Threshold (dB) — drops as strength rises (heavier compression).
    static func compThreshold(_ v: EffectVariant, _ s: Double) -> Float {
        let s = Float(min(max(s, 0), 1))
        switch v {
        case .punch: return -30 * s                 // the pre-rack curve
        case .glue:  return -20 * s
        case .limit: return -20 * s
        default:     return -30 * s
        }
    }

    /// Headroom (dB) above the threshold — effectively the knee softness.
    static func compHeadRoom(_ v: EffectVariant) -> Float {
        switch v {
        case .punch: return 5
        case .glue:  return 10                      // soft knee — gentle bus glue
        case .limit: return 0.5                     // hard — brick wall
        default:     return 5
        }
    }

    /// Attack time (seconds). Fast attack clamps transients; slow lets them through.
    static func compAttack(_ v: EffectVariant) -> Float {
        switch v {
        case .punch: return 0.020                   // lets the transient punch through
        case .glue:  return 0.030
        case .limit: return 0.001                   // catches peaks
        default:     return 0.020
        }
    }

    /// Release time (seconds).
    static func compRelease(_ v: EffectVariant) -> Float {
        switch v {
        case .punch: return 0.15
        case .glue:  return 0.40                    // long — rides the whole phrase
        case .limit: return 0.05
        default:     return 0.15
        }
    }

    /// Makeup / overall gain (dB) — rises with strength so engaging Comp adds density, not just
    /// level loss. `.punch` keeps the pre-rack `15·s`.
    static func compMakeup(_ v: EffectVariant, _ s: Double) -> Float {
        let s = Float(min(max(s, 0), 1))
        switch v {
        case .punch: return 15 * s                  // the pre-rack curve
        case .glue:  return 8 * s
        case .limit: return 6 * s
        default:     return 15 * s
        }
    }
}
