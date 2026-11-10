import AVFoundation
import Foundation

// MARK: - Progressive on-device analysis (np-dj-mode §5a — Levi 2026-11-09)
//
// "make the audio analysis lower latency by doing it on the first 15–30 seconds of audio and using
// that as a placeholder / hint until the full audio analysis is done (detecting bpm, key and volume)"
//
//  • QUICK pass: ~20 s of the song — from ~30 % in when the whole file is here (an intro is often
//    beatless / quiet: BPM fails and leveling over-boosts), else the first 15–30 s that exist
//    (a growing / streaming / ripping file; flagged `headOnly` and re-run on a better window once
//    the file completes). BPM (`BeatDetect`), key (`KeyDetector`), loudness (`LoudnessAnalyzer`),
//    each with a confidence. Published as a HINT.
//  • FULL pass follows: BPM over up to 120 s, key over the middle minute, loudness over the whole
//    song (`LoudnessCache`, unchanged). Replaces the hint.
//  • PRECEDENCE: measured server beat-grid / catalog > full on-device > confident quick hint >
//    nothing — a hint never overwrites better data; a low-confidence hint is treated as MISSING
//    (the planner / glide degrade exactly as they already do). A loudness hint is clamped to
//    ±`hintGainClampDb` until the full value lands, which then RAMPS over the normal 2 s.

enum AudioAnalysis {

    // MARK: Window

    /// The slice of song a pass decodes (song seconds; `headOnly` = the head of a file still arriving).
    struct Window: Equatable, Sendable {
        var startSeconds: Double
        var lengthSeconds: Double
        var headOnly: Bool
    }

    /// The quick pass's target length.
    static let quickSeconds: Double = 20
    /// A growing file needs at least this much decoded before the quick pass runs on its head…
    static let minHeadSeconds: Double = 15
    /// …and the head pass reads at most this much.
    static let maxHeadSeconds: Double = 30
    /// Where in a complete song the quick window starts (fraction of its length) — past the intro.
    static let quickStartFraction: Double = 0.3

    /// The quick window for a song of `durationSeconds` (nil = unknown) with `availableSeconds`
    /// decodable now; `complete` = the whole file is on disk. nil ⇒ not enough audio yet.
    static func quickWindow(durationSeconds: Double?, availableSeconds: Double, complete: Bool) -> Window? {
        guard availableSeconds > 0 else { return nil }
        if complete {
            let dur = durationSeconds.map { min($0, availableSeconds) } ?? availableSeconds
            guard dur > 2 else { return nil }
            let len = min(quickSeconds, dur)
            // ~30 % in, centred-ish, never past the end (a short song: the whole of it).
            let start = max(0, min(dur * quickStartFraction, dur - len))
            return Window(startSeconds: start, lengthSeconds: len, headOnly: false)
        }
        guard availableSeconds >= minHeadSeconds else { return nil }
        return Window(startSeconds: 0, lengthSeconds: min(availableSeconds, maxHeadSeconds), headOnly: true)
    }

    // MARK: Results + precedence

