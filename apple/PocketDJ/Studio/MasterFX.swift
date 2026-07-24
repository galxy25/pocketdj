import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Master FX (arranger master bus)
//
// The four effects the Mix tab doesn't have — phaser, ring modulator, freezer, Brazilian bass lift
// — plus the overall master gain, run over the summed arrangement. There is NO effect DSP anywhere
// else in the app (every Mix effect is an Apple built-in AVAudioUnit), so this is the project's
// first custom render-block DSP. ONE `MasterFXKernel` holds the math + state and is shared by two
// callers so live playback and a bounce can never drift: `MasterFXAudioUnit` (a v3 AUAudioUnit
// inserted live in MultitrackPlayer's graph) and `ArrangerBouncer` (offline, over the summed
// buffer). Freeze is a live capture-and-hold, so it's bypassed when baking (a static "freeze" of a
// whole bounce is meaningless); the other three + master gain are deterministic and bake WYSIWYG.

/// The DSP-relevant snapshot of `StudioMasterFX` (+ tempo + master gain). A plain value type read on
/// the audio thread — a torn read of a Double during a knob drag is benign (worst case one glitchy
/// sample), so no lock is taken.
struct MasterFXParams: Sendable, Equatable {
    var phaser = false; var phaserRate = 0.5; var phaserDepth = 0.6
    var ringMod = false; var ringFreq = 200.0; var ringMix = 0.5
    var freeze = false
    var brazil = false; var brazilAmount = 0.6
    var masterGain = 1.0            // linear (from masterGainDb)
    var bpm = 120.0

    var active: Bool { phaser || ringMod || freeze || brazil || abs(masterGain - 1) > 0.001 }

    init() {}
    /// `allowFreeze:false` for a bounce (freeze is a live-only hold).
    init(_ fx: StudioMasterFX, bpm: Double, allowFreeze: Bool = true) {
        phaser = fx.phaserEnabled; phaserRate = fx.phaserRate; phaserDepth = fx.phaserDepth
        ringMod = fx.ringModEnabled; ringFreq = fx.ringModFreqHz; ringMix = fx.ringModMix
        freeze = allowFreeze && fx.freezeEnabled
        brazil = fx.brazilianBassEnabled; brazilAmount = fx.brazilianBassAmount
        masterGain = pow(10.0, max(-24.0, min(12.0, fx.masterGainDb)) / 20.0)
        self.bpm = bpm > 0 ? bpm : 120
    }
}

/// The shared master-bus DSP. Reference type: holds per-channel filter/ring state allocated once in
/// `configure`, then mutated in place by `process` — no allocation in the hot path. Effects apply in
/// order phaser → ring-mod → freeze → Brazilian-bass → master-gain (gain last, then the caller's
/// limiter). Not thread-safe by design: params are set from the main thread, `process` runs on the
/// audio thread; value-type param reads make that safe enough for a personal tool.
final class MasterFXKernel: @unchecked Sendable {
    private var sr = 44_100.0
    private var channels = 2
    private var p = MasterFXParams()

    private let stages = 4
    private var lfoPhase = 0.0
    private var ringPhase = 0.0
    private var apX: [[Double]] = []       // per-channel all-pass state (x[n-1] per stage)
    private var apY: [[Double]] = []       // per-channel all-pass state (y[n-1] per stage)
    private var freezeBuf: [[Float]] = []  // per-channel rolling 0.25 s capture ring
    private var freezeWrite: [Int] = []
    private var freezeRead: [Int] = []
    private var freezeLen = 1
    private var wasFrozen = false
    private var subLP: [Double] = []       // per-channel one-pole sub low-pass state
    private var chanPtrs: [UnsafeMutablePointer<Float>?] = []   // reused per-render (no alloc)

    func configure(sampleRate: Double, channelCount: Int) {
        sr = sampleRate > 0 ? sampleRate : 44_100
        channels = max(1, channelCount)
        freezeLen = max(1, Int(sr * 0.25))
        apX = Array(repeating: Array(repeating: 0, count: stages), count: channels)
        apY = Array(repeating: Array(repeating: 0, count: stages), count: channels)
        freezeBuf = Array(repeating: Array(repeating: 0, count: freezeLen), count: channels)
        freezeWrite = Array(repeating: 0, count: channels)
        freezeRead = Array(repeating: 0, count: channels)
        subLP = Array(repeating: 0, count: channels)
        chanPtrs = Array(repeating: nil, count: channels)
        lfoPhase = 0; ringPhase = 0; wasFrozen = false
    }

