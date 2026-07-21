import Foundation
import Accelerate
import AVFoundation

/// On-device MONOPHONIC MELODY extraction for the Demuxer (F8 slice B): a melodic stem (VOCALS,
/// else `other`) → a single-voice, beat-quantizable note line the Instruments tab plays/edits as a
/// plain `StudioTake` with the same synced score as the chord-comping slice. This is a TRUE melody
/// (per-note pitch tracking), NOT the harmonic reduction the chord-comping converter builds.
///
/// Pipeline (Levi's decided "solid, editable starting point" — not raw, not gold-plated):
///   stream the stem block-by-block (the ChordDetector/DrumPatternDetector reader) → per-HOP
///   monophonic f0 via YIN (cumulative-mean-normalized difference, absolute threshold) over the
///   ~80 Hz–1 kHz band → voiced/unvoiced GATE (periodicity + RMS floor) → MEDIAN-SMOOTH the f0
///   track → MIDI (69 + 12·log2(f0/440)) → merge stable-MIDI frames into notes (drop sub-~100 ms
///   blips, coalesce brief unvoiced gaps) → SNAP to the KeyDetector-detected scale + OCTAVE-CORRECT.
///
/// The heavy per-hop f0 loop is `nonisolated` and streamed — run it OFF the main actor
/// (`Task.detached(.utility)`, the `analyzeDrumPattern` discipline). The pure segmentation
/// (`buildNotes` / `snapToScale`) is unit-tested directly on hand-built frame sequences; the f0
/// estimator on synthetic pure tones.
enum MelodyTracker {

    // Frame geometry: 2048-sample YIN windows, 512 hop (~86 fps / ~11.6 ms @ 44.1 kHz) — the
    // note-scale resolution the segmentation quantizes to.
    static let frameSize = 2048
    static let hop = 512

    /// Pitch band: a sung/lead melody lives here. Bounds the YIN lag search (`minTau`…`maxTau`).
    static let minHz = 80.0
    static let maxHz = 1_000.0

    /// YIN absolute threshold on the cumulative-mean-normalized difference: the first lag whose
    /// CMND dips below this is taken as the period (then descended to its local minimum). Lower =
    /// stricter (more unvoiced). 0.15 is the YIN paper's voiced sweet spot for real signals.
    static let yinThreshold: Float = 0.15

    /// Voiced GATE: a frame counts as pitched only when its periodicity (1 − CMND at the chosen
    /// lag) clears this AND its RMS clears `rmsFloorFraction` of the file's loudest frame. Kills
    /// breaths, consonants, and inter-note silence that would otherwise mint garbage notes.
    static let periodicityFloor: Float = 0.55
    static let rmsFloorFraction: Float = 0.10

    /// Median-smoothing window (frames, odd) over the per-frame MIDI track — removes single-frame
    /// octave/semitone jitter before frames are merged into notes.
    static let smoothWindow = 5

    /// Note segmentation thresholds (ms). A run of same-MIDI voiced frames shorter than
    /// `minNoteMs` is a blip (dropped); an unvoiced/mismatch gap shorter than `gapCoalesceMs`
    /// between two SAME-MIDI notes is bridged (a breath inside a held note, not a note boundary).
    static let minNoteMs = 100.0
    static let gapCoalesceMs = 90.0

    /// Analysis cap (the ChordDetector/DrumPatternDetector bound on an accidental huge file).
    static let maxSeconds = 12.0 * 60.0

    // MARK: - Public entry (stream → notes)

    /// Track the monophonic melody of a stem file and return its beat-independent note line
    /// (MIDI + [startMs,endMs) on the stem/song clock). Empty when nothing pitched was found
    /// (the caller maps that to `.failed`). Composes the streamed f0 pass, the pure segmentation,
    /// and the KeyDetector scale-snap + octave-correction.
    nonisolated static func detect(melodyURL: URL) -> [DemuxMelodyNote] {
        guard let file = try? AVAudioFile(forReading: melodyURL) else { return [] }
        let sr = file.processingFormat.sampleRate
        guard sr > 0, file.length > 0 else { return [] }
        let frames = f0Frames(file: file)
        guard !frames.isEmpty else { return [] }
        let hopMs = Double(hop) / sr * 1_000
        let raw = buildNotes(frames: frames, hopMs: hopMs)
        guard !raw.isEmpty else { return [] }
        let scale = scalePitchClasses(forNotes: raw) ?? []
        return snapToScale(notes: raw, scalePCs: scale)
    }

