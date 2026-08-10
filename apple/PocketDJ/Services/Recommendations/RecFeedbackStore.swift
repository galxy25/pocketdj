import Foundation
import Observation
import os

/// THE ONE record of accept / reject decisions on recommendations.
///
/// ── WHY ONE STORE AND NOT TWO PATHS ──────────────────────────────────────────────────────────
/// The owner asked for both modes: act on what is PLAYING (now-playing deck, mini-bar, widget,
/// CarPlay) and come back to the TILE later and work the list. Those are two entry points, not
/// two features — a thumbs-down given in the car must already be reflected the next time the tile
/// opens, and a row rejected on the tile must show as rejected on the lock screen if that song
/// comes round again. So there is exactly one store, one `record` call, and one wire event; every
/// surface is an adapter over this type. The likely defect in a feature shaped like this is two
/// paths that can disagree, and this is the structural answer to it.
///
/// ── LAST-WRITER-WINS PER SONG ────────────────────────────────────────────────────────────────
/// The log is append-only (so the engine can see that you rejected something three times), but
/// the STATE of a song is its most recent decision. Tapping ♥-up after a ♥-down flips it; tapping
/// the same control again clears it (a `cleared` row). That is what makes a mis-tap in the car
/// recoverable without an undo stack.
///
/// Same durable-JSON skeleton as `PuzzleDecisionStore` — lenient decode, union-by-id merge,
/// coalesced saves through a serial writer guarded by a write GENERATION, `applyPulledPayload`
/// for the CloudSync write seam. Deliberately the same shape rather than a second one: this
/// project already paid for that store's races (a stale enqueued snapshot landing after a pull),
/// and re-deriving them here would be re-paying.
@MainActor
@Observable
final class RecFeedbackStore {

    /// What a decision says. `RecFeedbackAction` lives in `Shared/` because the widget extension
    /// renders the same vocabulary off the App Group snapshot; this alias is here so every call
    /// site in the app reads `RecFeedbackStore.Action` like the rest of the store's types.
    typealias Action = RecFeedbackAction

    /// Where the listener acted. Not used by the ranking — it exists so the engine (and a future
    /// review of this feature) can tell a considered tap on a tile from one made at a red light.
    enum Surface: String, Codable, Sendable {
        case tile, nowPlaying, miniBar, widget, carPlay, intent
    }

    struct Decision: Codable, Identifiable, Equatable, Sendable {
        var id: UUID
        var at: Double                  // epoch ms
        var songId: String
        var action: String              // Action.rawValue — string for forward-compat
        var surface: String?            // Surface.rawValue
        /// The tile the decision was made from ("zone" / "suggested" / "col-<id>"), when there
        /// was one. nil for a now-playing / widget / CarPlay decision, which has no tile context.
        var context: String?
        /// The collection a tile-scoped accept added into, when the surface knew one.
        var collectionId: String?
        var originInstallId: String?
    }

    struct Document: Codable {
        var schemaVersion: Int = recFeedbackSchemaVersion
        var installId: String
        var decisions: [Decision] = []

        init(schemaVersion: Int = recFeedbackSchemaVersion, installId: String,
             decisions: [Decision] = []) {
            self.schemaVersion = schemaVersion; self.installId = installId
            self.decisions = decisions
        }

        enum CodingKeys: String, CodingKey { case schemaVersion, installId, decisions }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? recFeedbackSchemaVersion
            installId = (try? c.decode(String.self, forKey: .installId)) ?? UUID().uuidString
            decisions = ((try? c.decode([LenientDecision].self, forKey: .decisions)) ?? [])
                .compactMap(\.decision)
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
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSave = false
    @ObservationIgnored private let writeQueue =
        DispatchQueue(label: "com.levi.pocketdj.rec-feedback", qos: .utility)
    /// Monotonic write generation — see `PuzzleDecisionStore` for the race this closes (a block
    /// already handed to the serial queue outlives task cancellation, so it re-checks currency
    /// itself before writing).
    @ObservationIgnored private let writeGeneration = OSAllocatedUnfairLock(initialState: 0)
    var hasUnsavedChanges: Bool { pendingSave }

    /// Memo for the derived state, keyed on `revision`. Every surface reads `state(for:)` on a
    /// render path, and re-folding a 20k-row log per row would be the "derivations in SwiftUI
    /// bodies" regression this project has already paid for once.
    @ObservationIgnored private var stateCache: (revision: Int, map: [String: Action])?

    nonisolated static let maxDecisions = 20_000
    nonisolated static let saveDebounce: Duration = .milliseconds(600)

    init(fileURL: URL = RecFeedbackStore.defaultURL()) {
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
                                                in: .userDomainMask, appropriateFor: nil,
                                                create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-rec-feedback.json")
    }

    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdj-uitest-rec-feedback.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    // ========================================================================
    // MARK: - Recording
    // ========================================================================

