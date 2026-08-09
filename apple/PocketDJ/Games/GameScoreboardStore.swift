import Foundation
import Observation

/// The games this scoreboard knows about. Raw values are persisted tokens — never rename.
///
/// DISPLAY NAMES MAY CHANGE FREELY — `label` is the only user-facing string. The game now
/// SHOWN as "Gem Collector" keeps the persisted token `collectorsPuzzle`, because that
/// rawValue is written into `pocketdj-game-scores.json` (CloudKit-synced, union-merged
/// across devices), is stamped into already-uploaded `RecPuzzleEventWire.gameId`, and is
/// what the a11y ids `games-best-<rawValue>` / `games-run-<rawValue>-<i>` are derived from.
/// Renaming the case orphans every existing high score with no repair path — see
/// `GameScoreboardStoreTests.testGameKindTokensAreFrozenWhileLabelsAreFree`.
enum GameKind: String, Codable, CaseIterable {
    case collectorsPuzzle, musicWithFriends

    /// Human label for scoreboard headers.
    var label: String {
        switch self {
        case .collectorsPuzzle: return "Gem Collector"
        case .musicWithFriends: return "Music with Friends"
        }
    }
}

/// Durable log of game RUNS (one row per finished round/session) — the Games tab's
/// scoreboard. Modeled on `PlayHistoryStore`: per-element lenient decode,
/// union-by-run-id merge across devices, installId attribution, atomic saves.
///
/// ── DELETION NEEDS TOMBSTONES ───────────────────────────────────────────────────────────
/// The log is grow-only across devices: `reloadFromDisk` UNIONS the on-disk document into
/// the live log by run id and is deliberately idempotent for ADDS. A plain row drop is
/// therefore NOT durable — another device's CloudSync pull writes a document that still
/// contains the deleted runs, the union adds them straight back, and the deletion silently
/// undoes itself. A tombstone is the only thing that survives a union: a positive assertion
/// ("this id is gone") rather than an absence, exactly as `FavoritesStore` stores an explicit
/// un-♥ instead of removing the row. The merge invariant is stated on `reloadFromDisk`.
///
/// FORWARD-COMPAT HAZARD (accepted, not engineered around): an OLD build decoding a NEW
/// document drops `deleted` and, on its next save, rewrites the doc without it. The runs stay
/// deleted unless a THIRD never-upgraded device still holds them. All three platforms ship
/// together and this syncs only within one user's own devices, so the window is stated here
/// rather than defended against — there is no code fix that doesn't require the old build.
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

    /// A DELETED run, by id — see the type header for WHY an absence isn't enough.
    ///
    /// `at` orders EVICTION and nothing else: a tombstone is a fact, not a value, so two
    /// devices naming the same id agree no matter which timestamp wins, and `at` is never a
    /// merge tie-break (clock skew across devices would make that unsound).
    struct Tombstone: Codable, Identifiable, Equatable {
        var id: UUID              // the deleted RunRecord.id
        var at: Double            // epoch ms of the deletion — eviction order only
        var byInstallId: String?
    }

    struct Document: Codable {
        var schemaVersion: Int = gameScoreboardSchemaVersion
        var installId: String
        var runs: [RunRecord] = []
        /// ADDITIVE-OPTIONAL: absent in every pre-2026-08-08 document, and the synthesized
        /// `encode(to:)` uses `encodeIfPresent`, so a store with no deletions still writes the
        /// exact byte shape the shipped build wrote. `schemaVersion` deliberately STAYS 1 —
        /// matching `FavoritesStore.seedVersion`, which was added the same way: nothing gates
        /// on the number, and bumping it only invites a future gate to reject old documents.
        var deleted: [Tombstone]? = nil

        init(schemaVersion: Int = gameScoreboardSchemaVersion, installId: String,
             runs: [RunRecord] = [], deleted: [Tombstone]? = nil) {
            self.schemaVersion = schemaVersion; self.installId = installId
            self.runs = runs; self.deleted = deleted
        }

        enum CodingKeys: String, CodingKey { case schemaVersion, installId, runs, deleted }

        /// Lenient per-element decode (the PlayHistoryStore doctrine): one unreadable
        /// row — written by a newer build — must never nuke the whole scoreboard.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? gameScoreboardSchemaVersion
            installId = (try? c.decode(String.self, forKey: .installId)) ?? UUID().uuidString
            runs = ((try? c.decode([LenientRun].self, forKey: .runs)) ?? []).compactMap(\.run)
            deleted = ((try? c.decode([LenientTombstone].self, forKey: .deleted)) ?? []).compactMap(\.stone)
        }
    }

    private struct LenientRun: Decodable {
        let run: RunRecord?
        init(from decoder: Decoder) throws { run = try? RunRecord(from: decoder) }
    }

    /// Per-element lenient, same doctrine as `LenientRun`: one malformed tombstone written by
    /// a newer build must not take the rest of the deletions — or the runs — down with it.
    private struct LenientTombstone: Decodable {
        let stone: Tombstone?
        init(from decoder: Decoder) throws { stone = try? Tombstone(from: decoder) }
    }

    /// Oldest → newest (insertion order == chronological for live runs).
    private(set) var runs: [RunRecord] = []
    /// Deleted run ids, oldest → newest by `at`. Persisted, synced, capped.
    private(set) var tombstones: [Tombstone] = []
    private(set) var installId: String
    /// Monotonic, bumped on every real mutation — views key recomputes on it.
    private(set) var revision = 0

    /// O(1) suppression set — `tombstones` projected by id. Not observed: every read of it is
    /// paired with a `runs`/`tombstones` mutation that already invalidates the view.
    @ObservationIgnored private var deletedIds: Set<UUID> = []

    @ObservationIgnored private let fileURL: URL
    var syncFileURL: URL { fileURL }

    nonisolated static let maxRuns = 500
    /// 4× `maxRuns`, evicted OLDEST-FIRST. You cannot prune a tombstone by "the run is gone
    /// locally" — that is precisely the state in which it is doing its job, and there is no
    /// local signal that every device has converged (age-based pruning has the same flaw with
    /// a nicer name). Unbounded is worse: a synced document that only ever grows. At ~90
    /// bytes/tombstone this is ~180 KB, and `maxRuns = 500` means it takes FOUR full
    /// "delete all" wipes to fill. The eviction failure mode is bounded and benign: a peer
    /// offline across 2000 deletions that still holds the exact run gets ONE stale row back,
    /// which the user deletes again. (Rejected alternative: a per-game `deletedBefore`
    /// watermark — far more compact, but it wrongly suppresses a legitimately older run when
    /// clocks skew across devices or a run is recorded offline and synced late.)
    nonisolated static let maxTombstones = 2000

    init(fileURL: URL = GameScoreboardStore.defaultURL()) {
        self.fileURL = fileURL
        let doc = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(Document.self, from: $0) }
        installId = doc?.installId ?? UUID().uuidString
        // Tombstones FIRST, then filter the runs through them: a racing peer document can
        // legitimately carry both a run and its tombstone, and launch must never show it.
        adopt(tombstones: doc?.deleted ?? [])
        runs = (doc?.runs ?? []).filter { !deletedIds.contains($0.id) }
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
        // The cap trim NEVER tombstones. It is a local DISPLAY bound, not a user deletion —
        // tombstoning here would turn "my log got long on this device" into a cross-device
        // erase of rows the peers are still happily showing.
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

    // MARK: - Deletion (the user-facing pair — see `clear()` for the erasure path)

    /// Delete every recorded run of ONE game — the scoreboard row's context menu. Returns how
    /// many rows went. TOMBSTONED, so the deletion survives a peer's union merge.
    @discardableResult
    func delete(game: GameKind, at nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Int {
        deleteRuns(runs.filter { $0.game == game.rawValue }, at: nowMs)
    }

    /// Delete EVERY run of EVERY game — the "Scoreboard" header's ⋯ / context menu.
    @discardableResult
    func deleteAll(at nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Int {
        deleteRuns(runs, at: nowMs)
    }

    private func deleteRuns(_ doomed: [RunRecord], at nowMs: Double) -> Int {
        guard !doomed.isEmpty else { return 0 }
        let ids = Set(doomed.map(\.id))
        runs.removeAll { ids.contains($0.id) }
        adopt(tombstones: tombstones + doomed.map {
            Tombstone(id: $0.id, at: nowMs, byInstallId: installId)
        })
        revision &+= 1
        save()
        return doomed.count
    }

    /// Union tombstones by id — earliest `at` wins (a tombstone is a fact, not a value, so the
    /// tie-break only decides eviction order) — kept oldest-first and capped at
    /// `maxTombstones`. Returns how many ids are NEWLY suppressed.
    @discardableResult
    private func adopt(tombstones incoming: [Tombstone]) -> Int {
        var byId: [UUID: Tombstone] = [:]
        for t in incoming {
            if let have = byId[t.id] { if t.at < have.at { byId[t.id] = t } } else { byId[t.id] = t }
        }
        var merged = byId.values.sorted { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }
        if merged.count > Self.maxTombstones { merged.removeFirst(merged.count - Self.maxTombstones) }
        let before = deletedIds
        self.tombstones = merged
        deletedIds = Set(merged.map(\.id))
        return deletedIds.subtracting(before).count
    }

    /// UNION the on-disk document into the live log after a CloudSync pull —
    /// id-keyed, idempotent, conditional save (the PlayHistoryStore contract).
    ///
    /// THE MERGE INVARIANT, precisely:
    ///
    ///     live  = (localRuns ∪ docRuns) ∖ ids(localTombs ∪ docTombs)
    ///     saved = live, ids(localTombs ∪ docTombs)
    ///
    /// Both halves are GROW-ONLY UNIONS KEYED BY ID, so the merge is commutative, associative
    /// and idempotent: pull order is irrelevant and re-applying a document changes nothing.
    /// Run ids are fresh UUIDs and never reused, so a tombstone can only ever suppress the run
    /// it names. REVERSE DIRECTION: a device that has never seen a tombstone keeps pushing the
    /// run; every pull re-adds it to `byId` and the filter drops it again, and because that doc
    /// LACKS a tombstone we hold we re-save and re-publish — so the peer eventually learns and
    /// the deletion converges without any device being online at delete time. SCOPE: a
    /// tombstone names the ids THIS device holds at delete time; after a sync pass that is
    /// every run on every device.
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return false }
        let docTombs = doc.deleted ?? []
        let tombsAdded = adopt(tombstones: tombstones + docTombs)

        var byId = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var addedFromDisk = 0
        for r in doc.runs where byId[r.id] == nil { byId[r.id] = r; addedFromDisk += 1 }
        let before = runs.count
        runs = byId.values.filter { !deletedIds.contains($0.id) }.sorted { $0.at < $1.at }
        if runs.count > Self.maxRuns { runs.removeFirst(runs.count - Self.maxRuns) }
        let rowsDropped = max(0, before + addedFromDisk - runs.count)   // tombstoned or cap-trimmed

        // THE DOC IS STALE W.R.T. US — and must be rewritten — when it lacks a run we keep,
        // lacks a tombstone we hold, or STILL CARRIES a run we have tombstoned.
        //
        // The old `byId.count > doc.runs.count` count proxy is NO LONGER SOUND. It answers only
        // "do we hold extra RUNS", and the load-bearing deletion case has none: we deleted every
        // run, the doc still has them, `byId.count == doc.runs.count` → no save → our tombstones
        // never publish AND the on-disk doc keeps the runs, so the very next launch's `init`
        // resurrects them. Deletion DURABILITY, not just propagation, rides on this being
        // id-based.
        let docRunIds = Set(doc.runs.map(\.id))
        let docTombIds = Set(docTombs.map(\.id))
        let mustSave = runs.contains { !docRunIds.contains($0.id) }
            || !deletedIds.isSubset(of: docTombIds)
            || !docRunIds.isDisjoint(with: deletedIds)
        if addedFromDisk > 0 || rowsDropped > 0 || tombsAdded > 0 || mustSave { revision &+= 1 }
        guard mustSave else { return false }
        save()
        return true
    }

    /// HARD WIPE — account deletion (`AccountDeletionService`, the App Store 5.1.1(v) erasure
    /// guarantee) and the authoritative fixture seed. NOT the user-facing delete: leaving 500
    /// tombstones behind after "erase my account" is residual personal data about the user's
    /// activity, and it would make the seeded document non-byte-clean. The user's deletes are
    /// `delete(game:)` / `deleteAll()`, which tombstone; do not "unify" the two.
    func clear() {
        runs = []
        tombstones = []
        deletedIds = []
        revision &+= 1
        save()
    }

    /// UI-test seam: `PDJ_SEED_GAMES` seeds 3 puzzle runs (5/9/7) + 1 MwF run (4) so the
    /// scoreboard renders populated deterministically.
    ///
    /// Unlike the UserDefaults-backed fixture seams — which the isolated launch domain wipes
    /// for free — this scoreboard persists to a FILE, so "already has runs" is a state that can
    /// arrive from OUTSIDE this launch: a CloudSync pull landing on `syncFileURL` before the
    /// seed runs, a demo or on-device build pointed at `defaultURL()` (no `PDJ_USE_FIXTURE`, so
    /// no freshly-cleared container), or a run recorded earlier in the same session. A bare
    /// `runs.isEmpty` gate lets any of those SILENTLY veto the seed, and the scoreboard then
    /// renders a stale best — or, to a UI test looking for `games-best-collectorsPuzzle`, no
    /// such element at all. Under `PDJ_USE_FIXTURE` the seed is therefore AUTHORITATIVE: it
    /// replaces whatever it finds, persisted document included. Outside the fixture flag it
    /// keeps the polite no-op so a demo seed never eats a real player's history.
    func seedFixtureIfRequested() {
        guard ProcessInfo.processInfo.environment["PDJ_SEED_GAMES"] != nil else { return }
        seedFixture(replaceExisting: ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil)
    }

    /// The env-free seed body (unit-testable; the env gate lives above). `replaceExisting`
    /// clears the log — and the saved document behind it — first, so the seeded scoreboard is
    /// byte-identical no matter what a previous launch left on disk.
    func seedFixture(replaceExisting: Bool = false) {
        if replaceExisting {
            if !runs.isEmpty { clear() }
        } else {
            guard runs.isEmpty else { return }
        }
        let now = Date().timeIntervalSince1970 * 1000
        let hour = 3600.0 * 1000
        record(game: .collectorsPuzzle, score: 5, settingsSummary: "2:00 · 1 target", at: now - 30 * hour)
        record(game: .collectorsPuzzle, score: 9, settingsSummary: "2:00 · 2 targets", at: now - 20 * hour)
        record(game: .collectorsPuzzle, score: 7, settingsSummary: "1:00 · 1 target", at: now - 10 * hour)
        record(game: .musicWithFriends, score: 4, settingsSummary: "90s road-trip anthems",
               detail: ["sessionId": "seedmwf1"], at: now - 5 * hour)
    }

    private func save() {
        // `nil` and not `[]` when there is nothing deleted: `encodeIfPresent` then omits the
        // key entirely, so a store that has never deleted writes the pre-tombstone byte shape.
        let doc = Document(installId: installId, runs: runs,
                           deleted: tombstones.isEmpty ? nil : tombstones)
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }
}

let gameScoreboardSchemaVersion = 1