    // MARK: - Per-frame f0 (YIN — pure, unit-tested on synthetic tones)

    /// One frame's pitch estimate.
    struct F0Frame: Equatable {
        /// Estimated fundamental in Hz (0 when no periodicity was found).
        var f0: Double
        /// 1 − CMND at the chosen lag: ~1 for a clean tone, ~0 for noise. The voiced gate reads it.
        var periodicity: Float
        /// Frame RMS (the loudness gate reads it, relative to the file max).
        var rms: Float
    }

    /// Estimate f0 for ONE `frameSize`-length frame via YIN. Pure + deterministic — the unit test
    /// drives it with synthesized pure tones (440→MIDI 69, 220→57, 880→81). Returns f0 = 0 with
    /// low periodicity when the frame has no clear period in-band.
    nonisolated static func estimateF0(frame: [Float], sampleRate: Double) -> F0Frame {
        let n = frame.count
        guard n >= 64, sampleRate > 0 else { return F0Frame(f0: 0, periodicity: 0, rms: 0) }

        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(n))

        let minTau = max(2, Int((sampleRate / maxHz).rounded()))
        let maxTau = min(n - 1, Int((sampleRate / minHz).rounded()))
        guard maxTau > minTau + 2 else { return F0Frame(f0: 0, periodicity: 0, rms: rms) }
        // Integration window: the tail that is still fully overlapped at the LONGEST lag, so every
        // lag's difference is summed over the same count of terms (comparable across lags).
        let W = n - maxTau
        guard W >= 32 else { return F0Frame(f0: 0, periodicity: 0, rms: rms) }

        // Prefix sums of squares → each lag's windowed energy in O(1) (avoids a per-lag energy dot).
        var ps = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { ps[i + 1] = ps[i] + frame[i] * frame[i] }
        let e0 = ps[W] - ps[0]

