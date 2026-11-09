import AVFoundation
import Foundation

/// DJ Mode volume leveling (docs/design/np-dj-mode.md §5): the target and the gain clamp.
enum LoudnessLeveling {
    /// The leveling target, LUFS.
    static let targetLufs: Double = -14
    /// The gain clamp, dB — never cut more than 12 dB or boost more than 6 dB (the PeakLimiter
    /// catches positive-gain peaks).
    static let minGainDb: Double = -12
    static let maxGainDb: Double = 6
    /// Seconds a newly-known gain ramps over (never a step).
    static let rampSeconds: Double = 2

    /// `clamp(target − measured, −12…+6)`; nil when the loudness is unknown (play at 0 dB).
    static func gainDb(lufs: Double?) -> Double? {
        guard let lufs, lufs.isFinite else { return nil }
        return min(maxGainDb, max(minGainDb, targetLufs - lufs))
    }

    /// dB → linear amplitude.
    static func linear(db: Double) -> Double { pow(10, db / 20) }
}

/// ITU-R BS.1770-4 integrated loudness (LUFS), pure DSP over PCM.
///
/// - **K-weighting**: the two-stage biquad (high-shelf pre-filter + RLB high-pass), coefficients
///   derived for the actual sample rate with the bilinear formulas (libebur128's derivation of
///   the standard's 48 kHz table, so 44.1 / 96 kHz files are weighted correctly too).
/// - **Blocks**: 400 ms gating blocks with 75 % overlap (a 100 ms hop), as the standard specifies.
/// - **Gating**: absolute −70 LUFS, then relative −10 LU below the absolute-gated mean.
/// - **Channels**: every channel weighted 1.0 (BS.1770's L/R/C weight; PocketDJ's files are mono
///   or stereo, so the 1.41 surround weights never apply). Mono is ONE channel — a mono sine
///   reads ~3 dB below the same sine on both stereo channels, as the standard intends.
///
/// Returns nil when there is less than one full block, or when every block is gated (silence).
enum LoudnessAnalyzer {

    /// `samples` is mono, or interleaved with `channels` channels.
    static func integratedLoudness(samples: [Float], channels: Int = 1,
                                   sampleRate: Double) -> Double? {
        guard channels > 0, sampleRate > 0 else { return nil }
        var meter = Meter(channels: channels, sampleRate: sampleRate)
        samples.withUnsafeBufferPointer { meter.processInterleaved($0, frames: $0.count / channels) }
        return meter.integratedLoudness()
    }

    /// Decodes `url` in chunks and measures it, off the main actor at utility priority.
    static func analyze(url: URL) async throws -> Double? {
        try await Task.detached(priority: .utility) {
            try analyzeSync(url: url)
        }.value
    }

    /// The blocking body of `analyze(url:)` — call it only off the main thread.
    static func analyzeSync(url: URL, chunkFrames: AVAudioFrameCount = 65_536) throws -> Double? {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat   // deinterleaved Float32
        let channels = Int(format.channelCount)
        guard channels > 0, format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
        else { return nil }
        var meter = Meter(channels: channels, sampleRate: format.sampleRate)
        while file.framePosition < file.length {
            if Task.isCancelled { throw CancellationError() }
            try file.read(into: buffer, frameCount: chunkFrames)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { return nil }
            meter.processPlanar(data, frames: frames)
        }
        return meter.integratedLoudness()
    }

    // MARK: - K-weighting

    /// A direct-form-I biquad (a0 normalized to 1), Double state.
    struct Biquad: Equatable {
        var b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
        }

        @inline(__always)
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// Stage 1: the high-shelf "pre-filter" (+4 dB above ~1.7 kHz, head acoustics).
    static func preFilter(sampleRate fs: Double) -> Biquad {
        let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
        let k = tan(Double.pi * f0 / fs)
        let vh = pow(10, g / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: (vh + vb * k / q + k * k) / a0,
                      b1: 2 * (k * k - vh) / a0,
                      b2: (vh - vb * k / q + k * k) / a0,
                      a1: 2 * (k * k - 1) / a0,
                      a2: (1 - k / q + k * k) / a0)
    }

