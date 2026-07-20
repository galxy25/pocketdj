import Foundation
import Accelerate
import AVFoundation

/// On-device DRUM-PATTERN extraction for the Demuxer: the DRUMS stem (+ optionally the BASS
/// stem) → classified, timestamped hits. Spectral-flux onset detection (the `BeatDetect`
/// envelope recipe, kept per-frame here) with adaptive peak-picking, then each hit is classed
/// kick / snare / percussive / other from its attack's band-energy split; the bass stem runs a
/// low-band-only pass whose hits are all `.bass` (its own lane in the pattern grid).
///
/// STREAMS each file in blocks (never decodes a whole song into one buffer — the ChordDetector
/// doctrine), hop-overlapped for onset-grade time resolution (~12 ms @ 44.1 kHz). All
/// `nonisolated` statics — run OFF the main actor (`Task.detached`, the StudioAnalyzer pattern).
enum DrumPatternDetector {

    // Frame geometry: 1024-sample windows, 512 hop (~86 fps @ 44.1 kHz). Onsets live at the
    // 10 ms scale — the opposite trade from ChordDetector's chord-scale frames.
    private static let fftSize = 1024
    private static let hop = 512

    /// Band split for hit classification (Hz): kick fundamentals below `lowHi`, snare
    /// body/crack in the mid band, hats/cymbals above `highLo`.
    private static let lowHi = 160.0
    private static let midHi = 2_000.0
    private static let highLo = 4_000.0
    /// Bass-stem pass: flux restricted to fundamentals below this (the rest of a bass stem's
    /// spectrum is bleed + harmonics that would double-trigger).
    private static let bassBandHi = 400.0

    /// Peak picking: a frame is an onset when its flux is the local max over ±`peakRadius`,
    /// exceeds `meanFactor`× the local mean (±`meanWindow`), clears `floorFactor`× the file's
    /// max flux, and sits ≥ `minGapMs` after the previous onset (double-trigger guard).
    private static let peakRadius = 3
    private static let meanWindow = 8
    private static let meanFactor: Float = 1.4
    private static let floorFactor: Float = 0.03
    private static let minGapMs = 45.0

    /// Attack window (frames from the onset, inclusive) whose band energies classify the hit.
    private static let attackFrames = 3

    /// Analysis cap — bounds worst-case CPU on an accidental 2-hour file (ChordDetector's cap).
    private static let maxSeconds = 20.0 * 60.0

    // MARK: - Public entry

    /// Detect the classified hit list for a track: drums-stem onsets classed by spectrum plus,
    /// when a bass stem is given, its onsets as `.bass`. Sorted by time. Empty when nothing
    /// confident was found (the caller maps that to `.failed`).
    nonisolated static func detect(drumsURL: URL, bassURL: URL?) -> [DemuxDrumHit] {
        var hits = onsets(url: drumsURL, fluxBandHi: nil, kindOverride: nil)
        if let bassURL {
            hits += onsets(url: bassURL, fluxBandHi: bassBandHi, kindOverride: .bass)
        }
        return hits.sorted { $0.ms < $1.ms }
    }

    // MARK: - Per-file onset pass (streamed STFT → flux + band energies → picked hits)