    func update(_ params: MasterFXParams) { p = params }

    /// Live entry: process an AudioBufferList in place (non-interleaved Float32).
    func processABL(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: Int, framePos: Double) {
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        let n = min(bufs.count, chanPtrs.count)
        guard n > 0 else { return }
        for c in 0..<n {
            chanPtrs[c] = bufs[c].mData?.assumingMemoryBound(to: Float.self)
        }
        for c in n..<chanPtrs.count { chanPtrs[c] = nil }
        process(frames: frames, framePos: framePos, activeChannels: n)
    }

    /// Offline entry: process a canonical buffer's `floatChannelData` in place (outer pointer is
    /// const — the channel array — inner pointers are the mutable samples).
    func processFloatChannels(_ data: UnsafePointer<UnsafeMutablePointer<Float>>,
                              channelCount: Int, frames: Int, framePos: Double) {
        let n = min(channelCount, chanPtrs.count)
        for c in 0..<n { chanPtrs[c] = data[c] }
        for c in n..<chanPtrs.count { chanPtrs[c] = nil }
        process(frames: frames, framePos: framePos, activeChannels: n)
    }

    private func process(frames: Int, framePos: Double, activeChannels n: Int) {
        guard n > 0 else { return }
        let params = p                          // one read; stable for this block
        guard params.active else {
            // Neutral ⇒ passthrough, BUT keep the freeze capture ring warm so enabling ONLY the
            // Freezer (the master otherwise dry) holds the last 0.25 s of REAL audio, not the stale
            // zero-filled ring. Cheap: one copy per sample, output untouched.
            for i in 0..<frames {
                for c in 0..<n {
                    guard let d = chanPtrs[c] else { continue }
                    freezeBuf[c][freezeWrite[c]] = d[i]
                    freezeWrite[c] = (freezeWrite[c] + 1) % freezeLen
                }
            }
            wasFrozen = false
            return
        }
        let lfoInc = 2 * .pi * max(0.02, min(8, params.phaserRate)) / sr
        let ringInc = 2 * .pi * max(20, min(4_000, params.ringFreq)) / sr
        let beatFrames = 60.0 / max(20, min(300, params.bpm)) * sr
        let subCoeff = 1 - exp(-2 * .pi * 90.0 / sr)    // one-pole ~90 Hz sub

        if params.freeze && !wasFrozen { for c in 0..<n { freezeRead[c] = freezeWrite[c] } }
        wasFrozen = params.freeze

        for i in 0..<frames {
            let pos = framePos + Double(i)
            // Per-frame globals (shared across channels).
            let ringS = params.ringMod ? sin(ringPhase) : 0
            var phaserA = 0.0
            if params.phaser {
                let lfo = sin(lfoPhase)                       // mono sweep
                let f = 200.0 * pow(10.0, (lfo + 1) / 2)      // 200…2000 Hz
                let t = tan(.pi * min(0.49, f / sr))
                phaserA = (t - 1) / (t + 1)
            }
            var beatEnv = 0.0
            if params.brazil {
                var ph = pos.truncatingRemainder(dividingBy: beatFrames) / beatFrames
                if ph < 0 { ph += 1 }
                beatEnv = (1 - ph); beatEnv *= beatEnv       // quadratic decay from each beat
            }

            for c in 0..<n {
                guard let d = chanPtrs[c] else { continue }
                var x = Double(d[i])
                if params.phaser {
                    var s = x
                    for st in 0..<stages {
                        let y = phaserA * s + apX[c][st] - phaserA * apY[c][st]
                        apX[c][st] = s; apY[c][st] = y
                        s = y
                    }
                    let wet = 0.5 * (x + s)                    // dry + all-pass = notches
                    x = x * (1 - params.phaserDepth) + wet * params.phaserDepth
                }
                if params.ringMod {
                    x = x * (1 - params.ringMix) + (x * ringS) * params.ringMix
                }
                if params.freeze {
                    x = Double(freezeBuf[c][freezeRead[c]])
                    freezeRead[c] = (freezeRead[c] + 1) % freezeLen
                } else {
                    freezeBuf[c][freezeWrite[c]] = Float(x)
                    freezeWrite[c] = (freezeWrite[c] + 1) % freezeLen
                }
                if params.brazil {
                    subLP[c] += subCoeff * (x - subLP[c])
                    x += params.brazilAmount * beatEnv * subLP[c] * 1.6   // fat sub on each beat
                }
                x *= params.masterGain
                d[i] = Float(max(-1.8, min(1.8, x)))          // soft clamp; the limiter finishes
            }

            if params.phaser { lfoPhase += lfoInc; if lfoPhase > 2 * .pi { lfoPhase -= 2 * .pi } }
            if params.ringMod { ringPhase += ringInc; if ringPhase > 2 * .pi { ringPhase -= 2 * .pi } }
        }
    }
}