    struct Result: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case quick, full }
        var kind: Kind
        /// The window was the head of a file still arriving (re-run once it completes).
        var headOnly = false
        var bpm: Double?
        var bpmConfidence = 0.0
        var camelot: String?
        var keyConfidence = 0.0
        var lufs: Double?

        init(kind: Kind, headOnly: Bool = false, bpm: Double? = nil, bpmConfidence: Double = 0,
             camelot: String? = nil, keyConfidence: Double = 0, lufs: Double? = nil) {
            self.kind = kind; self.headOnly = headOnly; self.bpm = bpm; self.bpmConfidence = bpmConfidence
            self.camelot = camelot; self.keyConfidence = keyConfidence; self.lufs = lufs
        }

        /// Tolerant: a field added / renamed later decodes to its default — a schema change never
        /// wipes the persisted finals.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .full
            headOnly = (try? c.decodeIfPresent(Bool.self, forKey: .headOnly)) ?? false
            bpm = try? c.decodeIfPresent(Double.self, forKey: .bpm)
            bpmConfidence = (try? c.decodeIfPresent(Double.self, forKey: .bpmConfidence)) ?? 0
            camelot = try? c.decodeIfPresent(String.self, forKey: .camelot)
            keyConfidence = (try? c.decodeIfPresent(Double.self, forKey: .keyConfidence)) ?? 0
            lufs = try? c.decodeIfPresent(Double.self, forKey: .lufs)
        }

        /// The BPM if confident enough to use, else nil (a low-confidence hint is MISSING).
        var usableBPM: Double? { bpmConfidence >= AudioAnalysis.minBPMConfidence ? bpm : nil }
        var usableCamelot: String? { keyConfidence >= AudioAnalysis.minKeyConfidence ? camelot : nil }
    }

    /// Below these a detection is treated as missing.
    static let minBPMConfidence = 0.3
    static let minKeyConfidence = 0.7
    /// A loudness HINT moves the trim at most this far (dB) until the full measurement lands.
    static let hintGainClampDb: Double = 4

    /// Where a value came from (the readouts show "≈" for a hint).
    enum Source: Int, Comparable, Sendable {
        case none = 0, quick, full, measured
        static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
    }

    /// BPM by precedence: `measured` (server beat-grid / catalog) > full on-device > a confident
    /// quick hint > nothing.
    static func bpm(measured: Double?, full: Result?, quick: Result?) -> (value: Double?, source: Source) {
        if let m = measured, m > 0 { return (m, .measured) }
        if let f = full?.usableBPM { return (f, .full) }
        if let q = quick?.usableBPM { return (q, .quick) }
        return (nil, .none)
    }

    /// Camelot key by the same ladder.
    static func camelot(measured: String?, full: Result?, quick: Result?) -> (value: String?, source: Source) {
        if let m = measured, !m.isEmpty { return (m, .measured) }
        if let f = full?.usableCamelot { return (f, .full) }
        if let q = quick?.usableCamelot { return (q, .quick) }
        return (nil, .none)
    }

    /// The leveling gain: the full measurement's (`LoudnessCache`), else the quick hint's clamped
    /// to ±`hintGainClampDb`, else nil (unknown).
    static func levelGain(fullGainDb: Double?, quick: Result?) -> (db: Double?, source: Source) {
        if let g = fullGainDb { return (g, .full) }
        if let g = LoudnessLeveling.gainDb(lufs: quick?.lufs) {
            return (min(hintGainClampDb, max(-hintGainClampDb, g)), .quick)
        }
        return (nil, .none)
    }

    // MARK: Passes (blocking — call off the main actor)

    /// Decode `window` of `url` (offset by `sliceStartSeconds` for a song on a shared album side)
    /// into one buffer. nil when unreadable / empty.
    static func decode(url: URL, sliceStartSeconds: Double = 0, window: Window) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return nil }
        let start = AVAudioFramePosition((sliceStartSeconds + window.startSeconds) * sr)
        guard start < file.length else { return nil }
        let count = AVAudioFrameCount(min(Double(file.length - start), window.lengthSeconds * sr))
        guard count > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return nil }
        file.framePosition = start
        guard (try? file.read(into: buf, frameCount: count)) != nil, buf.frameLength > 0 else { return nil }
        return buf
    }

    /// Seconds of audio decodable from `url` right now (a growing file: what has landed).
    static func availableSeconds(url: URL, sliceStartSeconds: Double = 0) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let sr = file.processingFormat.sampleRate
        return sr > 0 ? max(0, Double(file.length) / sr - sliceStartSeconds) : 0
    }

    /// BPM / key / loudness of one decoded window.
    static func measure(_ buf: AVAudioPCMBuffer, kind: Result.Kind, headOnly: Bool,
                        bpmSeconds: Double, keySeconds: Double, loudness: Bool) -> Result {
        var r = Result(kind: kind, headOnly: headOnly)
        if let g = BeatDetect.detectGridWithConfidence(buf, maxSeconds: bpmSeconds) {
            r.bpm = g.grid.bpm; r.bpmConfidence = g.confidence
        }
        if let k = KeyDetector.detect(audio: buf, maxSeconds: keySeconds) {
            r.camelot = k.camelot; r.keyConfidence = k.strength
        }
        if loudness, let ch = buf.floatChannelData {
            var meter = LoudnessAnalyzer.Meter(channels: 1, sampleRate: buf.format.sampleRate)
            meter.processPlanarMonoSum(ch, channels: Int(buf.format.channelCount), frames: Int(buf.frameLength),
                                       energyScale: Double(buf.format.channelCount))
            r.lufs = meter.integratedLoudness()
        }
        return r
    }

    /// The QUICK pass over `window`.
    static func quickPass(url: URL, sliceStartSeconds: Double = 0, window: Window) -> Result? {
        guard let buf = decode(url: url, sliceStartSeconds: sliceStartSeconds, window: window) else { return nil }
        return measure(buf, kind: .quick, headOnly: window.headOnly,
                       bpmSeconds: window.lengthSeconds, keySeconds: window.lengthSeconds, loudness: true)
    }

    /// The FULL pass (BPM over up to 120 s from the top, key over the song's middle minute;
    /// loudness is `LoudnessCache`'s whole-song measurement, not repeated here).
    static func fullPass(url: URL, sliceStartSeconds: Double = 0, durationSeconds: Double) -> Result? {
        guard durationSeconds > 2 else { return nil }
        var r = Result(kind: .full)
        if let buf = decode(url: url, sliceStartSeconds: sliceStartSeconds,
                            window: Window(startSeconds: 0, lengthSeconds: min(120, durationSeconds), headOnly: false)),
           let g = BeatDetect.detectGridWithConfidence(buf, maxSeconds: 120) {
            r.bpm = g.grid.bpm; r.bpmConfidence = g.confidence
        }
        let keyLen = min(60, durationSeconds)
        if let buf = decode(url: url, sliceStartSeconds: sliceStartSeconds,
                            window: Window(startSeconds: max(0, (durationSeconds - keyLen) / 2), lengthSeconds: keyLen, headOnly: false)),
           let k = KeyDetector.detect(audio: buf, maxSeconds: keyLen) {
            r.camelot = k.camelot; r.keyConfidence = k.strength
        }
        return r
    }
}

