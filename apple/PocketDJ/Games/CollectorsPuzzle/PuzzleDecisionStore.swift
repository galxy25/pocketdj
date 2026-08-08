import Foundation
import Observation
import os

/// The recommendation-engine-readable log of every Collectors Puzzle decision — which
/// song was ASSIGNED to which collection, SKIPPED, or EXPIRED (played out without the
/// player acting — a real signal), plus a snapshot of the round's weighting settings.
/// Same durable-JSON skeleton as `GameScoreboardStore` (lenient, union, installId).
@MainActor
@Observable
final class PuzzleDecisionStore {

    /// One decision. `action` stays a STRING on the wire for forward-compat.
    struct Decision: Codable, Identifiable, Equatable {
        var id: UUID
        var roundId: UUID
        var at: Double                // epoch ms
        var songId: String
        var action: String            // "assigned" | "skipped" | "expired"
        var collectionId: String?     // pkt_/pls_ target when assigned
        var collectionName: String?
        var positionInRound: Int?
        var settings: PuzzleSettings? // snapshot of the round's weighting settings
        var originInstallId: String?
    }

    struct Document: Codable {
        var schemaVersion: Int = puzzleDecisionsSchemaVersion
        var installId: String
        var decisions: [Decision] = []

        init(schemaVersion: Int = puzzleDecisionsSchemaVersion, installId: String, decisions: [Decision] = []) {
            self.schemaVersion = schemaVersion; self.installId = installId; self.decisions = decisions
        }