// MARK: - Live AUAudioUnit wrapper

/// A v3 AUAudioUnit that runs `MasterFXKernel` in its render block — the inserted node between the
/// arranger's summed master and the peak-limiter. Registered once and instantiated via
/// `AVAudioUnit.instantiate`. If instantiation ever fails, MultitrackPlayer falls back to a chain
/// without it (effects simply don't apply live; the bounce still bakes them), so playback never
/// depends on this succeeding.
final class MasterFXAudioUnit: AUAudioUnit {
    let kernel = MasterFXKernel()
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!
    private var scratch: [UnsafeMutablePointer<Float>] = []
    private var scratchFrames = 0
    private var scratchChannels = 0

    static let desc = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x70646d78,       // 'pdmx'
        componentManufacturer: 0x50646a78,  // 'Pdjx'
        componentFlags: 0, componentFlagsMask: 0)

    private static var registered = false
    static func registerIfNeeded() {
        guard !registered else { return }
        registered = true
        AUAudioUnit.registerSubclass(MasterFXAudioUnit.self, as: desc,
                                     name: "PocketDJ Master FX", version: 1)
    }

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let fmt = StudioAudio.canonicalFormat
        _inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input,
                                           busses: [try AUAudioUnitBus(format: fmt)])
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output,
                                            busses: [try AUAudioUnitBus(format: fmt)])
    }

    override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let fmt = outputBusses[0].format
        kernel.configure(sampleRate: fmt.sampleRate, channelCount: Int(fmt.channelCount))
        // Scratch memory for the (rare) case the host passes null output buffers.
        scratchFrames = Int(maximumFramesToRender)
        scratchChannels = Int(fmt.channelCount)
        scratch = (0..<scratchChannels).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames)
        }
    }

    override func deallocateRenderResources() {
        for p in scratch { p.deallocate() }
        scratch = []
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel
        let scratch = self.scratch
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            // Give any null output buffers a home before pulling input into them.
            for i in 0..<abl.count where abl[i].mData == nil && i < scratch.count {
                abl[i].mData = UnsafeMutableRawPointer(scratch[i])
                abl[i].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
            }
            var flags = AudioUnitRenderActionFlags()
            let err = pullInputBlock?(&flags, timestamp, frameCount, 0, outputData) ?? kAudioUnitErr_NoConnection
            if err != noErr { return err }
            kernel.processABL(outputData, frames: Int(frameCount), framePos: timestamp.pointee.mSampleTime)
            return noErr
        }
    }

    /// Instantiate the effect node (async, per Apple's AVAudioUnit contract). Returns the node + its
    /// kernel-bearing AU, or nil if creation failed (caller then routes around it).
    static func make() async -> (AVAudioUnit, MasterFXAudioUnit)? {
        registerIfNeeded()
        return await withCheckedContinuation { cont in
            AVAudioUnit.instantiate(with: desc, options: []) { node, _ in
                if let node, let au = node.auAudioUnit as? MasterFXAudioUnit {
                    cont.resume(returning: (node, au))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
