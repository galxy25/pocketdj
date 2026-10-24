import Foundation

/// DEAD-AIR METER — the key playback-health number: of the time the listener wanted the set
/// playing, how many seconds were SILENT, and where did they come from.
///
/// Two complementary feeds, rolled up per local calendar day and persisted (survives relaunch —
/// the supervisor's own `dead-air total` resets with every process):
///
///  1. CONTINUOUS (1 Hz, from `PlaybackSupervisor`): `activeSeconds` (listener wants sound and
///     the setlist lane owns it) vs `deadSeconds`, split into TRANSITION dead air (a start window
///     open / the track already ended) and MID-SONG dead air (a stall inside a playing song).
///  2. PER TRANSITION (precise, from `SetlistPlayer`): the gap from the moment a start began
///     (auto-advance at a track's end, a skip, a cold start) to the first proof of audio, keyed
///     by `from→to` backend. A start that hops rows (stall → on-device hop, dead source → next)
///     stays ONE transition, measured from its original start — that is the silence heard.
///
/// "Audio" is the engines' own proof: the AVPlayer rendering with an advancing clock, or MusicKit
/// reporting `.playing` with its playback time moving (`audioConfirmed`). Apple Music renders in a
/// system process, so its output can't be tapped — playback-time movement is the best available
/// signal, and it is the same one the supervisor already trusts.
///
/// Not covered: the Mix engine's deck lane (its own `[mix] hb` heartbeat) — the setlist lane only.
@MainActor
final class DeadAirMeter {
    static let shared = DeadAirMeter()

    struct Pair: Codable, Equatable {
        var n = 0
        var seconds: Double = 0
        var max: Double = 0
    }

    struct Day: Codable, Equatable {
        var activeSeconds: Double = 0
        var deadSeconds: Double = 0
        var transitionDeadSeconds: Double = 0
        var midSongDeadSeconds: Double = 0
        /// Measured transitions (closed by first audio).
        var transitions = 0
        var transitionGapSeconds: Double = 0
        var gapsOver1s = 0
        var gapsOver3s = 0
        var gapsOver10s = 0
        /// "appleMusic→burned" etc. — `cause` is folded in for non-advance starts ("start:…").
        var byPair: [String: Pair] = [:]

        /// Dead share of active time, 0…1 (0 when nothing was active).
        var deadRatio: Double { activeSeconds > 0 ? deadSeconds / activeSeconds : 0 }
    }

    struct Document: Codable, Equatable {
        var days: [String: Day] = [:]
    }

    /// Days kept on disk.
    nonisolated static let retentionDays = 60
    /// A summary line is logged after this many ACTIVE seconds (and on `flush`).
    static var summaryEveryActiveSeconds: Double = 600

    private(set) var document = Document()
    private let fileURL: URL?
    var log: (String) -> Void = { DiagLog.shared.log("deadair", $0) }
    var calendar = Calendar.current

    /// The open transition: when it began, what was playing before, and why it started.
    private(set) var open: (at: Date, from: String, cause: String)?
    /// The backend the open transition is currently trying (last `trackStarting`).
    private var openTo: String?
    /// The backend that last produced audio — the `from` of the next transition.
    private(set) var lastAudibleBackend: String?
    private var activeSinceSummary: Double = 0
    private var dirty = false
    private var lastSave = Date.distantPast