    /// Stage 2: the RLB high-pass (~38 Hz).
    static func rlbFilter(sampleRate fs: Double) -> Biquad {
        let f0 = 38.13547087602444, q = 0.5003270373238773
        let k = tan(Double.pi * f0 / fs)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: 1, b1: -2, b2: 1,
                      a1: 2 * (k * k - 1) / a0,
                      a2: (1 - k / q + k * k) / a0)
    }

    // MARK: - Streaming meter

    /// Streaming BS.1770 meter: K-weights each channel, accumulates 100 ms sub-block energies,
    /// and forms the 400 ms / 75 %-overlap gating blocks at the end.
    struct Meter {
        let channels: Int
        let hop: Int
        private var stage1: [Biquad]
        private var stage2: [Biquad]
        /// Σ over channels of the sum of squared K-weighted samples, this sub-block so far.
        private var acc = 0.0
        private var accFrames = 0
        /// Per 100 ms sub-block: Σ_channels mean square.
        private(set) var subBlocks: [Double] = []

        init(channels: Int, sampleRate: Double) {
            self.channels = channels
            self.hop = max(1, Int((sampleRate * 0.1).rounded()))
            stage1 = Array(repeating: LoudnessAnalyzer.preFilter(sampleRate: sampleRate), count: channels)
            stage2 = Array(repeating: LoudnessAnalyzer.rlbFilter(sampleRate: sampleRate), count: channels)
        }

        mutating func processInterleaved(_ p: UnsafeBufferPointer<Float>, frames: Int) {
            for f in 0..<frames {
                var e = 0.0
                for c in 0..<channels {
                    let y = stage2[c].process(stage1[c].process(Double(p[f * channels + c])))
                    e += y * y
                }
                push(e)
            }
        }

        mutating func processPlanar(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
            for f in 0..<frames {
                var e = 0.0
                for c in 0..<channels {
                    let y = stage2[c].process(stage1[c].process(Double(data[c][f])))
                    e += y * y
                }
                push(e)
            }
        }

        @inline(__always)
        private mutating func push(_ e: Double) {
            acc += e
            accFrames += 1
            if accFrames == hop {
                subBlocks.append(acc / Double(hop))
                acc = 0; accFrames = 0
            }
        }

        /// The gated integrated loudness; nil with < 400 ms of audio or when all of it is gated.
        func integratedLoudness() -> Double? {
            guard subBlocks.count >= 4 else { return nil }
            var blocks: [Double] = []
            blocks.reserveCapacity(subBlocks.count - 3)
            for i in 0...(subBlocks.count - 4) {
                blocks.append((subBlocks[i] + subBlocks[i + 1] + subBlocks[i + 2] + subBlocks[i + 3]) / 4)
            }
            let absGated = blocks.filter { LoudnessAnalyzer.lufs($0) > -70 }
            guard !absGated.isEmpty else { return nil }
            let relThreshold = LoudnessAnalyzer.lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10
            let gated = absGated.filter { LoudnessAnalyzer.lufs($0) > relThreshold }
            guard !gated.isEmpty else { return nil }
            return LoudnessAnalyzer.lufs(gated.reduce(0, +) / Double(gated.count))
        }
    }

    /// BS.1770 block loudness of a channel-summed mean square.
    @inline(__always)
    static func lufs(_ meanSquare: Double) -> Double {
        meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity
    }
}

/// Measured loudness per local file, keyed by song id + file BYTE SIZE (a re-cut or re-rip with
/// a different size re-analyzes), persisted as JSON at `Application Support/loudness.json`.
///
/// `@MainActor final class` (not an actor): the DSP reads `gainDb(for:)` synchronously on the
/// main actor when it engages a track, and writes are rare (one per analysis). Analysis itself
/// runs off-main (`LoudnessAnalyzer.analyze`); `analyzeIfNeeded` hops back to store the result.
@MainActor
final class LoudnessCache {
    struct Key: Hashable, Codable, Sendable {
        var songId: String
        var byteSize: Int64
    }

    private struct Entry: Codable {
        var songId: String
        var byteSize: Int64
        /// nil = analyzed, but nothing measurable (silence / too short) — never re-analyzed.
        var lufs: Double?
    }

    private struct FileBody: Codable {
        var version = 1
        var entries: [Entry]
    }

    static let shared = LoudnessCache(fileURL: LoudnessCache.defaultURL)

    static var defaultURL: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("loudness.json")
    }

    let fileURL: URL
    private var table: [Key: Double?] = [:]
    private var inFlight: Set<Key> = []

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let body = try? JSONDecoder().decode(FileBody.self, from: data) {
            for e in body.entries { table[Key(songId: e.songId, byteSize: e.byteSize)] = .some(e.lufs) }
        }
    }

    /// The key for a local file (nil when its size can't be read).
    nonisolated static func key(songId: String, url: URL) -> Key? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return nil }
        return Key(songId: songId, byteSize: size.int64Value)
    }

    /// Whether `key` has been analyzed (even if it measured nothing).
    func contains(_ key: Key) -> Bool { table[key] != nil }

    /// The measured loudness, nil when unknown or unmeasurable.
    func lufs(for key: Key) -> Double? { table[key] ?? nil }

    /// The leveling gain, dB: `clamp(−14 − lufs, −12…+6)`; nil when unknown.
    func gainDb(for key: Key) -> Double? { LoudnessLeveling.gainDb(lufs: lufs(for: key)) }

    /// Records a measurement and persists the table.
    func store(_ lufs: Double?, for key: Key) {
        table[key] = .some(lufs)
        inFlight.remove(key)
        save()
    }

    /// Analyzes `url` once per song id + size (background, utility priority) and stores the
    /// result. Returns the stored loudness (or the cached one); nil when unmeasurable, already
    /// in flight, or the file can't be read.
    @discardableResult
    func analyzeIfNeeded(songId: String, url: URL) async -> Double? {
        guard let key = Self.key(songId: songId, url: url) else { return nil }
        if contains(key) { return lufs(for: key) }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        do {
            let measured = try await LoudnessAnalyzer.analyze(url: url)
            store(measured, for: key)
            DJMode.log("level song=\(songId) lufs=\(measured.map { String(format: "%.1f", $0) } ?? "nil")")
            return measured
        } catch {
            inFlight.remove(key)
            DJMode.log("level song=\(songId) analyze failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func save() {
        let entries = table.map { Entry(songId: $0.key.songId, byteSize: $0.key.byteSize, lufs: $0.value) }
            .sorted { ($0.songId, $0.byteSize) < ($1.songId, $1.byteSize) }
        guard let data = try? JSONEncoder().encode(FileBody(entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
