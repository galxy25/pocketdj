import Foundation
import Accelerate
import AVFoundation

/// On-device musical KEY detection → Camelot code, for PERFORMANCE MEDIA (which carry no server
/// key). Two front doors feed one back end:
///   • MIDI notes (instrumentals): an EXACT pitch-class histogram straight from the played notes —
///     no audio, no ambiguity.
///   • Audio (samples / loops / sequences): a CHROMAGRAM (per-pitch-class magnitude via FFT) folded
///     from the decoded PCM.
/// Both correlate against the Krumhansl-Kessler major/minor key profiles across all 24 keys; the
/// best-correlating key maps to its Camelot code (so `MixEngine.glideParams` can harmonically mix
/// performance media). Mirrors the server's `analyze-one.py` `detect_key` (chroma → KS), ported to
/// Accelerate/vDSP. All `nonisolated` statics + value types — run it OFF the main actor.
enum KeyDetector {
    // Krumhansl-Kessler key profiles (tonic-relative pitch-class weights).
    private static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    // Camelot code per tonic pitch class (0 = C, 1 = C#, … 11 = B). Standard Camelot wheel.
    private static let majorCamelot = ["8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B"]
    private static let minorCamelot = ["5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A"]

    // MARK: - Public entry points

    /// Detect from a 12-bin pitch-class profile (any nonnegative weights; index 0 = C). Returns the
    /// Camelot code + a 0…1 confidence (the best correlation, remapped from [-1,1]). nil when empty.
    nonisolated static func detect(chroma: [Double]) -> (camelot: String, strength: Double)? {
        guard chroma.count == 12, chroma.reduce(0, +) > 0 else { return nil }
        var bestPc = 0, bestMajor = true, bestScore = -Double.greatestFiniteMagnitude
        for tonic in 0..<12 {
            // Rotate the profile so index 0 aligns with candidate tonic `tonic`.
            let rotated = (0..<12).map { chroma[($0 + tonic) % 12] }
            let cMaj = correlation(rotated, majorProfile)
            let cMin = correlation(rotated, minorProfile)
            if cMaj > bestScore { bestScore = cMaj; bestPc = tonic; bestMajor = true }
            if cMin > bestScore { bestScore = cMin; bestPc = tonic; bestMajor = false }
        }
        let camelot = bestMajor ? majorCamelot[bestPc] : minorCamelot[bestPc]
        return (camelot, max(0, min(1, (bestScore + 1) / 2)))
    }

    /// Instrumental key: an EXACT pitch-class histogram from MIDI note events, weighted by each
    /// note's sounding DURATION (a long tonic anchors the key more than a passing note), then KS.
    nonisolated static func detect(noteEvents events: [StudioNoteEvent]) -> (camelot: String, strength: Double)? {
        guard !events.isEmpty else { return nil }
        var chroma = [Double](repeating: 0, count: 12)
        for e in events {
            let dur = Double(max(1, e.offMs - e.onMs))
            chroma[((e.note % 12) + 12) % 12] += dur
        }
        return detect(chroma: chroma)
    }

    /// Audio key: a chromagram from the decoded PCM (FFT magnitude folded into 12 pitch classes),
    /// then KS. nil when the audio is too short/quiet to be tonal.
    nonisolated static func detect(audio buffer: AVAudioPCMBuffer) -> (camelot: String, strength: Double)? {
        guard let chroma = chromagram(buffer) else { return nil }
        return detect(chroma: chroma)
    }

    // MARK: - Chromagram (audio → 12-bin pitch-class magnitude)

    private static let fftSize = 4096          // ~10.8 Hz bins @ 44.1 kHz — separates adjacent low notes
    private static let hop = 2048
    private static let maxSeconds = 30.0       // tonality is stationary; the head is representative
    private static let refFreq = 440.0         // A4

    /// Fold the FFT magnitude spectrum of `buffer` into 12 pitch-class bins across the musical range
    /// (A1…~D8). Sums |X| per bin over Hann-windowed hops. nil when unreadable/silent.
    nonisolated static func chromagram(_ buffer: AVAudioPCMBuffer) -> [Double]? {
        let sr = buffer.format.sampleRate
        guard sr > 0, let mono = monoSamples(buffer, maxSeconds: maxSeconds), mono.count >= fftSize else { return nil }
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        let half = fftSize / 2

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Precompute each bin's pitch class (−1 = outside the musical band, skipped).
        var binPC = [Int](repeating: -1, count: half)
        for k in 1..<half {
            let freq = Double(k) * sr / Double(fftSize)
            guard freq >= 55, freq <= 5000 else { continue }   // A1 … ~D8
            let midi = 69.0 + 12.0 * log2(freq / refFreq)
            binPC[k] = ((Int(midi.rounded()) % 12) + 12) % 12
        }

        var windowed = [Float](repeating: 0, count: fftSize)
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        var chroma = [Double](repeating: 0, count: 12)

        var pos = 0
        while pos + fftSize <= mono.count {
            mono.withUnsafeBufferPointer { xp in
                vDSP_vmul(xp.baseAddress! + pos, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
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
            for k in 1..<half where binPC[k] >= 0 { chroma[binPC[k]] += Double(mag[k]) }
            pos += hop
        }
        return chroma.reduce(0, +) > 0 ? chroma : nil
    }

    // MARK: - Helpers

    /// Pearson correlation of two equal-length vectors (0 when either is constant).
    private nonisolated static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        let den = (da * db).squareRoot()
        return den > 0 ? num / den : 0
    }

    /// Average all channels into one Float array, capped at `maxSeconds` (mirrors BeatDetect).
    private nonisolated static func monoSamples(_ buffer: AVAudioPCMBuffer, maxSeconds: Double) -> [Float]? {
        guard let ch = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return nil }
        let cap = min(frames, Int(buffer.format.sampleRate * maxSeconds))
        guard cap > 0 else { return nil }
        var mono = [Float](repeating: 0, count: cap)
        for c in 0..<channels { vDSP_vadd(mono, 1, ch[c], 1, &mono, 1, vDSP_Length(cap)) }
        if channels > 1 {
            var scale = 1.0 / Float(channels)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(cap))
        }
        return mono
    }
}