        // YIN difference d(tau) for every lag 1…maxTau (the cumulative mean needs the small lags
        // too), via the energy-identity: d = E0 + E(tau) − 2·Σ x[j]·x[j+tau].
        var d = [Float](repeating: 0, count: maxTau + 1)
        frame.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for tau in 1...maxTau {
                var cross: Float = 0
                vDSP_dotpr(base, 1, base + tau, 1, &cross, vDSP_Length(W))
                let eTau = ps[tau + W] - ps[tau]
                d[tau] = e0 + eTau - 2 * cross
            }
        }

        // Cumulative-mean-normalized difference: d'(tau) = d(tau) / ((1/tau)·Σ_{k≤tau} d(k)).
        var cmnd = [Float](repeating: 1, count: maxTau + 1)
        var running: Float = 0
        for tau in 1...maxTau {
            running += d[tau]
            cmnd[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }

        // Absolute threshold: the FIRST lag in-band below the threshold, descended to the bottom of
        // its dip; else the global CMND minimum in-band (weakly-periodic / unvoiced frame).
        var tau = -1
        var t = minTau
        while t <= maxTau {
            if cmnd[t] < yinThreshold {
                while t + 1 <= maxTau && cmnd[t + 1] < cmnd[t] { t += 1 }
                tau = t
                break
            }
            t += 1
        }
        if tau < 0 {
            var best = minTau
            for k in minTau...maxTau where cmnd[k] < cmnd[best] { best = k }
            tau = best
        }

        // Parabolic interpolation around the chosen lag for sub-sample period refinement.
        var refined = Double(tau)
        if tau > minTau && tau < maxTau {
            let a = cmnd[tau - 1], b = cmnd[tau], c = cmnd[tau + 1]
            let denom = a + c - 2 * b
            if abs(denom) > 1e-9 { refined = Double(tau) + Double((a - c) / (2 * denom)) }
        }
        let f0 = refined > 0 ? sampleRate / refined : 0
        let periodicity = max(0, 1 - cmnd[tau])
        return F0Frame(f0: f0, periodicity: periodicity, rms: rms)
    }

    // MARK: - Streamed f0 pass (block reader → per-hop F0Frame)

    /// Stream the file hop-by-hop (the DrumPatternDetector overlap-carry reader), emitting one
    /// `F0Frame` per hop. Never decodes the whole file into one buffer.
    private nonisolated static func f0Frames(file: AVAudioFile) -> [F0Frame] {
        let format = file.processingFormat
        let sr = format.sampleRate
        let channels = Int(format.channelCount)
        let blockFrames = AVAudioFrameCount(frameSize * 16)
        guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else { return [] }
        let maxTotal = AVAudioFramePosition(sr * maxSeconds)

        var mono = [Float]()
        var out: [F0Frame] = []
        var consumed: AVAudioFramePosition = 0
        var frame = [Float](repeating: 0, count: frameSize)

        while consumed < min(file.length, maxTotal) {
            block.frameLength = 0
            guard (try? file.read(into: block, frameCount: blockFrames)) != nil, block.frameLength > 0 else { break }
            consumed += AVAudioFramePosition(block.frameLength)
            guard let ch = block.floatChannelData else { break }
            let count = Int(block.frameLength)
            let base = mono.count
            mono.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: count))
            if channels > 1 {
                mono.withUnsafeMutableBufferPointer { mp in
                    for c in 1..<channels {
                        vDSP_vadd(mp.baseAddress! + base, 1, ch[c], 1, mp.baseAddress! + base, 1, vDSP_Length(count))
                    }
                    var scale = 1.0 / Float(channels)
                    vDSP_vsmul(mp.baseAddress! + base, 1, &scale, mp.baseAddress! + base, 1, vDSP_Length(count))
                }
            }
            var pos = 0
            while pos + frameSize <= mono.count {
                for i in 0..<frameSize { frame[i] = mono[pos + i] }
                out.append(estimateF0(frame: frame, sampleRate: sr))
                pos += hop
            }
            if pos > 0 { mono.removeFirst(pos) }
        }
        return out
    }

    // MARK: - Segmentation (pure — gate → smooth → merge → blip/gap → notes)

    /// Turn a per-hop f0 track into UN-SNAPPED note segments: voiced/unvoiced gate → median-smooth
    /// the MIDI track → merge same-MIDI runs into notes → coalesce brief unvoiced gaps between
    /// same-MIDI notes → drop sub-`minNoteMs` blips. Pure + testable on a hand-built frame array.
    nonisolated static func buildNotes(frames: [F0Frame], hopMs: Double) -> [DemuxMelodyNote] {
        guard !frames.isEmpty, hopMs > 0 else { return [] }
        let maxRms = frames.map(\.rms).max() ?? 0
        let rmsFloor = maxRms * rmsFloorFraction

        // Gate → per-frame MIDI (nil when unvoiced).
        var midi: [Int?] = frames.map { f in
            guard f.periodicity >= periodicityFloor, f.rms >= rmsFloor, f.f0 > 0 else { return nil }
            let m = 69.0 + 12.0 * log2(f.f0 / 440.0)
            guard m.isFinite else { return nil }
            return Int(m.rounded())
        }

        // Median-smooth the voiced MIDI values (unvoiced frames neither contribute nor receive).
        let radius = smoothWindow / 2
        var smoothed = midi
        for i in midi.indices where midi[i] != nil {
            var window: [Int] = []
            for j in max(0, i - radius)...min(midi.count - 1, i + radius) {
                if let v = midi[j] { window.append(v) }
            }
            if !window.isEmpty { window.sort(); smoothed[i] = window[window.count / 2] }
        }

        // Merge consecutive same-MIDI voiced frames into raw segments (frame indices).
        var segs: [(midi: Int, startF: Int, endF: Int)] = []
        for i in smoothed.indices {
            guard let m = smoothed[i] else { continue }
            if var last = segs.last, last.midi == m, last.endF == i - 1 {
                last.endF = i; segs[segs.count - 1] = last
            } else {
                segs.append((m, i, i))
            }
        }
        guard !segs.isEmpty else { return [] }

        // Coalesce brief unvoiced/mismatch gaps between two SAME-MIDI segments (a breath inside a
        // held note). Frame `endF` is inclusive, so the gap is (next.start − cur.end − 1) frames.
        var coalesced: [(midi: Int, startF: Int, endF: Int)] = [segs[0]]
        for s in segs.dropFirst() {
            var prev = coalesced[coalesced.count - 1]
            let gapMs = Double(s.startF - prev.endF - 1) * hopMs
            if prev.midi == s.midi && gapMs <= gapCoalesceMs {
                prev.endF = s.endF; coalesced[coalesced.count - 1] = prev
            } else {
                coalesced.append(s)
            }
        }

        // Frames → ms; drop sub-minNoteMs blips. A segment spans [startF, endF] inclusive; its
        // sounding length is (endF − startF + 1) hops.
        var notes: [DemuxMelodyNote] = []
        for s in coalesced {
            let startMs = Int((Double(s.startF) * hopMs).rounded())
            let endMs = Int((Double(s.endF + 1) * hopMs).rounded())
            guard Double(endMs - startMs) >= minNoteMs else { continue }
            notes.append(DemuxMelodyNote(midi: s.midi, startMs: startMs, endMs: endMs))
        }
        return notes
    }

    // MARK: - Scale snap + octave correction (pure)

    /// The 7 scale pitch classes of a note line's best-fitting key (KeyDetector's KS correlation
    /// over the notes' duration-weighted pitch-class histogram). nil when the line is empty/atonal.
    nonisolated static func scalePitchClasses(forNotes notes: [DemuxMelodyNote]) -> [Int]? {
        guard !notes.isEmpty else { return nil }
        var chroma = [Double](repeating: 0, count: 12)
        for n in notes {
            chroma[((n.midi % 12) + 12) % 12] += Double(max(1, n.endMs - n.startMs))
        }
        return KeyDetector.scale(chroma: chroma)
    }

    /// Clean a raw note line into a "solid starting point": SNAP each note's pitch class to the
    /// nearest scale degree (kills semitone jitter; a no-op when `scalePCs` is empty) then
    /// OCTAVE-CORRECT — fold ONLY a NEAR-OCTAVE slip (an interval > 10 semitones from the previous
    /// corrected note, i.e. almost certainly a tracker octave jump) back by ±12, killing the octave
    /// errors monophonic trackers are prone to WITHOUT flattening or inverting genuine leaps: a real
    /// sixth or seventh (≤ 10 st) is left intact. Continuity is anchored to the already-corrected
    /// previous note.
    nonisolated static func snapToScale(notes: [DemuxMelodyNote], scalePCs: [Int]) -> [DemuxMelodyNote] {
        guard !notes.isEmpty else { return [] }
        // Sorted-unique so a two-sided tie (every chromatic tone is ±1 from both neighbours in a
        // diatonic scale) resolves DETERMINISTICALLY toward the lower scale degree.
        let scale = Array(Set(scalePCs.map { (($0 % 12) + 12) % 12 })).sorted()
        var out: [DemuxMelodyNote] = []
        var prevMidi: Int?
        for note in notes {
            var m = note.midi
            if !scale.isEmpty {
                let pc = ((m % 12) + 12) % 12
                if !scale.contains(pc) {
                    // Nearest scale degree by signed circular distance in (−6, 6].
                    var bestDelta = 12
                    for s in scale {
                        var delta = s - pc
                        if delta > 6 { delta -= 12 }
                        if delta < -6 { delta += 12 }
                        if abs(delta) < abs(bestDelta) { bestDelta = delta }
                    }
                    if abs(bestDelta) <= 6 { m += bestDelta }
                }
            }
            // Octave-correct against the previous (already corrected) note: fold by ±12 ONLY when
            // the interval is a NEAR-OCTAVE slip (> 10 semitones — a minor-7th-or-wider jump that a
            // monophonic tracker almost always mis-octaves), leaving genuine sixths/sevenths (≤ 10)
            // untouched so a real ascending leap isn't flattened or inverted downward.
            if let p = prevMidi {
                while m - p > 10 { m -= 12 }
                while p - m > 10 { m += 12 }
            }
            out.append(DemuxMelodyNote(midi: m, startMs: note.startMs, endMs: note.endMs))
            prevMidi = m
        }
        return out
    }
}
