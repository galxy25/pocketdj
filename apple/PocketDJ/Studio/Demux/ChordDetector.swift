import Foundation
import Accelerate
import AVFoundation

/// On-device DOMINANT-CHORD detection for the Demuxer: the whole file → a timeline of maj/min
/// triad segments. KeyDetector's chromagram folded PER FRAME instead of over the whole take,
/// then each frame is template-matched against the 24 triads and the frame labels are smoothed
/// (majority vote) + merged into segments — so a verse in Am reads as one long "Am" block, not
/// 400 jittery frames.
///
/// STREAMS the file in blocks (never decodes the whole song into one buffer — a 6-minute float
/// PCM decode is >100 MB), so it's safe for full-length tracks. All `nonisolated` statics —
/// run it OFF the main actor (`Task.detached`, the StudioAnalyzer pattern).
enum ChordDetector {

    // Frame geometry: 4096-sample frames, no overlap (~93 ms @ 44.1 kHz). Chords live at the
    // 0.5 s+ scale, so the resolution goes into the SMOOTHING window, not the hop.
    private static let fftSize = 4096
    /// Chroma folding band: E1 bass fundamentals up to ~1.3 kHz — above that it's mostly
    /// cymbals + harmonics that smear the triad (narrower than KeyDetector's key band).
    private static let bandLo = 41.0, bandHi = 1_320.0
    /// Majority-vote window (frames): ~0.8 s — flattens beat-level jitter, keeps 1-bar changes.
    private static let smoothWindow = 9
    /// Segments shorter than this merge into their neighbor (a chord you can't hear isn't one).
    private static let minSegmentMs = 500
    /// A frame whose best template match is below this is "no chord" (noise / drums / silence).
    private static let minScore = 0.55
    /// RMS floor below which a frame is silence.
    private static let minRMS: Float = 0.005
    /// Analysis cap — bounds worst-case CPU on an accidental 2-hour file.
    private static let maxSeconds = 20.0 * 60.0

    // MARK: - Public entry

