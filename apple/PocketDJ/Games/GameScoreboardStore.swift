import Foundation
import Observation

/// The games this scoreboard knows about. Raw values are persisted tokens — never rename.
enum GameKind: String, Codable, CaseIterable {
    case collectorsPuzzle, musicWithFriends

    /// Human label for scoreboard headers.
    var label: String {
        switch self {
        case .collectorsPuzzle: return "Collectors Puzzle"
        case .musicWithFriends: return "Music with Friends"
        }
    }
}

/// Durable, append-only log of game RUNS (one row per finished round/session) — the
/// Games tab's scoreboard. Modeled on `PlayHistoryStore`: per-element lenient decode,
/// union-by-run-id merge across devices, installId attribution, atomic saves.
@MainActor
@Observable
final class GameScoreboardStore {

    /// One finished run. `game` stays a STRING on the wire so a newer build's unknown
    /// game kind never breaks an older build's decode (forward-compat doctrine).
    struct RunRecord: Codable, Identifiable, Equatable {
        var id: UUID
        var game: String              // GameKind rawValue
        var score: Int
        var at: Double                // epoch ms
        var settingsSummary: String?  // e.g. "2:00 · favorites · 1990–1999 · 3 targets"
        var detail: [String: String]? // game-specific extras (sessionId, theme, …)
        var originInstallId: String?
    }

    struct Document: Codable {
        var schemaVersion: Int = gameScoreboardSchemaVersion
        var installId: String
        var runs: [RunRecord] = []

        init(schemaVersion: Int = gameScoreboardSchemaVersion, installId: String, runs: [RunRecord] = []) {
            self.schemaVersion = schemaVersion; self.installId = installId; self.runs = runs
        }

        enum CodingKeys: String, CodingKey { case schemaVersion, installId, runs }

        /// Lenient per-element decode (the PlayHistoryStore doctrine): one unreadable
        /// row — written by a newer build — must never nuke the whole scoreboard.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? gameScoreboardSchemaVersion
            installId = (try? c.decode(String.self, forKey: .installId)) ?? UUID().uuidString
            runs = ((try? c.decode([LenientRun].self, forKey: .runs)) ?? []).compactMap(\.run)
        }
    }

    private struct LenientRun: Decodable {
        let run: RunRecord?
        init(from decoder: Decoder) throws { run = try? RunRecord(from: decoder) }
    }

    /// Oldest → newest (insertion order == chronological for live runs).
    private(set) var runs: [RunRecord] = []
    private(set) var installId: String
    /// Monotonic, bumped on every real mutation — views key recomputes on it.
    private(set) var revision = 0

    @ObservationIgnored private let fileURL: URL
    var syncFileURL: URL { fileURL }

    nonisolated static let maxRuns = 500

    init(fileURL: URL = GameScoreboardStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            runs = doc.runs
            installId = doc.installId
        } else {
            installId = UUID().uuidString
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-game-scores.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (mirrors PlayHistoryStore.launchURL).
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-game-scores.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    /// Record a finished run (zero-score runs included — recent-runs history shows them).
    @discardableResult
    func record(game: GameKind, score: Int, settingsSummary: String?,
                detail: [String: String]? = nil,
                at nowMs: Double = Date().timeIntervalSince1970 * 1000) -> RunRecord {
        let run = RunRecord(id: UUID(), game: game.rawValue, score: score, at: nowMs,
                            settingsSummary: settingsSummary, detail: detail,
                            originInstallId: installId)
        runs.append(run)
        if runs.count > Self.maxRuns { runs.removeFirst(runs.count - Self.maxRuns) }
        revision &+= 1
        save()
        return run
    }

    func bestScore(_ game: GameKind) -> Int? {
        runs.lazy.filter { $0.game == game.rawValue }.map(\.score).max()
    }

    /// The best run — highest score, newest wins a tie.
    func bestRun(_ game: GameKind) -> RunRecord? {
        runs.filter { $0.game == game.rawValue }
            .max { ($0.score, $0.at) < ($1.score, $1.at) }
    }

    /// Newest first.
    func recentRuns(_ game: GameKind, limit: Int) -> [RunRecord] {
        Array(runs.lazy.filter { $0.game == game.rawValue }.suffix(limit).reversed())
    }

    /// UNION the on-disk document into the live log after a CloudSync pull —
    /// id-keyed, idempotent, conditional save (the PlayHistoryStore contract).
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return false }
        var byId = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var addedFromDisk = 0
        for r in doc.runs where byId[r.id] == nil { byId[r.id] = r; addedFromDisk += 1 }
        let weHoldRowsTheDocLacks = byId.count > doc.runs.count
        runs = byId.values.sorted { $0.at < $1.at }
        if runs.count > Self.maxRuns { runs.removeFirst(runs.count - Self.maxRuns) }
        if addedFromDisk > 0 || weHoldRowsTheDocLacks { revision &+= 1 }
        guard weHoldRowsTheDocLacks else { return false }
        save()
        return true
    }

    func clear() {
        runs = []
        revision &+= 1
        save()
    }

    /// UI-test seam: `PDJ_SEED_GAMES` seeds 3 puzzle runs (5/9/7) + 1 MwF run (4) so the
    /// scoreboard renders populated deterministically. No-op when runs already exist.
    func seedFixtureIfRequested() {
        guard ProcessInfo.processInfo.environment["PDJ_SEED_GAMES"] != nil else { return }
        seedFixture()
    }

    /// The env-free seed body (unit-testable; the env gate lives above).
    func seedFixture() {
        guard runs.isEmpty else { return }
        let now = Date().timeIntervalSince1970 * 1000
        let hour = 3600.0 * 1000
        record(game: .collectorsPuzzle, score: 5, settingsSummary: "2:00 · 1 target", at: now - 30 * hour)
        record(game: .collectorsPuzzle, score: 9, settingsSummary: "2:00 · 2 targets", at: now - 20 * hour)
        record(game: .collectorsPuzzle, score: 7, settingsSummary: "1:00 · 1 target", at: now - 10 * hour)
        record(game: .musicWithFriends, score: 4, settingsSummary: "90s road-trip anthems",
               detail: ["sessionId": "seedmwf1"], at: now - 5 * hour)
    }

    private func save() {
        let doc = Document(installId: installId, runs: runs)
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }
}

let gameScoreboardSchemaVersion = 1
