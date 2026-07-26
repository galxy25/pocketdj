import Foundation

// MARK: - Per-track channel-strip FX (arranger)
//
// The LIVE render-block DSP for one track's mix strip: a 3-band EQ (low-shelf / mid-peak / high-
// shelf) plus reverb / delay / chorus sends. Pitch + tempo are NOT here — they change audio CONTENT
// and are pre-baked into the clip buffers by MultitrackPlayer (a raw-sum render loop can't host a
// time-stretch). These six knobs, by contrast, are per-sample stateful DSP that must ring out past a
// clip's end (a reverb/delay tail) and respond LIVE to a dial drag — so they run in the render block,
// exactly like MasterFXKernel, one kernel per track. Same discipline as MasterFX: a plain value-type
// param snapshot read once per block (torn reads benign), all state allocated in `configure`, no
// allocation in the hot path. Applied IDENTICALLY live (MultitrackRenderContext) and in a bounce
// (ArrangerBouncer) so what you hear is what you export.

/// DSP-relevant snapshot of a `StudioChannelStrip`'s LIVE effects (EQ + sends) + the master bpm the
/// delay syncs to. Pitch/tempo are excluded on purpose (baked upstream).
struct TrackFXParams: Sendable, Equatable {
    var eqLowDb = 0.0, eqMidDb = 0.0, eqHighDb = 0.0
    var reverb = 0.0, delay = 0.0, chorus = 0.0
    var bpm = 120.0

    /// True when any effect is audibly engaged — lets the mixer take the fast raw-sum path on a
    /// neutral track (no scratch buffer, no kernel).
    var active: Bool {
        abs(eqLowDb) > 0.01 || abs(eqMidDb) > 0.01 || abs(eqHighDb) > 0.01 ||
        reverb > 0.001 || delay > 0.001 || chorus > 0.001
    }

    init() {}
    init(_ s: StudioChannelStrip, bpm: Double) {
        let c = s.clamped()
        eqLowDb = c.eqLowDb; eqMidDb = c.eqMidDb; eqHighDb = c.eqHighDb
        reverb = c.reverb; delay = c.delay; chorus = c.chorus
        self.bpm = bpm > 0 ? bpm : 120
    }
}

/// A Direct-Form-I biquad (per channel). Coefficients (normalized by a0) are set from the main thread
/// via the RBJ cookbook; `process` runs on the audio thread. One instance per (channel, band).
private struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    mutating func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }

    @inline(__always) mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    /// RBJ low-shelf. `dB` = shelf gain, `f0` = corner, `sr` = sample rate.
    static func lowShelf(dB: Double, f0: Double, sr: Double) -> (Double, Double, Double, Double, Double) {
        let A = pow(10, dB / 40), w0 = 2 * .pi * f0 / sr
        let cw = cos(w0), sw = sin(w0), alpha = sw / 2 * sqrt(2), twoSqrtAalpha = 2 * sqrt(A) * alpha
        let a0 = (A + 1) + (A - 1) * cw + twoSqrtAalpha
        let b0 = A * ((A + 1) - (A - 1) * cw + twoSqrtAalpha)
        let b1 = 2 * A * ((A - 1) - (A + 1) * cw)
        let b2 = A * ((A + 1) - (A - 1) * cw - twoSqrtAalpha)
        let a1 = -2 * ((A - 1) + (A + 1) * cw)
        let a2 = (A + 1) + (A - 1) * cw - twoSqrtAalpha
        return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }
    /// RBJ high-shelf.
    static func highShelf(dB: Double, f0: Double, sr: Double) -> (Double, Double, Double, Double, Double) {
        let A = pow(10, dB / 40), w0 = 2 * .pi * f0 / sr
        let cw = cos(w0), sw = sin(w0), alpha = sw / 2 * sqrt(2), twoSqrtAalpha = 2 * sqrt(A) * alpha
        let a0 = (A + 1) - (A - 1) * cw + twoSqrtAalpha
        let b0 = A * ((A + 1) + (A - 1) * cw + twoSqrtAalpha)
        let b1 = -2 * A * ((A - 1) + (A + 1) * cw)
        let b2 = A * ((A + 1) + (A - 1) * cw - twoSqrtAalpha)
        let a1 = 2 * ((A - 1) - (A + 1) * cw)
        let a2 = (A + 1) - (A - 1) * cw - twoSqrtAalpha
        return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }
    /// RBJ peaking EQ (mid band). `Q` sets bandwidth.
    static func peaking(dB: Double, f0: Double, Q: Double, sr: Double) -> (Double, Double, Double, Double, Double) {
        let A = pow(10, dB / 40), w0 = 2 * .pi * f0 / sr
        let cw = cos(w0), sw = sin(w0), alpha = sw / (2 * Q)
        let a0 = 1 + alpha / A
        let b0 = 1 + alpha * A
        let b1 = -2 * cw
        let b2 = 1 - alpha * A
        let a1 = -2 * cw
        let a2 = 1 - alpha / A
        return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }
}