    /// Detect the chord timeline of an audio file. Returns segments ordered by start time
    /// (gaps = no confident chord). Empty when the file is unreadable or nothing is tonal.
    nonisolated static func detect(url: URL) -> [DemuxChordSegment] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let sr = file.processingFormat.sampleRate
        guard sr > 0, file.length > 0 else { return [] }
        let frames = chromaFrames(file: file)
        let frameMs = Double(fftSize) / sr * 1_000
        return segments(from: frames, frameMs: frameMs)
    }

    // MARK: - Framewise chroma (streamed)

    struct ChromaFrame {
        var chroma: [Double]   // 12 pitch-class magnitudes
        var rms: Float
    }

    /// Stream the file block-by-block, emitting one 12-bin chroma per fftSize frames.
    private nonisolated static func chromaFrames(file: AVAudioFile) -> [ChromaFrame] {
        let format = file.processingFormat
        let sr = format.sampleRate
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let half = fftSize / 2

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Bin → pitch class map for THIS sample rate (−1 = outside the chord band).
        var binPC = [Int](repeating: -1, count: half)
        for k in 1..<half {
            let freq = Double(k) * sr / Double(fftSize)
            guard freq >= bandLo, freq <= bandHi else { continue }
            let midi = 69.0 + 12.0 * log2(freq / 440.0)
            binPC[k] = ((Int(midi.rounded()) % 12) + 12) % 12
        }

        let blockFrames = AVAudioFrameCount(fftSize * 32)   // ~3 s reads
        guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else { return [] }
        let maxTotal = AVAudioFramePosition(sr * maxSeconds)

        var windowed = [Float](repeating: 0, count: fftSize)
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        var mono = [Float]()                        // carry across block boundaries
        var out: [ChromaFrame] = []
        var consumed: AVAudioFramePosition = 0

        while consumed < min(file.length, maxTotal) {
            block.frameLength = 0
            guard (try? file.read(into: block, frameCount: blockFrames)) != nil, block.frameLength > 0 else { break }
            consumed += AVAudioFramePosition(block.frameLength)
            guard let ch = block.floatChannelData else { break }
            let n = Int(block.frameLength), channels = Int(format.channelCount)
            // Mix channels down to mono, appended to the carry buffer.
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
            // Consume whole fftSize frames from the carry.
            var pos = 0
            while pos + fftSize <= mono.count {
                var rms: Float = 0
                mono.withUnsafeBufferPointer { mp in
                    vDSP_rmsqv(mp.baseAddress! + pos, 1, &rms, vDSP_Length(fftSize))
                    vDSP_vmul(mp.baseAddress! + pos, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
                }
                var chroma = [Double](repeating: 0, count: 12)
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
                for k in 1..<half where binPC[k] >= 0 { chroma[binPC[k]] += Double(mag[k]) }
                out.append(ChromaFrame(chroma: chroma, rms: rms))
                pos += fftSize
            }
            mono.removeFirst(pos)
        }
        return out
    }

    // MARK: - Template matching

    /// Frame label: 0…11 = major root pc, 12…23 = minor root pc (index−12), nil = no chord.
    struct FrameLabel { var index: Int?; var score: Double }

    /// The 24 triad templates, L2-normalized. Root weighted above fifth above third (the third
    /// is quietest in real voicings but is what separates maj/min — keep it present, not loud).
    nonisolated static let templates: [[Double]] = {
        var t: [[Double]] = []
        for minor in [false, true] {
            for root in 0..<12 {
                var v = [Double](repeating: 0, count: 12)
                v[root] = 1.0
                v[(root + (minor ? 3 : 4)) % 12] = 0.8
                v[(root + 7) % 12] = 0.9
                let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
                t.append(v.map { $0 / norm })
            }
        }
        return t
    }()

    /// Best triad for one chroma frame (cosine similarity), or nil under the floors.
    nonisolated static func match(chroma: [Double], rms: Float) -> FrameLabel {
        guard rms >= minRMS else { return FrameLabel(index: nil, score: 0) }
        let norm = sqrt(chroma.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return FrameLabel(index: nil, score: 0) }
        let unit = chroma.map { $0 / norm }
        var best = -1.0, bestIdx = 0
        for (i, tmpl) in templates.enumerated() {
            var dot = 0.0
            for j in 0..<12 { dot += unit[j] * tmpl[j] }
            if dot > best { best = dot; bestIdx = i }
        }
        return best >= minScore ? FrameLabel(index: bestIdx, score: best)
                                : FrameLabel(index: nil, score: best)
    }

    // MARK: - Smoothing + segmentation

    /// Frame labels → majority-vote smoothing → merged, min-length segments.
    nonisolated static func segments(from frames: [ChromaFrame], frameMs: Double) -> [DemuxChordSegment] {
        guard !frames.isEmpty, frameMs > 0 else { return [] }
        let raw = frames.map { match(chroma: $0.chroma, rms: $0.rms) }

        // Majority vote over a centered window (no-chord frames vote too — a real gap survives).
        var voted = [Int?](repeating: nil, count: raw.count)
        let halfWin = smoothWindow / 2
        for i in raw.indices {
            var counts: [Int: Int] = [:]
            var nilCount = 0
            for j in max(0, i - halfWin)...min(raw.count - 1, i + halfWin) {
                if let idx = raw[j].index { counts[idx, default: 0] += 1 } else { nilCount += 1 }
            }
            if let (winner, n) = counts.max(by: { $0.value < $1.value }), n >= nilCount {
                voted[i] = winner
            }
        }

        // Merge runs into segments, tracking mean score per run.
        struct Run { var index: Int; var start: Int; var end: Int; var scoreSum: Double; var n: Int }
        var runs: [Run] = []
        for (i, label) in voted.enumerated() {
            guard let idx = label else { continue }
            let score = raw[i].score
            if var last = runs.last, last.index == idx, last.end == i {
                last.end = i + 1; last.scoreSum += score; last.n += 1
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(index: idx, start: i, end: i + 1, scoreSum: score, n: 1))
            }
        }

        // Drop sub-minSegmentMs blips (they were jitter the vote couldn't kill).
        let minFrames = max(1, Int(Double(minSegmentMs) / frameMs))
        let kept = runs.filter { $0.end - $0.start >= minFrames }

        return kept.map { run in
            DemuxChordSegment(rootPC: run.index % 12,
                              minor: run.index >= 12,
                              startMs: Int(Double(run.start) * frameMs),
                              endMs: Int(Double(run.end) * frameMs),
                              confidence: run.n > 0 ? run.scoreSum / Double(run.n) : 0)
        }
    }
}