// MARK: - Cache (hints in memory, finals persisted)

/// Quick hints and full results per file, keyed like `LoudnessCache` (song id + byte size +
/// segment). Finals persist at `Application Support/analysis.json`; hints live for the launch.
@MainActor
final class AudioAnalysisCache {
    static let shared = AudioAnalysisCache(fileURL: AudioAnalysisCache.defaultURL)

    static var defaultURL: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("analysis.json")
    }

    private struct Entry: Codable {
        var key: LoudnessCache.Key
        var result: AudioAnalysis.Result
        /// Last use (epoch seconds) — the LRU cap's order. Optional: older files lack it.
        var usedAt: Double?
    }
    private struct FileBody: Codable { var version = 1; var entries: [Entry] }

    /// At most this many finals are kept (least-recently used go first).
    static var maxEntries = 5000
    /// Saves are debounced by this, and written off the main actor.
    static var saveDebounceSeconds: Double = 1

    let fileURL: URL
    private var quick: [LoudnessCache.Key: AudioAnalysis.Result] = [:]
    private var full: [LoudnessCache.Key: AudioAnalysis.Result] = [:]
    private var usedAt: [LoudnessCache.Key: Double] = [:]
    private var saveTask: Task<Void, Never>?
    /// Song id → the key of its latest result (the planner looks songs up by id).
    private var latestKey: [String: LoudnessCache.Key] = [:]
    /// Bumped on every store (observers re-read).
    private(set) var revision = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let body = try? JSONDecoder().decode(FileBody.self, from: data) {
            for e in body.entries where e.result.kind == .full {
                full[e.key] = e.result
                usedAt[e.key] = e.usedAt ?? 0
                if let k = latestKey[e.key.songId], (usedAt[k] ?? 0) > (e.usedAt ?? 0) { continue }
                latestKey[e.key.songId] = e.key
            }
        }
    }

    func quick(for key: LoudnessCache.Key) -> AudioAnalysis.Result? { quick[key] }
    func full(for key: LoudnessCache.Key) -> AudioAnalysis.Result? { full[key] }
    /// A hint for this song + segment under ANY byte size (a growing file re-keys as it grows).
    func quick(songId: String, segment: LoudnessAnalyzer.Segment?) -> AudioAnalysis.Result? {
        quick.first { $0.key.songId == songId && $0.key.segment == segment }?.value
    }
    var fullCountForTesting: Int { full.count }
    /// The best results known for a song id (any file / segment of it — the latest analysed).
    func results(songId: String) -> (full: AudioAnalysis.Result?, quick: AudioAnalysis.Result?) {
        guard let k = latestKey[songId] else { return (nil, nil) }
        if full[k] != nil { usedAt[k] = Date().timeIntervalSince1970 }
        return (full[k], quick[k])
    }

    func store(_ r: AudioAnalysis.Result, for key: LoudnessCache.Key) {
        switch r.kind {
        case .quick:
            guard full[key] == nil else { return }          // a hint never overwrites a final
            quick[key] = r
        case .full:
            // The same song + segment under another byte size is a STALE file (re-rip / re-cut,
            // or a growing file's interim size): drop it — never two answers for one song.
            for k in Array(full.keys) where k.songId == key.songId && k.segment == key.segment && k != key {
                full[k] = nil; usedAt[k] = nil
            }
            for k in Array(quick.keys) where k.songId == key.songId && k.segment == key.segment {
                quick[k] = nil                              // the final supersedes every hint
            }
            full[key] = r
            scheduleSave()
        }
        usedAt[key] = Date().timeIntervalSince1970
        latestKey[key.songId] = key
        revision &+= 1
    }

    /// Debounced; the encode is on the main actor (small), the write is not.
    private func scheduleSave() {
        saveTask?.cancel()
        let wait = Self.saveDebounceSeconds
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            guard let (data, url) = self.encodedForSave() else { return }
            await Task.detached(priority: .utility) { Self.write(data, to: url) }.value
        }
    }

    /// Write now (tests / a flush): the same pruned body, synchronously.
    func flushForTesting() {
        saveTask?.cancel(); saveTask = nil
        if let (data, url) = encodedForSave() { Self.write(data, to: url) }
    }

    /// The LRU cap applied, then the body encoded.
    private func encodedForSave() -> (Data, URL)? {
        if full.count > Self.maxEntries {
            let drop = full.keys.sorted { (usedAt[$0] ?? 0) < (usedAt[$1] ?? 0) }.prefix(full.count - Self.maxEntries)
            for k in drop {
                full[k] = nil; usedAt[k] = nil
                if latestKey[k.songId] == k { latestKey[k.songId] = nil }
            }
        }
        let entries = full.map { Entry(key: $0.key, result: $0.value, usedAt: usedAt[$0.key]) }
            .sorted { ($0.key.songId, $0.key.byteSize) < ($1.key.songId, $1.key.byteSize) }
        guard let data = try? JSONEncoder().encode(FileBody(entries: entries)) else { return nil }
        return (data, fileURL)
    }

    private nonisolated static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Scheduler (low QoS, ≤ 2 passes at once, priority order)