/// A feedback comb filter with a one-pole damping low-pass in the loop (Freeverb building block).
private struct Comb {
    var buf: [Double]; var idx = 0; var store = 0.0
    var feedback = 0.0; var damp1 = 0.0; var damp2 = 0.0
    init(_ size: Int) { buf = Array(repeating: 0, count: max(1, size)) }
    mutating func reset() { for i in buf.indices { buf[i] = 0 }; store = 0 }
    @inline(__always) mutating func process(_ x: Double) -> Double {
        let y = buf[idx]
        store = y * damp2 + store * damp1
        buf[idx] = x + store * feedback
        idx += 1; if idx >= buf.count { idx = 0 }
        return y
    }
}

/// A Schroeder all-pass (Freeverb building block).
private struct AllPass {
    var buf: [Double]; var idx = 0; let feedback = 0.5
    init(_ size: Int) { buf = Array(repeating: 0, count: max(1, size)) }
    mutating func reset() { for i in buf.indices { buf[i] = 0 } }
    @inline(__always) mutating func process(_ x: Double) -> Double {
        let bufout = buf[idx]
        let y = -x + bufout
        buf[idx] = x + bufout * feedback
        idx += 1; if idx >= buf.count { idx = 0 }
        return y
    }
}

/// One track's live FX kernel. Reference type: state allocated once in `configure`, mutated in place
/// on the audio thread. Not thread-safe by design (params set from main, `process` on audio) — the
/// value-type `TrackFXParams` read makes that safe enough, same contract as `MasterFXKernel`.
final class TrackFXKernel: @unchecked Sendable {
    private var sr = 44_100.0
    private var channels = 2
    private var p = TrackFXParams()

    // 3-band EQ: [channel][band 0=low,1=mid,2=high].
    private var eq: [[Biquad]] = []
    private var eqOn = false

    // Delay (bpm-synced 1/8 note): per-channel ring + write head; time/feedback from params/bpm.
    private var delayBuf: [[Double]] = []
    private var delayWrite: [Int] = []
    private var delayFrames = 1
    private var delayFeedback = 0.34
    private var delayWet = 0.0

    // Chorus: modulated delay (per-channel ring), LFO phase (stereo-spread per channel).
    private var chorusBuf: [[Double]] = []
    private var chorusWrite: [Int] = []
    private var chorusPhase: [Double] = []
    private var chorusWet = 0.0
    private let chorusBaseMs = 18.0, chorusDepthMs = 6.0, chorusRateHz = 0.8

    // Reverb (compact Freeverb: 4 combs + 2 all-pass per channel), scaled input.
    private var combs: [[Comb]] = []
    private var allpasses: [[AllPass]] = []
    private var reverbWet = 0.0
    private let combTunings = [1116, 1188, 1277, 1356]   // @44.1k; scaled to sr
    private let allpassTunings = [556, 441]
    private let stereoSpread = 23

    private var chanPtrs: [UnsafeMutablePointer<Float>?] = []

    func configure(sampleRate: Double, channelCount: Int) {
        sr = sampleRate > 0 ? sampleRate : 44_100
        channels = max(1, channelCount)
        let scale = sr / 44_100.0

        eq = (0..<channels).map { _ in [Biquad(), Biquad(), Biquad()] }

        delayFrames = max(1, Int(sr * 2))                    // ring holds ≤ 2 s (recomputed in update)
        delayBuf = Array(repeating: Array(repeating: 0, count: max(1, Int(sr * 2) + 1)), count: channels)
        delayWrite = Array(repeating: 0, count: channels)

        let chorusMax = Int((chorusBaseMs + chorusDepthMs + 2) / 1000 * sr) + 2
        chorusBuf = Array(repeating: Array(repeating: 0, count: max(2, chorusMax)), count: channels)
        chorusWrite = Array(repeating: 0, count: channels)
        chorusPhase = (0..<channels).map { Double($0) * 0.5 }   // ~half-cycle offset for stereo width

        combs = (0..<channels).map { c in
            combTunings.map { Comb(Int(Double($0) * scale) + (c == 1 ? stereoSpread : 0)) }
        }
        allpasses = (0..<channels).map { c in
            allpassTunings.map { AllPass(Int(Double($0) * scale) + (c == 1 ? stereoSpread : 0)) }
        }
        chanPtrs = Array(repeating: nil, count: channels)
        update(p)
    }