    init(fileURL: URL? = DeadAirMeter.defaultURL()) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            document = doc
        }
    }

    nonisolated static func defaultURL() -> URL? {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
        let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return dir?.appendingPathComponent("pocketdj-dead-air.json")
    }

    func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func day(_ date: Date = Date()) -> Day { document.days[dayKey(date)] ?? Day() }

    // MARK: Per-transition (SetlistPlayer)

    /// A start began. If a transition is already open (a hop / retry / dead-source advance inside
    /// the same silence), it keeps its original start and cause.
    func transitionBegan(cause: String, now: Date = Date()) {
        guard open == nil else { return }
        open = (now, lastAudibleBackend ?? "none", cause)
        openTo = nil
    }

    /// The open transition is now trying `backend` (called at each track start).
    func trackStarting(backend: String) {
        if open != nil { openTo = backend }
    }

    /// First proof of audio: close the open transition and record its gap.
    func firstAudio(backend: String? = nil, now: Date = Date()) {
        let to = backend ?? openTo ?? "?"
        defer { lastAudibleBackend = to }
        guard let o = open else { return }
        open = nil; openTo = nil
        let gap = max(0, now.timeIntervalSince(o.at))
        let key = o.cause == "advance" ? "\(o.from)→\(to)" : "\(o.cause):\(o.from)→\(to)"
        mutate(now) { d in
            d.transitions += 1
            d.transitionGapSeconds += gap
            if gap >= 1 { d.gapsOver1s += 1 }
            if gap >= 3 { d.gapsOver3s += 1 }
            if gap >= 10 { d.gapsOver10s += 1 }
            var p = d.byPair[key] ?? Pair()
            p.n += 1; p.seconds += gap; p.max = Swift.max(p.max, gap)
            d.byPair[key] = p
        }
        log(String(format: "gap=%.2fs from=%@ to=%@ cause=%@", gap, o.from, to, o.cause))
    }

    /// The listener stopped / paused / took a call mid-transition: that silence is theirs, not
    /// ours — drop it unrecorded.
    func transitionAbandoned(reason: String) {
        guard let o = open else { return }
        open = nil; openTo = nil
        log("abandoned cause=\(o.cause) from=\(o.from) reason=\(reason)")
    }

    // MARK: Continuous (PlaybackSupervisor, 1 Hz)

    func accumulate(active: Double, dead: Double, transitionDead: Double, now: Date = Date()) {
        guard active > 0 || dead > 0 else { return }
        mutate(now) { d in
            d.activeSeconds += active
            d.deadSeconds += dead
            d.transitionDeadSeconds += transitionDead
            d.midSongDeadSeconds += max(0, dead - transitionDead)
        }
        activeSinceSummary += active
        if activeSinceSummary >= Self.summaryEveryActiveSeconds {
            activeSinceSummary = 0
            logSummary(now)
        }
    }

    // MARK: Reporting + persistence

    func summaryLine(_ now: Date = Date()) -> String {
        let d = day(now)
        return String(format: "day=%@ active=%.0fs dead=%.0fs ratio=%.2f%% transitionDead=%.0fs midSongDead=%.0fs transitions=%d gap≥3s=%d gap≥10s=%d",
                      dayKey(now), d.activeSeconds, d.deadSeconds, d.deadRatio * 100,
                      d.transitionDeadSeconds, d.midSongDeadSeconds, d.transitions, d.gapsOver3s, d.gapsOver10s)
    }

    func logSummary(_ now: Date = Date()) { log(summaryLine(now)) }

    /// Persist now (backgrounding) and log the day's summary.
    func flush(now: Date = Date()) {
        if day(now).activeSeconds > 0 { logSummary(now) }
        save(force: true)
    }

    private func mutate(_ now: Date, _ body: (inout Day) -> Void) {
        let key = dayKey(now)
        var d = document.days[key] ?? Day()
        body(&d)
        document.days[key] = d
        dirty = true
        save(force: false, now: now)
    }

    private func save(force: Bool, now: Date = Date()) {
        guard dirty, let fileURL else { return }
        guard force || now.timeIntervalSince(lastSave) >= 30 else { return }
        prune(now)
        if let data = try? JSONEncoder().encode(document) {
            try? data.write(to: fileURL, options: .atomic)
        }
        dirty = false
        lastSave = now
    }

    private func prune(_ now: Date) {
        guard document.days.count > Self.retentionDays,
              let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: now) else { return }
        let keep = dayKey(cutoff)
        document.days = document.days.filter { $0.key >= keep }
    }

    #if DEBUG
    func resetForTesting() {
        document = Document(); open = nil; openTo = nil; lastAudibleBackend = nil
        activeSinceSummary = 0; dirty = false
    }
    #endif
}