/// Runs quick → full passes off the main actor at background QoS, at most `maxConcurrent` at a
/// time, highest priority first: the CURRENT song → the next-up (a listener's pick first) → the
/// rest of the plan window. Nothing starts while Low Power Mode is on or the device is thermally
/// serious (it resumes on the next enqueue / completion once that clears).
@MainActor
final class AudioAnalysisScheduler {
    static let shared = AudioAnalysisScheduler(cache: .shared)

    enum Priority: Int, Comparable, Sendable {
        case current = 0, userNext, next, window
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    struct Job {
        var key: LoudnessCache.Key
        /// Opens the file when the job STARTS (its security scope is held only while it runs —
        /// 40 queued rows never pin 40 scopes). nil ⇒ the file is gone; the job is dropped.
        var open: () -> (url: URL, release: (() -> Void)?)?
        var sliceStartSeconds: Double
        var durationSeconds: Double?
        /// The whole file is on disk (false: a growing / ripping file — the head pass, re-run later).
        var complete: Bool
        var priority: Priority
        /// Head retries so far (a growing file that never reaches `minHeadSeconds` gives up).
        var headRetries = 0
        /// The scheduler generation it was queued in (`cancelPending` bumps it: a stale retry dies).
        var generation = 0

        /// A growing file re-keys (its byte size) every time it is looked at — its head jobs are
        /// one job per song + segment.
        var headID: HeadID { HeadID(songId: key.songId, segment: key.segment) }
    }