    func update(_ params: TrackFXParams) {
        p = params
        // EQ coefficients (fixed corners: low 120 Hz shelf, mid 1 kHz peak Q0.9, high 8 kHz shelf).
        eqOn = abs(params.eqLowDb) > 0.01 || abs(params.eqMidDb) > 0.01 || abs(params.eqHighDb) > 0.01
        for c in 0..<eq.count {
            (eq[c][0].b0, eq[c][0].b1, eq[c][0].b2, eq[c][0].a1, eq[c][0].a2) = Biquad.lowShelf(dB: params.eqLowDb, f0: 120, sr: sr)
            (eq[c][1].b0, eq[c][1].b1, eq[c][1].b2, eq[c][1].a1, eq[c][1].a2) = Biquad.peaking(dB: params.eqMidDb, f0: 1000, Q: 0.9, sr: sr)
            (eq[c][2].b0, eq[c][2].b1, eq[c][2].b2, eq[c][2].a1, eq[c][2].a2) = Biquad.highShelf(dB: params.eqHighDb, f0: 8000, sr: sr)
        }
        // Delay: 1/8 note at bpm, clamped into the ring.
        let eighth = 60.0 / max(20, min(300, params.bpm)) / 2
        delayFrames = max(1, min(delayBuf.first.map { $0.count - 1 } ?? 1, Int(eighth * sr)))
        delayWet = max(0, min(1, params.delay))
        chorusWet = max(0, min(1, params.chorus))
        // Reverb: map amount → room feedback + damping; wet is the send level.
        reverbWet = max(0, min(1, params.reverb))
        let room = 0.70 + 0.28 * reverbWet          // larger tail as the dial opens
        for c in 0..<combs.count {
            for k in combs[c].indices {
                combs[c][k].feedback = room
                combs[c][k].damp1 = 0.2
                combs[c][k].damp2 = 0.8
            }
        }
    }

    /// True when any effect is engaged (mirror of params.active) — the mixer uses this to decide the
    /// scratch path. Kept as a stored flag so the audio thread doesn't recompute per block.
    var active: Bool { p.active }

    func reset() {
        for c in eq.indices { for b in eq[c].indices { eq[c][b].reset() } }
        for c in delayBuf.indices { for i in delayBuf[c].indices { delayBuf[c][i] = 0 }; delayWrite[c] = 0 }
        for c in chorusBuf.indices { for i in chorusBuf[c].indices { chorusBuf[c][i] = 0 }; chorusWrite[c] = 0 }
        for c in combs.indices { for k in combs[c].indices { combs[c][k].reset() } }
        for c in allpasses.indices { for k in allpasses[c].indices { allpasses[c][k].reset() } }
    }

    /// Process one track's scratch buffer in place. `data` are per-channel Float pointers (the raw,
    /// pre-gain summed clips for this track); output is the wet/dry-mixed strip.
    func processFloatChannels(_ data: UnsafePointer<UnsafeMutablePointer<Float>>,
                              channelCount: Int, frames: Int) {
        let n = min(channelCount, channels)
        guard n > 0, frames > 0, eq.count >= n else { return }
        let params = p
        guard params.active else { return }
        let phaseInc = 2 * .pi * chorusRateHz / sr
        let chorusBase = chorusBaseMs / 1000 * sr, chorusDepth = chorusDepthMs / 1000 * sr

        for c in 0..<n {
            let d = data[c]
            for i in 0..<frames {
                var s = Double(d[i])

                // 3-band EQ (series).
                if eqOn { s = eq[c][2].process(eq[c][1].process(eq[c][0].process(s))) }

                // Chorus (modulated delay, add wet).
                if chorusWet > 0 {
                    let lfo = (sin(chorusPhase[c]) + 1) / 2           // 0…1
                    let dly = chorusBase + lfo * chorusDepth
                    let buf = chorusBuf[c]
                    let readPos = Double(chorusWrite[c]) - dly
                    let wet = interp(buf, readPos)
                    chorusBuf[c][chorusWrite[c]] = s
                    chorusWrite[c] += 1; if chorusWrite[c] >= buf.count { chorusWrite[c] = 0 }
                    chorusPhase[c] += phaseInc; if chorusPhase[c] > 2 * .pi { chorusPhase[c] -= 2 * .pi }
                    s += wet * chorusWet * 0.7
                }

                // Delay (bpm-synced, feedback, add wet).
                if delayWet > 0 {
                    let rd = (delayWrite[c] - delayFrames + delayBuf[c].count) % delayBuf[c].count
                    let echo = delayBuf[c][rd]
                    delayBuf[c][delayWrite[c]] = s + echo * delayFeedback
                    delayWrite[c] += 1; if delayWrite[c] >= delayBuf[c].count { delayWrite[c] = 0 }
                    s += echo * delayWet * 0.8
                }

                // Reverb (4 combs in parallel → 2 all-pass in series, add wet).
                if reverbWet > 0 {
                    let input = s * 0.5
                    var acc = 0.0
                    for k in combs[c].indices { acc += combs[c][k].process(input) }
                    acc = allpasses[c][0].process(acc)
                    acc = allpasses[c][1].process(acc)
                    s += acc * reverbWet * 0.5
                }

                d[i] = Float(s)
            }
        }
    }

    /// Linear-interpolated ring read at a (possibly negative, wrapped) fractional position.
    @inline(__always) private func interp(_ buf: [Double], _ pos: Double) -> Double {
        let n = buf.count
        var p = pos
        while p < 0 { p += Double(n) }
        let i0 = Int(p) % n
        let i1 = (i0 + 1) % n
        let frac = p - floor(p)
        return buf[i0] * (1 - frac) + buf[i1] * frac
    }
}