    /// One file's onset pass. `fluxBandHi` restricts the flux to bins below that frequency
    /// (the bass-stem mode); `kindOverride` skips spectral classing (every hit is that kind).
    nonisolated static func onsets(url: URL, fluxBandHi: Double?, kindOverride: DemuxDrumKind?)
        -> [DemuxDrumHit] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let sr = file.processingFormat.sampleRate
        guard sr > 0, file.length > 0 else { return [] }
        let frames = fluxFrames(file: file, fluxBandHi: fluxBandHi)
        let frameMs = Double(hop) / sr * 1_000
        return pickHits(frames: frames, frameMs: frameMs, kindOverride: kindOverride)
    }

    /// One STFT frame's onset features.
    struct FluxFrame {
        /// Half-wave-rectified spectral flux vs the previous frame (the onset envelope sample).
        var flux: Float
        /// Attack-band energies (Σ mag² over the band's bins) for classification.
        var low: Float
        var mid: Float
        var high: Float
    }

    /// Stream the file hop-by-hop, emitting flux + band energies per frame (the ChordDetector
    /// block-reader with overlap carry).
    private nonisolated static func fluxFrames(file: AVAudioFile, fluxBandHi: Double?) -> [FluxFrame] {
        let format = file.processingFormat
        let sr = format.sampleRate
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let half = fftSize / 2

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Bin → band edges for THIS sample rate.
        let binHz = sr / Double(fftSize)
        let lowEnd = max(1, min(half, Int(lowHi / binHz)))
        let midEnd = max(lowEnd, min(half, Int(midHi / binHz)))
        let highStart = max(midEnd, min(half, Int(highLo / binHz)))
        let fluxEnd = fluxBandHi.map { max(2, min(half, Int($0 / binHz))) } ?? half

        let blockFrames = AVAudioFrameCount(fftSize * 32)   // ~0.7 s reads at 1024
        guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else { return [] }
        let maxTotal = AVAudioFramePosition(sr * maxSeconds)

        var windowed = [Float](repeating: 0, count: fftSize)
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        var prevMag = [Float](repeating: 0, count: half)
        var havePrev = false
        var mono = [Float]()                        // carry across block boundaries (overlap too)
        var out: [FluxFrame] = []
        var consumed: AVAudioFramePosition = 0

        while consumed < min(file.length, maxTotal) {
            block.frameLength = 0
            guard (try? file.read(into: block, frameCount: blockFrames)) != nil, block.frameLength > 0 else { break }
            consumed += AVAudioFramePosition(block.frameLength)
            guard let ch = block.floatChannelData else { break }
            let n = Int(block.frameLength), channels = Int(format.channelCount)
            let base = mono.count
            mono.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
            if channels > 1 {
                mono.withUnsafeMutableBufferPointer { mp in
                    for c in 1..<channels {
                        vDSP_vadd(mp.baseAddress! + base, 1, ch[c], 1, mp.baseAddress! + base, 1, vDSP_Length(n))
                    }
                    var scale = 1.0 / Float(channels)
                    vDSP_vsmul(mp.baseAddress! + base, 1, &scale, mp.baseAddress! + base, 1, vDSP_Length(n))
                }
            }
            // Consume hop-sized steps; each frame windows fftSize samples (hop overlap).
            var pos = 0
            while pos + fftSize <= mono.count {
                mono.withUnsafeBufferPointer { mp in
                    vDSP_vmul(mp.baseAddress! + pos, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
                }
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        windowed.withUnsafeBufferPointer { wp in
                            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                                vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                    }
                }
                var flux: Float = 0
                if havePrev {
                    for k in 1..<fluxEnd {
                        let d = mag[k] - prevMag[k]
                        if d > 0 { flux += d }
                    }
                }
                var low: Float = 0, mid: Float = 0, high: Float = 0
                for k in 1..<lowEnd { low += mag[k] * mag[k] }
                for k in lowEnd..<midEnd { mid += mag[k] * mag[k] }
                for k in highStart..<half { high += mag[k] * mag[k] }
                out.append(FluxFrame(flux: flux, low: low, mid: mid, high: high))
                swap(&prevMag, &mag)
                havePrev = true
                pos += hop
            }
            mono.removeFirst(pos)
        }
        return out
    }

    // MARK: - Peak picking + classification (pure — unit-tested on synthetic frames)

    /// Adaptive-threshold peak picking over the flux envelope, then per-hit classification from
    /// the attack's band-energy split. Strengths are normalized to the file's loudest onset.
    nonisolated static func pickHits(frames: [FluxFrame], frameMs: Double,
                                     kindOverride: DemuxDrumKind?) -> [DemuxDrumHit] {
        guard frames.count > 2, frameMs > 0 else { return [] }
        let flux = frames.map(\.flux)
        guard let maxFlux = flux.max(), maxFlux > 0 else { return [] }
        let floor = maxFlux * floorFactor
        let minGapFrames = max(1, Int(minGapMs / frameMs))

        var hits: [DemuxDrumHit] = []
        var lastOnset = -minGapFrames
        for i in flux.indices {
            let f = flux[i]
            guard f > floor else { continue }
            // Local max over ±peakRadius (ties break to the earlier frame — strict > after i).
            var isPeak = true
            for j in max(0, i - peakRadius)...min(flux.count - 1, i + peakRadius) where j != i {
                if flux[j] > f || (flux[j] == f && j < i) { isPeak = false; break }
            }
            guard isPeak else { continue }
            // Adaptive mean threshold over ±meanWindow.
            var sum: Float = 0; var n = 0
            for j in max(0, i - meanWindow)...min(flux.count - 1, i + meanWindow) {
                sum += flux[j]; n += 1
            }
            guard n > 0, f > (sum / Float(n)) * meanFactor else { continue }
            guard i - lastOnset >= minGapFrames else { continue }
            lastOnset = i

            let kind = kindOverride ?? classify(frames: frames, onset: i)
            hits.append(DemuxDrumHit(ms: Int(Double(i) * frameMs),
                                     kind: kind,
                                     strength: Double(f / maxFlux)))
        }
        return hits
    }

    /// Class a hit from its attack's band-energy ratios: low-dominant → kick; clearly top-heavy
    /// → percussive (hats/cymbals); broadband mid → snare; the rest (toms, congas, FX) → other.
    nonisolated static func classify(frames: [FluxFrame], onset: Int) -> DemuxDrumKind {
        var low: Float = 0, mid: Float = 0, high: Float = 0
        for j in onset...min(frames.count - 1, onset + attackFrames) {
            low += frames[j].low; mid += frames[j].mid; high += frames[j].high
        }
        let total = low + mid + high
        guard total > 0 else { return .other }
        let rLow = low / total, rMid = mid / total, rHigh = high / total
        if rLow >= 0.40 { return .kick }
        if rHigh >= 0.60 { return .percussive }
        if rMid >= 0.30 { return .snare }
        if rHigh >= 0.40 { return .percussive }
        return .other
    }

    // MARK: - Bars + quantization (pure — the grid the pattern view and export share)

    /// One bar of the song's timeline (ms bounds on the stem/song clock).
    struct Bar: Hashable, Sendable, Identifiable {
        var index: Int
        var startMs: Int
        var endMs: Int
        var id: Int { index }
    }

    /// Hard cap on rendered bars (a 2-hour file at 170 BPM would otherwise mint thousands).
    static let maxBars = 512

    /// The song's bar list. Measured DOWNBEATS when the sidecar has ≥ 2 (real bar lines, tempo
    /// drift included; the tail extends at the median bar length) — else constant bars from the
    /// scalar bpm anchored at `firstDownbeatMs`. Empty without any tempo (caller shows a hint).
    nonisolated static func bars(downbeatsMs: [Int], bpm: Double?, firstDownbeatMs: Int?,
                                 durationMs: Int) -> [Bar] {
        var out: [Bar] = []
        let downs = downbeatsMs.filter { $0 >= 0 && $0 < durationMs }.sorted()
        if downs.count >= 2 {
            for i in 0..<(downs.count - 1) where out.count < maxBars {
                out.append(Bar(index: out.count, startMs: downs[i], endMs: downs[i + 1]))
            }
            // Extend past the last measured downbeat at the median bar length.
            let lengths = zip(downs.dropFirst(), downs).map { $0 - $1 }.sorted()
            let median = lengths[lengths.count / 2]
            var start = downs.last ?? 0
            while median > 0, start + median / 2 < durationMs, out.count < maxBars {
                out.append(Bar(index: out.count, startMs: start, endMs: start + median))
                start += median
            }
            return out
        }
        guard let bpm, bpm > 0 else { return [] }
        let barLen = Int((240_000.0 / bpm).rounded())
        guard barLen > 0 else { return [] }
        var start = max(0, firstDownbeatMs ?? 0)
        // A late first downbeat pulls whole bars back to (near) 0 so the intro isn't dropped.
        while start - barLen >= 0 { start -= barLen }
        while start + barLen / 2 < durationMs, out.count < maxBars {
            out.append(Bar(index: out.count, startMs: start, endMs: start + barLen))
            start += barLen
        }
        return out
    }

    /// Quantize hits onto per-bar 16-step lanes. A hit rounds to its NEAREST 16th — one landing
    /// on a bar's far edge belongs to the NEXT bar's step 0 (the early-push case), so the grid
    /// is computed globally, not per-bar.
    nonisolated static func stepGrid(hits: [DemuxDrumHit], bars: [Bar])
        -> [[DemuxDrumKind: [Bool]]] {
        var grid = Array(repeating: [DemuxDrumKind: [Bool]](), count: bars.count)
        guard !bars.isEmpty else { return grid }
        for hit in hits {
            guard let bi = barIndex(forMs: hit.ms, bars: bars) else { continue }
            let bar = bars[bi]
            let len = max(1, bar.endMs - bar.startMs)
            var slot = Int((Double(hit.ms - bar.startMs) / Double(len) * 16).rounded())
            var target = bi
            if slot >= 16 {
                target = bi + 1
                slot = 0
                guard target < bars.count else { continue }
            }
            if slot < 0 { slot = 0 }
            var lane = grid[target][hit.kind] ?? Array(repeating: false, count: 16)
            lane[slot] = true
            grid[target][hit.kind] = lane
        }
        return grid
    }

    /// The bar containing `ms` (bars are sorted + contiguous; binary search).
    nonisolated static func barIndex(forMs ms: Int, bars: [Bar]) -> Int? {
        var lo = 0, hi = bars.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if ms < bars[mid].startMs { hi = mid - 1 }
            else if ms >= bars[mid].endMs { lo = mid + 1 }
            else { return mid }
        }
        return nil
    }

    // MARK: - Grid fallback (custom sources with no analysis sidecar)

    /// Estimate a constant grid from the first `capSeconds` of a file (`BeatDetect` over a
    /// bounded decode — never the whole song into memory). Used when no measured sidecar exists.
    nonisolated static func gridEstimate(url: URL, capSeconds: Double = 90) -> StudioGrid? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.processingFormat.sampleRate
        guard sr > 0, file.length > 0 else { return nil }
        let frames = AVAudioFrameCount(min(Double(file.length), sr * capSeconds))
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            return nil
        }
        guard (try? file.read(into: buf, frameCount: frames)) != nil, buf.frameLength > 0 else { return nil }
        return BeatDetect.detectGrid(buf)
    }
}
