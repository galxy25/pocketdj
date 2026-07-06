import Foundation
import Accelerate
import AVFoundation

/// On-device beat-grid / tempo detection (Studio round 4). The app previously only CONSUMED grids —
/// real detection was server-side librosa (`.claude/skills/analog-indexer/audio/analyze-beatgrid.py`).
/// This ports that pass's essential path to Accelerate/vDSP so an IMPORTED or MIC sample — which has
/// no server `analysis-<id>.json` sidecar to inherit — can still get a tempo for auto-slicing:
///
///   spectral-flux onset envelope → autocorrelation tempo (log-normal prior centred on 120 BPM)
///   → octave-fold into the DJ window [70,180] → onset-energy downbeat phase (4/4).
///
/// Output is a CONSTANT `StudioGrid` (bpm + firstDownbeatMs, empty `beatsMs`) — exactly what the
/// loop-/sample-slice math (`BeatMath.sliceBoundaries`) needs; per-beat drift tracking stays a
/// server-only refinement. All `nonisolated` statics + value types: run it OFF the main actor. The
/// caller decodes the file via `StudioRender.decodeFileSync` (pure file I/O — touches no
/// AVAudioSession, so this is session-policy-safe by construction).
enum BeatDetect {
    /// Matches the server analyzer's DJ-usable window: fold 2×/½ octave errors into [70,180].
    static let bpmLo = 70.0
    static let bpmHi = 180.0
    /// The autocorrelation SEARCH range is wider than the report window: like the librosa pass, we
    /// detect the true fundamental tempo (a 60 BPM ballad, a 200 BPM DnB) THEN octave-fold it into
    /// [70,180]. Searching only [70,180] can't see a sub-70 fundamental at all — there is simply no
    /// autocorrelation energy at any in-window lag for it (a pulse train correlates only at integer
    /// multiples of its period). The 120-centred prior below still picks the musical octave.
    private static let searchBpmLo = 55.0
    private static let searchBpmHi = 210.0
    private static let beatsPerBar = 4

    /// STFT framing. hop 512 @ 44.1 kHz ≈ 86 fps — fine enough to place a beat within ~12 ms.
    private static let hop = 512
    private static let fftSize = 1024
    /// Cap analysis cost on very long imports: tempo is stationary enough that the head is
    /// representative, and an hour-long file shouldn't spin the CPU. (librosa loads the whole file;
    /// we only need a stable tempo, not the tail.)
    private static let maxAnalysisSeconds = 120.0
    /// Log2 spread of the tempo prior (a Gaussian in log-tempo centred on 120 BPM) — ~1 octave.
    /// This is what makes the autocorrelation pick the musical tempo over its ½/2× harmonics.
    private static let priorCenterBpm = 120.0
    private static let priorSpread = 1.0

    // MARK: - Public entry

    /// Detect a constant beat grid from a decoded PCM buffer (sample rate read from the buffer).
    /// Returns nil when the audio is too short/quiet/aperiodic to place a tempo — the caller keeps
    /// the sample grid-less (manual tap-tempo stays available).
    nonisolated static func detectGrid(_ buffer: AVAudioPCMBuffer) -> StudioGrid? {
        let sr = buffer.format.sampleRate
        guard sr > 0, let mono = monoSamples(buffer, maxSeconds: maxAnalysisSeconds) else { return nil }
        guard mono.count >= Int(sr * 2) else { return nil }        // < 2 s: not enough to lock a tempo

        let env = onsetEnvelope(mono)
        guard env.count >= 16 else { return nil }
        let frameRate = sr / Double(hop)

        guard let (periodFrames, bpmRaw) = estimateTempo(env, frameRate: frameRate) else { return nil }
        let bpm = octaveFold(bpmRaw)

        // Beat phase: the offset in [0, period) whose lattice lands on the most onset energy, then
        // the bar-phase (of 4) whose beats are strongest = the downbeat.
        let (firstBeatFrame, downbeatPhase) = estimatePhase(env, period: periodFrames)
        let firstDownbeatFrame = firstBeatFrame + downbeatPhase * periodFrames
        let firstDownbeatMs = Int((Double(firstDownbeatFrame) * Double(hop) / sr * 1000).rounded())

        return StudioGrid(bpm: (bpm * 100).rounded() / 100, firstDownbeatMs: max(0, firstDownbeatMs))
    }

    /// Halve/double a BPM until it lands in [lo, hi] — identical rule to `analyze-beatgrid.py`'s
    /// `octave_fold`. Kills the 2×/½ detection errors that would otherwise clock loops an octave off.
    nonisolated static func octaveFold(_ bpm: Double, lo: Double = bpmLo, hi: Double = bpmHi) -> Double {
        guard bpm > 0 else { return bpm }
        var b = bpm
        while b < lo { b *= 2 }
        while b > hi { b /= 2 }
        return b
    }

    // MARK: - Mono mixdown