        enum CodingKeys: String, CodingKey { case schemaVersion, installId, decisions }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? puzzleDecisionsSchemaVersion
            installId = (try? c.decode(String.self, forKey: .installId)) ?? UUID().uuidString
            decisions = ((try? c.decode([LenientDecision].self, forKey: .decisions)) ?? []).compactMap(\.decision)
        }
    }

    private struct LenientDecision: Decodable {
        let decision: Decision?
        init(from decoder: Decoder) throws { decision = try? Decision(from: decoder) }
    }

    private(set) var decisions: [Decision] = []
    private(set) var installId: String
    private(set) var revision = 0

    @ObservationIgnored private let fileURL: URL
    var syncFileURL: URL { fileURL }
    /// The coalescing save (see `scheduleSave`) + the serial writer it orders through.
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSave = false
    @ObservationIgnored private let writeQueue =
        DispatchQueue(label: "com.levi.pocketdj.puzzle-decisions", qos: .utility)
    /// Monotonic WRITE GENERATION, checked INSIDE every queued coalesced block. Task
    /// cancellation cannot retract a block already handed to `writeQueue` — so a stale
    /// snapshot enqueued before a `save()`/pull could land AFTER it and clobber the newer
    /// document. Every supersession (a newer scheduled save, an immediate `save()`, a
    /// cloud-pull write, a merge) bumps the generation; a queued block whose captured
    /// generation is no longer current skips its write. Lock-protected: read from the
    /// utility queue, bumped from the main actor.
    @ObservationIgnored private let writeGeneration = OSAllocatedUnfairLock(initialState: 0)
    /// True while a recorded row has not reached disk yet.
    var hasUnsavedChanges: Bool { pendingSave }

    nonisolated static let maxDecisions = 20_000
    /// Coalescing window for gameplay-rate records.
    nonisolated static let saveDebounce: Duration = .milliseconds(600)

    init(fileURL: URL = PuzzleDecisionStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            decisions = doc.decisions
            installId = doc.installId
        } else {
            installId = UUID().uuidString
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-puzzle-decisions.json")
    }

    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-puzzle-decisions.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    @discardableResult
    func record(roundId: UUID, songId: String, action: String,
                collectionId: String? = nil, collectionName: String? = nil,
                positionInRound: Int? = nil, settings: PuzzleSettings? = nil,
                at nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Decision {
        let d = Decision(id: UUID(), roundId: roundId, at: nowMs, songId: songId,
                         action: action, collectionId: collectionId,
                         collectionName: collectionName, positionInRound: positionInRound,
                         settings: settings, originInstallId: installId)
        append([d])
        return d
    }

    /// Record several decisions with ONE persist — the puzzle ticker's drift re-sync
    /// expires every song the audio passed, and a per-row save would re-encode the whole
    /// document once per row, inside a 0.25 s ticker.
    @discardableResult
    func recordBatch(_ rows: [(songId: String, action: String, positionInRound: Int?)],
                     roundId: UUID, settings: PuzzleSettings? = nil,
                     at nowMs: Double = Date().timeIntervalSince1970 * 1000) -> [Decision] {
        guard !rows.isEmpty else { return [] }
        let made = rows.map {
            Decision(id: UUID(), roundId: roundId, at: nowMs, songId: $0.songId,
                     action: $0.action, collectionId: nil, collectionName: nil,
                     positionInRound: $0.positionInRound, settings: settings,
                     originInstallId: installId)
        }
        append(made)
        return made
    }

    private func append(_ rows: [Decision]) {
        decisions.append(contentsOf: rows)
        if decisions.count > Self.maxDecisions { decisions.removeFirst(decisions.count - Self.maxDecisions) }
        revision &+= 1
        scheduleSave()
    }

    func decisions(forRound roundId: UUID) -> [Decision] {
        decisions.filter { $0.roundId == roundId }
    }

    /// CloudSync write seam (`Entry.applyPayload`): land the pulled payload through the
    /// SAME serial queue the coalesced writer uses, bumping the write generation first —
    /// so a stale enqueued snapshot either lands BEFORE the pull (and is overwritten by
    /// it) or skips itself on the generation check. Without this ordering, the pull's
    /// direct file write could be clobbered between write and merge-read, dropping the
    /// peer's rows locally AND (via the next LWW push) in the cloud.
    func applyPulledPayload(_ data: Data) {
        writeGeneration.withLock { $0 &+= 1 }
        let url = fileURL
        writeQueue.sync { try? data.write(to: url, options: .atomic) }
    }

    /// Union-by-id merge after a CloudSync pull (conditional save — see PlayHistoryStore).
    @discardableResult
    func reloadFromDisk() -> Bool {
        // Invalidate any not-yet-run coalesced block before reading: its snapshot predates
        // this merge, and letting it land afterwards would drop the rows pulled here.
        writeGeneration.withLock { $0 &+= 1 }
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return false }
        var byId = Dictionary(decisions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var addedFromDisk = 0
        for d in doc.decisions where byId[d.id] == nil { byId[d.id] = d; addedFromDisk += 1 }
        let weHoldRowsTheDocLacks = byId.count > doc.decisions.count
        decisions = byId.values.sorted { $0.at < $1.at }
        if decisions.count > Self.maxDecisions { decisions.removeFirst(decisions.count - Self.maxDecisions) }
        if addedFromDisk > 0 || weHoldRowsTheDocLacks { revision &+= 1 }
        guard weHoldRowsTheDocLacks else {
            // A coalesced save scheduled BEFORE this merge holds a pre-merge snapshot —
            // letting it land would drop the rows we just pulled. Re-arm it on the merged
            // document instead (scheduleSave cancels the stale one).
            if pendingSave, addedFromDisk > 0 { scheduleSave() }
            return false
        }
        save()
        return true
    }

    func clear() {
        decisions = []
        revision &+= 1
        save()
    }

    /// Write any pending coalesced save NOW, synchronously (scenePhase `.background`, the
    /// mixSessions/studio flush doctrine — a suspension→kill must not lose the round).
    func flush() {
        guard pendingSave else { return }
        save()
    }

    /// Round-end flush: land the pending rows NOW but WITHOUT blocking the main actor —
    /// `flush()`'s synchronous drain pays an MB-scale encode right as the summary presents
    /// (and can queue behind an in-flight coalesced encode on top). The write is enqueued
    /// immediately (no debounce) on the serial writer; `pendingSave` stays true until it
    /// lands, so a suspension's synchronous `flush()` still catches a racing kill.
    func flushAsync() {
        guard pendingSave else { return }
        scheduleSave(debounce: false)
    }

    /// Gameplay records arrive ~1/second — and in bursts from the ticker's drift re-sync —
    /// while a full document at the 20k cap is megabytes of JSON. So a burst COALESCES into
    /// one write, and the encode+write runs OFF the main actor on a serial queue (writes
    /// therefore land in schedule order, newest last). `flush()`/`save()` close the
    /// suspension race by draining that queue synchronously; the write GENERATION closes
    /// the retraction race (a block already handed to the queue outlives task cancellation,
    /// so it re-checks currency itself before writing).
    private func scheduleSave(debounce: Bool = true) {
        pendingSave = true
        saveTask?.cancel()
        let doc = Document(installId: installId, decisions: decisions)  // cheap COW snapshot
        let url = fileURL
        let queue = writeQueue
        let generation = writeGeneration
        let gen = generation.withLock { (g: inout Int) -> Int in g &+= 1; return g }
        saveTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: Self.saveDebounce)
                guard !Task.isCancelled else { return }
            }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                queue.async {
                    // Superseded (a newer save, a save()/clear(), or a cloud pull/merge
                    // bumped the generation) ⇒ this snapshot is stale: write nothing.
                    if generation.withLock({ $0 }) == gen { Self.write(doc, to: url) }
                    c.resume()
                }
            }
            guard !Task.isCancelled else { return }   // a newer save superseded this one
            self?.pendingSave = false
        }
    }

    /// Immediate, ordered write (flush / clear / post-merge). Bumps the generation so any
    /// already-enqueued coalesced block skips itself, then writes `sync` on the serial
    /// queue so this write lands AFTER any block that is already mid-flight.
    private func save() {
        saveTask?.cancel()
        saveTask = nil
        pendingSave = false
        writeGeneration.withLock { $0 &+= 1 }
        let doc = Document(installId: installId, decisions: decisions)
        let url = fileURL
        writeQueue.sync { Self.write(doc, to: url) }
    }

    private nonisolated static func write(_ doc: Document, to url: URL) {
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: url, options: .atomic) }
    }
}

let puzzleDecisionsSchemaVersion = 1