    struct HeadID: Hashable { var songId: String; var segment: LoudnessAnalyzer.Segment? }

    /// A growing file is looked at this many times (× `headRetrySeconds`) before giving up.
    static var maxHeadRetries = 24

    let cache: AudioAnalysisCache
    var maxConcurrent = 1
    /// SEAM (tests): the blocking passes. Default: the real `AudioAnalysis` passes.
    var quickPass: @Sendable (URL, Double, AudioAnalysis.Window) -> AudioAnalysis.Result? = {
        AudioAnalysis.quickPass(url: $0, sliceStartSeconds: $1, window: $2)
    }
    var fullPass: @Sendable (URL, Double, Double) -> AudioAnalysis.Result? = {
        AudioAnalysis.fullPass(url: $0, sliceStartSeconds: $1, durationSeconds: $2)
    }
    var available: @Sendable (URL, Double) -> Double = { AudioAnalysis.availableSeconds(url: $0, sliceStartSeconds: $1) }
    /// SEAM: the device may run analysis now (Low Power Mode off, thermal state below serious).
    var mayRun: () -> Bool = {
        let p = ProcessInfo.processInfo
        return !p.isLowPowerModeEnabled && p.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }
    /// Posted on the main actor after each stored result (`object`: the `LoudnessCache.Key`) —
    /// the Now Playing sequencer and the Mix engine both listen.
    static let resultNotification = Notification.Name("pdj.audioAnalysis.result")

    private var pending: [Job] = []
    private var running: Set<LoudnessCache.Key> = []
    private var runningHeads: Set<HeadID> = []
    private var deferred: [HeadID: Job] = [:]
    /// Bumped by `cancelPending` — a head retry from before it never comes back.
    private(set) var generation = 0
    /// Started order (tests).
    private(set) var startedOrderForTesting: [String] = []
    /// A growing file waiting for enough head audio is re-tried after this.
    static var headRetrySeconds: Double = 5

    init(cache: AudioAnalysisCache) { self.cache = cache }

    /// Queue (or re-prioritise) a file. A file already fully analysed is skipped; a head-only
    /// hint is re-run once the file is complete.
    func enqueue(_ job: Job) {
        var job = job
        job.generation = generation
        if cache.full(for: job.key) != nil { return }
        // Still arriving and its head hint is in (under any interim size): nothing new to learn
        // until it completes.
        if !job.complete, cache.quick(songId: job.key.songId, segment: job.key.segment) != nil { return }
        if running.contains(job.key) || runningHeads.contains(job.headID) {
            // The file completed while its head pass ran: the better window + full pass follow.
            if job.complete { deferred[job.headID] = job }
            return
        }
        // One head job per song + segment, whatever size the file has reached.
        if !job.complete, let i = pending.firstIndex(where: { !$0.complete && $0.headID == job.headID }) {
            pending[i].priority = min(pending[i].priority, job.priority)
            pump()
            return
        }
        if job.complete { pending.removeAll { !$0.complete && $0.headID == job.headID } }
        if let i = pending.firstIndex(where: { $0.key == job.key }) {
            var j = pending[i]
            j.priority = min(j.priority, job.priority)
            j.complete = j.complete || job.complete
            j.durationSeconds = job.durationSeconds ?? j.durationSeconds
            pending[i] = j
        } else {
            pending.append(job)
        }
        pump()
    }