    /// Average all channels into one Float array, capped at `maxSeconds`. nil for an empty buffer.
    private nonisolated static func monoSamples(_ buffer: AVAudioPCMBuffer, maxSeconds: Double) -> [Float]? {
        guard let ch = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return nil }
        let cap = min(frames, Int(buffer.format.sampleRate * maxSeconds))
        guard cap > 0 else { return nil }
        var mono = [Float](repeating: 0, count: cap)
        for c in 0..<channels {                                    // sum then scale = mean
            vDSP_vadd(mono, 1, ch[c], 1, &mono, 1, vDSP_Length(cap))
        }
        if channels > 1 {
            var scale = 1.0 / Float(channels)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(cap))
        }
        return mono
    }

    // MARK: - Onset envelope (spectral flux)

    /// Half-wave-rectified spectral flux per STFT frame: Σ over bins of max(0, |X_t| − |X_{t−1}|).
    /// Rising magnitude = an onset; falling magnitude (a note decaying) is ignored. This is the same
    /// quantity librosa's `onset_strength` builds its beat tracker on.
    private nonisolated static func onsetEnvelope(_ x: [Float]) -> [Float] {
        let n = x.count
        guard n >= fftSize else { return [] }
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        let half = fftSize / 2
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var windowed = [Float](repeating: 0, count: fftSize)
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        var prevMag = [Float](repeating: 0, count: half)

        var env: [Float] = []
        env.reserveCapacity((n - fftSize) / hop + 1)
        var pos = 0
        var havePrev = false

        while pos + fftSize <= n {
            x.withUnsafeBufferPointer { xp in
                vDSP_vmul(xp.baseAddress! + pos, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
            }
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))     // real signal → split complex
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))          // |X| per bin
                }
            }
            if havePrev {
                var flux: Float = 0
                for k in 0..<half {
                    let d = mag[k] - prevMag[k]
                    if d > 0 { flux += d }
                }
                env.append(flux)
            }
            havePrev = true
            swap(&mag, &prevMag)          // prevMag ← this frame's |X|; mag is scratch reused next frame
            pos += hop
        }
        return env
    }

    // MARK: - Tempo (autocorrelation + tempo prior)

    /// Dominant beat period (in envelope frames) and its raw BPM. Autocorrelates the mean-removed
    /// onset envelope over the lag range spanning [70,180] BPM, weighted by a log-normal prior so a
    /// half/double-tempo harmonic doesn't win. nil when the envelope has no periodicity in-window.
    private nonisolated static func estimateTempo(_ env: [Float], frameRate: Double) -> (period: Int, bpm: Double)? {
        let n = env.count
        let minLag = max(1, Int((60.0 * frameRate / searchBpmHi).rounded()))
        let maxLag = Int((60.0 * frameRate / searchBpmLo).rounded())
        guard maxLag > minLag, n > maxLag * 2 else { return nil }

        var mean: Float = 0
        vDSP_meanv(env, 1, &mean, vDSP_Length(n))
        let e = env.map { $0 - mean }                              // zero-mean: autocorr sees pulses, not DC

        var bestLag = minLag
        var bestScore = -Double.greatestFiniteMagnitude
        e.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for lag in minLag...maxLag {
                var ac: Float = 0
                vDSP_dotpr(base + lag, 1, base, 1, &ac, vDSP_Length(n - lag))   // Σ e[t]·e[t−lag]
                let bpm = 60.0 * frameRate / Double(lag)
                let z = log2(bpm / priorCenterBpm) / priorSpread
                let prior = exp(-0.5 * z * z)
                let score = Double(ac) * prior
                if score > bestScore { bestScore = score; bestLag = lag }
            }
        }
        guard bestScore > 0 else { return nil }                    // no in-window periodicity
        return (bestLag, 60.0 * frameRate / Double(bestLag))
    }

    // MARK: - Phase + downbeat

    /// Beat phase (frame offset of beat 1) and the bar-phase (0…3) that carries the most onset
    /// energy = the downbeat. Pure integer walks over the envelope; deterministic.
    private nonisolated static func estimatePhase(_ env: [Float], period: Int) -> (firstBeat: Int, downbeatPhase: Int) {
        let n = env.count
        guard period > 0, n > 0 else { return (0, 0) }

        var bestPhase = 0
        var bestSum: Float = -1
        for phase in 0..<period {
            var s: Float = 0
            var i = phase
            while i < n { s += env[i]; i += period }
            if s > bestSum { bestSum = s; bestPhase = phase }
        }

        var beats: [Int] = []
        var i = bestPhase
        while i < n { beats.append(i); i += period }

        var bestDown = 0
        var bestScore: Float = -1
        for p in 0..<beatsPerBar {
            var sum: Float = 0
            var cnt = 0
            var k = p
            while k < beats.count { sum += env[beats[k]]; cnt += 1; k += beatsPerBar }
            let m = cnt > 0 ? sum / Float(cnt) : -1
            if m > bestScore { bestScore = m; bestDown = p }
        }
        return (bestPhase, bestDown)
    }
}
