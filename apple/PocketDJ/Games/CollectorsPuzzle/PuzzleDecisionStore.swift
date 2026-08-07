import Foundation
import Observation

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

    nonisolated static let maxDecisions = 20_000

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
        decisions.append(d)
        if decisions.count > Self.maxDecisions { decisions.removeFirst(decisions.count - Self.maxDecisions) }
        revision &+= 1
        save()
        return d
    }

    func decisions(forRound roundId: UUID) -> [Decision] {
        decisions.filter { $0.roundId == roundId }
    }

    /// Union-by-id merge after a CloudSync pull (conditional save — see PlayHistoryStore).
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return false }
        var byId = Dictionary(decisions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var addedFromDisk = 0
        for d in doc.decisions where byId[d.id] == nil { byId[d.id] = d; addedFromDisk += 1 }
        let weHoldRowsTheDocLacks = byId.count > doc.decisions.count
        decisions = byId.values.sorted { $0.at < $1.at }
        if decisions.count > Self.maxDecisions { decisions.removeFirst(decisions.count - Self.maxDecisions) }
        if addedFromDisk > 0 || weHoldRowsTheDocLacks { revision &+= 1 }
        guard weHoldRowsTheDocLacks else { return false }
        save()
        return true
    }

    func clear() {
        decisions = []
        revision &+= 1
        save()
    }

    private func save() {
        let doc = Document(installId: installId, decisions: decisions)
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }
}

let puzzleDecisionsSchemaVersion = 1