    /// Drop queued (not running) work — DJ Mode off / the session ended.
    func cancelPending() { pending.removeAll(); deferred.removeAll(); generation &+= 1 }

    var pendingKeysForTesting: [String] { ordered().map(\.key.songId) }

    private func ordered() -> [Job] {
        pending.enumerated().sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }.map(\.element)
    }

    private func pump() {
        guard mayRun() else { return }
        while running.count < max(1, maxConcurrent), let job = ordered().first {
            pending.removeAll { $0.key == job.key }
            running.insert(job.key)
            if !job.complete { runningHeads.insert(job.headID) }
            startedOrderForTesting.append(job.key.songId)
            run(job)
        }
    }

    private func run(_ job: Job) {
        guard let file = job.open() else {
            finished(job, retryHead: false, release: nil)
            return
        }
        let url = file.url, slice = job.sliceStartSeconds
        let quickPass = self.quickPass, fullPass = self.fullPass, available = self.available
        let hadFinalHint = cache.quick(for: job.key).map { !$0.headOnly } ?? false
        Task.detached(priority: .background) { [weak self] in
            let avail = available(url, slice)
            let dur = job.durationSeconds.map { min($0, avail) } ?? avail
            // QUICK: on a better window unless a non-head hint already exists.
            var quick: AudioAnalysis.Result?
            var waitForHead = false
            if !hadFinalHint {
                if let w = AudioAnalysis.quickWindow(durationSeconds: job.durationSeconds, availableSeconds: avail,
                                                     complete: job.complete) {
                    quick = quickPass(url, slice, w)
                } else if !job.complete {
                    waitForHead = true
                }
            }
            if let quick { await self?.landed(job.key, quick) }
            // FULL: only once the whole file is here.
            var full: AudioAnalysis.Result?
            if job.complete, dur > 2 { full = fullPass(url, slice, dur) }
            if let full { await self?.landed(job.key, full) }
            await self?.finished(job, retryHead: waitForHead, release: file.release)
        }
    }

    private func landed(_ key: LoudnessCache.Key, _ r: AudioAnalysis.Result) {
        cache.store(r, for: key)
        DJMode.log("analysis \(r.kind.rawValue)\(r.headOnly ? " (head)" : "") song=\(key.songId) "
                   + "bpm=\(r.bpm.map { String(format: "%.1f", $0) } ?? "-")@\(String(format: "%.2f", r.bpmConfidence)) "
                   + "key=\(r.camelot ?? "-")@\(String(format: "%.2f", r.keyConfidence)) "
                   + "lufs=\(r.lufs.map { String(format: "%.1f", $0) } ?? "-")")
        NotificationCenter.default.post(name: Self.resultNotification, object: key)
    }

    private func finished(_ job: Job, retryHead: Bool, release: (() -> Void)?) {
        release?()
        running.remove(job.key)
        if !job.complete { runningHeads.remove(job.headID) }
        if let next = deferred.removeValue(forKey: job.headID) {
            enqueue(next)
        } else if retryHead, job.headRetries < Self.maxHeadRetries, job.generation == generation {
            var job = job
            job.headRetries += 1
            let gen = generation
            // Not enough of the growing file yet — look again shortly (unless cancelled since).
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.headRetrySeconds * 1_000_000_000))
                guard let self, self.generation == gen else { return }
                self.enqueue(job)
            }
        }
        pump()
    }
}