    @discardableResult
    func record(songId: String, action: Action, surface: Surface,
                context: String? = nil, collectionId: String? = nil,
                at nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Decision? {
        guard !songId.isEmpty else { return nil }
        let d = Decision(id: UUID(), at: nowMs, songId: songId, action: action.rawValue,
                         surface: surface.rawValue, context: context,
                         collectionId: collectionId, originInstallId: installId)
        append([d])
        return d
    }

    /// Tap-the-control semantics, shared by every surface: pressing the control a song already
    /// carries CLEARS it, pressing the other one FLIPS it. Returns the resulting state so a
    /// caller can decide what to do next (the tile's ＋, for instance, only fires on a fresh
    /// accept). One implementation so the phone, the car and the widget cannot drift.
    @discardableResult
    func toggle(songId: String, to action: Action, surface: Surface,
                context: String? = nil, collectionId: String? = nil,
                at nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Action {
        let resulting: Action = state(for: songId) == action ? .cleared : action
        record(songId: songId, action: resulting, surface: surface, context: context,
               collectionId: collectionId, at: nowMs)
        return resulting
    }

    private func append(_ rows: [Decision]) {
        decisions.append(contentsOf: rows)
        if decisions.count > Self.maxDecisions {
            decisions.removeFirst(decisions.count - Self.maxDecisions)
        }
        revision &+= 1
        scheduleSave()
    }

    // ========================================================================
    // MARK: - Derived state
    // ========================================================================

    /// songId → its CURRENT decision (last writer wins; `cleared` rows are folded out).
    var currentState: [String: Action] {
        if let c = stateCache, c.revision == revision { return c.map }
        var latestAt: [String: Double] = [:]
        var map: [String: Action] = [:]
        for d in decisions {
            guard let a = Action(rawValue: d.action) else { continue }
            // `>=` so two rows stamped the same millisecond resolve to the LATER-appended one,
            // which is the one the user tapped second.
            guard d.at >= (latestAt[d.songId] ?? -.greatestFiniteMagnitude) else { continue }
            latestAt[d.songId] = d.at
            if a == .cleared { map.removeValue(forKey: d.songId) } else { map[d.songId] = a }
        }
        stateCache = (revision, map)
        return map
    }

    func state(for songId: String) -> Action? { currentState[songId] }
    func isRejected(_ songId: String) -> Bool { currentState[songId] == .rejected }
    func isAccepted(_ songId: String) -> Bool { currentState[songId] == .accepted }

    /// How many rejections of one ARTIST amount to a full-strength penalty. Three, because an
    /// artist is a narrow thing to reject: three thumbs-down on the same name is a pattern, not a
    /// mood.
    nonisolated static let artistSaturation = 3.0
    /// …and for a GENRE. Much higher, and that gap is the whole point. `Genre.category` has ~12
    /// buckets over a 96k-song library where R&B/Soul and Hip-Hop/Rap alone are ~68% of all
    /// plays: normalizing a genre by "the most-rejected one" would let a SINGLE thumbs-down cut
    /// a third of the library by 45%. Saturating at eight means one rejection nudges its genre
    /// (~6%) and only a sustained, deliberate pattern moves it properly — which is also what
    /// makes the artist penalty distinguishable from the genre one rather than swamped by it.
    nonisolated static let genreSaturation = 8.0

    /// The ranking projection. PURE given the log + the two catalog lookups, so the engine never
    /// sees this store and the whole loop is testable from literals.
    ///
    /// The artist/genre shares SATURATE (count / saturation, capped at 1) rather than being
    /// normalized against the most-rejected entry. Max-normalization looks equivalent and is not:
    /// it makes the first rejection in any genre a full-strength one, because that genre is
    /// trivially its own maximum. Saturation makes the penalty proportional to how much the user
    /// has actually said, which is the difference between "I did not like that one" and "stop
    /// playing me this".
    func signal(artistKeyFor: (String) -> String?,
                genreFor: (String) -> String?) -> ZoneEngine.Feedback {
        var f = ZoneEngine.Feedback()
        var rejectedArtists: [String: Double] = [:]
        var rejectedGenres: [String: Double] = [:]
        var acceptedArtists: [String: Double] = [:]
        for (songId, action) in currentState {
            switch action {
            case .rejected:
                f.rejectedSongIds.insert(songId)
                if let a = artistKeyFor(songId), !a.isEmpty { rejectedArtists[a, default: 0] += 1 }
                if let g = genreFor(songId), !g.isEmpty { rejectedGenres[g, default: 0] += 1 }
            case .accepted:
                f.acceptedSongIds.insert(songId)
                if let a = artistKeyFor(songId), !a.isEmpty { acceptedArtists[a, default: 0] += 1 }
            case .cleared:
                continue   // folded out by `currentState` already; belt and braces
            }
        }
        func saturated(_ m: [String: Double], _ saturation: Double) -> [String: Double] {
            guard saturation > 0 else { return [:] }
            return m.mapValues { Swift.min(1, $0 / saturation) }
        }
        f.rejectedArtistShare = saturated(rejectedArtists, Self.artistSaturation)
        f.rejectedGenreShare = saturated(rejectedGenres, Self.genreSaturation)
        f.acceptedArtistShare = saturated(acceptedArtists, Self.artistSaturation)
        return f
    }

    // ========================================================================
    // MARK: - Sync + persistence (the PuzzleDecisionStore skeleton)
    // ========================================================================

    /// CloudSync write seam — land the pulled payload through the SAME serial queue the coalesced
    /// writer uses, bumping the generation first so a stale enqueued snapshot cannot clobber it.
    func applyPulledPayload(_ data: Data) {
        writeGeneration.withLock { $0 &+= 1 }
        let url = fileURL
        writeQueue.sync { try? data.write(to: url, options: .atomic) }
    }

    /// Union-by-id merge after a CloudSync pull. A decision made on the Mac and one made in the
    /// car are both real; the LWW is per SONG (in `currentState`), never per document.
    @discardableResult
    func reloadFromDisk() -> Bool {
        writeGeneration.withLock { $0 &+= 1 }
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return false }
        var byId = Dictionary(decisions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var addedFromDisk = 0
        for d in doc.decisions where byId[d.id] == nil { byId[d.id] = d; addedFromDisk += 1 }
        let weHoldRowsTheDocLacks = byId.count > doc.decisions.count
        decisions = byId.values.sorted { $0.at < $1.at || ($0.at == $1.at && $0.id.uuidString < $1.id.uuidString) }
        if decisions.count > Self.maxDecisions {
            decisions.removeFirst(decisions.count - Self.maxDecisions)
        }
        if addedFromDisk > 0 || weHoldRowsTheDocLacks { revision &+= 1 }
        guard weHoldRowsTheDocLacks else {
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

    /// Write any pending coalesced save NOW, synchronously (the scenePhase `.background` flush
    /// doctrine — a suspension→kill must not lose a decision made seconds earlier).
    func flush() {
        guard pendingSave else { return }
        save()
    }

    private func scheduleSave(debounce: Bool = true) {
        pendingSave = true
        saveTask?.cancel()
        let doc = Document(installId: installId, decisions: decisions)   // cheap COW snapshot
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
                    if generation.withLock({ $0 }) == gen { Self.write(doc, to: url) }
                    c.resume()
                }
            }
            guard !Task.isCancelled else { return }
            self?.pendingSave = false
        }
    }

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

let recFeedbackSchemaVersion = 1

// ============================================================================
// MARK: - The rec-engine seam
// ============================================================================

/// This store projected onto `RecFeedbackWire` — the mirror of `PuzzleRecEventBridge`, and
/// installed the same way (`RecommendationService.feedbackEventsProvider` in `PocketDJApp`).
///
/// UNLIKE the puzzle bridge, EVERY action rides — including `rejected` and `cleared`. That bridge
/// withholds its negatives because the wire it speaks has no notion of one, so uploading a skip
/// would have been read as a positive. This wire was designed for the negative: a reject that
/// never leaves the device is a reject the cloud engine keeps recommending against, which is the
/// whole complaint. `cleared` rides for the same reason — an undo the server never hears is an
/// undo that only works on one device.
extension RecFeedbackStore {
    func recFeedbackEvents(sinceMs: Double) -> [RecFeedbackWire] {
        decisions
            .filter { $0.at >= sinceMs && Action(rawValue: $0.action) != nil }
            .sorted { $0.at < $1.at }
            .map {
                RecFeedbackWire(id: $0.id.uuidString, atMs: $0.at, songId: $0.songId,
                                action: $0.action, surface: $0.surface, context: $0.context)
            }
    }
}

// ============================================================================
// MARK: - Display order (the ONE definition of "sunk")
// ============================================================================

/// Where a rejected row goes, and therefore what "play in order" plays.
///
/// A reject does NOT remove the row from a list that is already on screen — it SINKS it. Removing
/// it makes the decision unrecoverable without a rebuild, and the owner asked for a tuning loop,
/// not a delete button. The engine excludes rejected songs on the NEXT build (see
/// `ZoneEngine.Feedback`), so the sunk row is a within-session affordance that lets the listener
/// see, and undo, what they just did.
///
/// This is a PURE function on purpose, and it is the only place the order is decided. The tile's
/// list and the tile's ▶ both call it, so "play in order" cannot play a rejected song second while
/// the list shows it last — the two read the same array.
enum RecFeedbackOrder {
    /// Stable partition: everything not rejected in its original order, then the rejected rows in
    /// theirs. `Array.sorted` is NOT used — it is not guaranteed stable in Swift, and an unstable
    /// sort here would reshuffle a 90-row tile on every keystroke of state change.
    static func sink(_ ids: [String], rejected: Set<String>) -> [String] {
        guard !rejected.isEmpty else { return ids }
        var kept: [String] = []
        var sunk: [String] = []
        kept.reserveCapacity(ids.count)
        for id in ids {
            if rejected.contains(id) { sunk.append(id) } else { kept.append(id) }
        }
        return kept + sunk
    }
}
