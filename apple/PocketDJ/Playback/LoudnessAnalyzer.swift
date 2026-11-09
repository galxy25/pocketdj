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

    /// The slice of a file to measure (song seconds of a shared analog album side). nil
    /// `lengthMs` ⇒ to the file's end.
    struct Segment: Hashable, Codable, Sendable {
        var startMs: Int
        var lengthMs: Int?
    }

    /// Thread-safe cancellation flag the blocking decode polls (a `Task.detached` doesn't
    /// inherit its awaiter's cancellation, so the caller's cancel is relayed through this).
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func cancel() { lock.lock(); flag = true; lock.unlock() }
    }

    /// Decodes `url` (or just `segment` of it) in chunks and measures it, off the main actor
    /// at utility priority. Cancelling the awaiting task stops the decode at its next chunk.
    static func analyze(url: URL, segment: Segment? = nil, monoSum: Bool = true) async throws -> Double? {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try analyzeSync(url: url, segment: segment, monoSum: monoSum, cancel: flag)
            }.value
        } onCancel: {
            flag.cancel()
        }
    }

    /// The blocking body of `analyze(url:)` — call it only off the main thread.
    ///
    /// - `segment`: measure only `[startMs, startMs + lengthMs)` (a song on a shared album
    ///   side — never the whole 40–60 min side).
    /// - `monoSum` (np-dj-mode §5 "reduced cost"): the channels are averaged and ONE K-weighting
    ///   chain runs on the sum, its energy scaled by the channel count. Exact for mono and for
    ///   identical (centre-panned) channels; uncorrelated wide-stereo content reads up to ~3 dB
    ///   low. That bias is the same for every song of similar width, so the trim stays a
    ///   consistent relative leveling at about half the per-frame cost. `false` = the exact
    ///   per-channel BS.1770 sum.
    static func analyzeSync(url: URL, segment: Segment? = nil, monoSum: Bool = true,
                            cancel: CancelFlag? = nil,
                            chunkFrames: AVAudioFrameCount = 65_536) throws -> Double? {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat   // deinterleaved Float32
        let channels = Int(format.channelCount)
        guard channels > 0, format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
        else { return nil }
        let sr = format.sampleRate
        var endFrame = file.length
        if let segment {
            let start = min(file.length, max(0, AVAudioFramePosition(Double(segment.startMs) / 1000 * sr)))
            if let len = segment.lengthMs {
                endFrame = min(file.length, start + max(0, AVAudioFramePosition(Double(len) / 1000 * sr)))
            }
            file.framePosition = start
        }
        var meter = Meter(channels: monoSum ? 1 : channels, sampleRate: sr)
        let scale = monoSum ? Double(channels) : 1
        while file.framePosition < endFrame {
            if Task.isCancelled || cancel?.isCancelled == true { throw CancellationError() }
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), endFrame - file.framePosition))
            try file.read(into: buffer, frameCount: want)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { return nil }
            if monoSum { meter.processPlanarMonoSum(data, channels: channels, frames: frames, energyScale: scale) }
            else { meter.processPlanar(data, frames: frames) }
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

        /// The `monoSum` path: average the channels, weight the ONE sum, scale its energy by
        /// `energyScale` (the channel count — identical channels then read exactly as stereo).
        mutating func processPlanarMonoSum(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int,
                                           frames: Int, energyScale: Double) {
            let inv = 1 / Double(max(1, channels))
            for f in 0..<frames {
                var m = 0.0
                for c in 0..<channels { m += Double(data[c][f]) }
                let y = stage2[0].process(stage1[0].process(m * inv))
                push(y * y * energyScale)
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
/// a different size re-analyzes) + the SEGMENT measured (a song on a shared album side is its
/// own slice of the side, never the whole file), persisted as JSON at
/// `Application Support/loudness.json`.
///
/// `@MainActor final class` (not an actor): the DSP reads `gainDb(for:)` synchronously on the
/// main actor when it engages a track, and writes are rare (one per analysis). Analysis itself
/// runs off-main (`LoudnessAnalyzer.analyze`); `analyze` hops back to store the result.
///
/// ONE analysis per key at a time: a second caller AWAITS the first one's task (it never gets
/// an instant "nothing yet" it could spin on), and a failure is remembered for the launch so a
/// file that can't be decoded is never retried in a loop.
@MainActor
final class LoudnessCache {
    struct Key: Hashable, Codable, Sendable {
        var songId: String
        var byteSize: Int64
        /// The measured slice of a shared album file (nil = the whole file — every per-song file,
        /// and every entry written before segments existed).
        var segment: LoudnessAnalyzer.Segment? = nil
    }

    private struct Entry: Codable {
        var songId: String
        var byteSize: Int64
        var segment: LoudnessAnalyzer.Segment?
        /// nil = analyzed, but nothing measurable (silence / too short) — never re-analyzed.
        var lufs: Double?
    }

    private struct FileBody: Codable {
        var version = 1
        var entries: [Entry]
    }

    /// How one `analyze` call ended.
    enum Outcome: Equatable {
        /// THIS call's analysis stored a new result (nil = unmeasurable).
        case measured(Double?)
        /// Already known (nil = unmeasurable) — nothing new stored by this call.
        case cached(Double?)
        /// The decode failed (remembered: not retried this launch) or the file is unreadable.
        case failed
        /// The analysis was cancelled (not remembered: a later call may run it again).
        case cancelled
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
    private var inFlight: [Key: Task<Outcome, Never>] = [:]
    private var failed: Set<Key> = []

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let body = try? JSONDecoder().decode(FileBody.self, from: data) {
            for e in body.entries {
                table[Key(songId: e.songId, byteSize: e.byteSize, segment: e.segment)] = .some(e.lufs)
            }
        }
    }

    /// The key for a local file (nil when its size can't be read). `startMs` (a song on a
    /// shared album side) keys the slice `[startMs, startMs + lengthMs)`; nil = the whole file.
    nonisolated static func key(songId: String, url: URL, startMs: Int? = nil, lengthMs: Int? = nil) -> Key? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return nil }
        return Key(songId: songId, byteSize: size.int64Value,
                   segment: startMs.map { LoudnessAnalyzer.Segment(startMs: $0, lengthMs: lengthMs) })
    }

    /// Whether `key` has been analyzed (even if it measured nothing).
    func contains(_ key: Key) -> Bool { table[key] != nil }

    /// An analysis of `key` is running now.
    func isAnalyzing(_ key: Key) -> Bool { inFlight[key] != nil }

    /// `key`'s analysis failed this launch (it isn't retried until a relaunch / a new file).
    func hasFailed(_ key: Key) -> Bool { failed.contains(key) }

    /// Nothing to start for `key`: known, failed, or already running.
    func isSettledOrRunning(_ key: Key) -> Bool { contains(key) || hasFailed(key) || isAnalyzing(key) }

    /// The measured loudness, nil when unknown or unmeasurable.
    func lufs(for key: Key) -> Double? { table[key] ?? nil }

    /// The leveling gain, dB: `clamp(−14 − lufs, −12…+6)`; nil when unknown.
    func gainDb(for key: Key) -> Double? { LoudnessLeveling.gainDb(lufs: lufs(for: key)) }

    /// Records a measurement and persists the table.
    func store(_ lufs: Double?, for key: Key) {
        table[key] = .some(lufs)
        failed.remove(key)
        save()
    }

    /// Measure `key`'s file (its segment) once: background, utility priority. A call while the
    /// same key is in flight AWAITS that analysis and reports `.cached` (it stored nothing
    /// itself). Cancelling one awaiting caller doesn't stop a shared analysis; `cancelAll` does.
    @discardableResult
    func analyze(_ key: Key, url: URL) async -> Outcome {
        if contains(key) { return .cached(lufs(for: key)) }
        if failed.contains(key) { return .failed }
        if let running = inFlight[key] {
            let r = await running.value
            if case .measured(let v) = r { return .cached(v) }
            return r
        }
        let seg = key.segment.map { " seg=\($0.startMs)+\($0.lengthMs.map(String.init) ?? "end")" } ?? ""
        let task = Task { @MainActor [weak self] () -> Outcome in
            do {
                let measured = try await LoudnessAnalyzer.analyze(url: url, segment: key.segment)
                guard let self else { return .cancelled }
                self.inFlight[key] = nil
                self.store(measured, for: key)
                DJMode.log("level song=\(key.songId)\(seg) lufs=\(measured.map { String(format: "%.1f", $0) } ?? "nil")")
                return .measured(measured)
            } catch is CancellationError {
                self?.inFlight[key] = nil
                return .cancelled
            } catch {
                guard let self else { return .failed }
                self.inFlight[key] = nil
                self.failed.insert(key)
                DJMode.log("level song=\(key.songId)\(seg) analyze failed (not retried): \(error.localizedDescription)")
                return .failed
            }
        }
        inFlight[key] = task
        return await task.value
    }

    /// Analyzes `url` once per song id + size (+ segment) and stores the result. Returns the
    /// loudness (measured now or cached); nil when unmeasurable, failed or unreadable.
    @discardableResult
    func analyzeIfNeeded(songId: String, url: URL, startMs: Int? = nil, lengthMs: Int? = nil) async -> Double? {
        guard let key = Self.key(songId: songId, url: url, startMs: startMs, lengthMs: lengthMs) else { return nil }
        switch await analyze(key, url: url) {
        case .measured(let v), .cached(let v): return v
        case .failed, .cancelled: return nil
        }
    }

    /// Stop every running analysis (DJ Mode off / the session ended). Nothing is remembered
    /// for them — a later call analyzes again.
    func cancelAll() {
        for t in inFlight.values { t.cancel() }
    }

    private func save() {
        let entries = table.map { Entry(songId: $0.key.songId, byteSize: $0.key.byteSize, segment: $0.key.segment, lufs: $0.value) }
            .sorted { ($0.songId, $0.byteSize, $0.segment?.startMs ?? -1) < ($1.songId, $1.byteSize, $1.segment?.startMs ?? -1) }
        guard let data = try? JSONEncoder().encode(FileBody(entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
