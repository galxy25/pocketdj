import Foundation
import Observation

/// NAMED BOOKMARKS IN THE COLLECTION TIMELINE — "set and name cue points in the temporal stream
/// that I can jump to" (F8).
///
/// ## These are NOT the Studio / Mix cue points
/// `StudioStore`'s cues are positions INSIDE a piece of audio, in seconds from the top of a track,
/// and they exist to trigger playback. These are positions in the ADD-DATE stream of the whole
/// catalog — "the vinyl binge", "after the new turntable", "lockdown" — each one an epoch
/// millisecond the Collection timeline can scroll to. Two different things that happen to share an
/// English word. Separate file, separate schema, separate store, no shared code: conflating them
/// would put an audio offset and a calendar instant in the same field.
///
/// ## Shape
/// The same durable-JSON idiom every small store in this app uses: atomic save, lenient
/// decode-on-init (a missing / partial / forward-version document loads degraded rather than
/// resetting), a `PDJ_USE_FIXTURE` launch seam, a monotonic `revision` views key recomputes on, and
/// a cap. Every field past `id`/`name`/`atMs` is OPTIONAL so a later build can add to the schema
/// without a version bump — the lesson from `mix-deck-loop`, where a bump discarded live sessions.
///
/// ## Sync
/// Registered with `CloudSyncService` as `"timeline-cues"` and reloaded WHOLE-DOCUMENT (LWW), like
/// `PlayStatsStore` and unlike `CollectionActivityStore`'s union. Deliberate: this is a small,
/// hand-curated list where DELETES have to stick. A union merge cannot express a deletion without
/// tombstones, so a cue removed on the phone would be resurrected by the Mac's next push — the
/// worse failure for a list the user edits by hand. LWW's cost is the ordinary one: a cue added on
/// a device that was offline while another device pushed can be lost.
@MainActor
@Observable
final class TimelineCueStore {

    /// One named point on the add-date axis.
    struct Cue: Codable, Identifiable, Equatable, Hashable {
        var id: UUID
        /// What he called it. Trimmed, never empty (see `add`).
        var name: String
        /// WHERE on the timeline, epoch ms.
        var atMs: Double
        /// ADDITIVE-OPTIONAL: when the bookmark itself was created (not where it points).
        var createdAtMs: Double?
        /// ADDITIVE-OPTIONAL free-text note. Unused by the current UI; here so the schema does not
        /// need a bump the first time a note is wanted.
        var note: String?
    }

    /// The persisted, versioned document. LENIENT decode: a missing `cues` list ⇒ [], unknown keys
    /// ignored, and an individual un-decodable cue is DROPPED rather than throwing away the list
    /// (the per-element tolerance `CollectionActivityStore` learned the hard way — one bad row
    /// there reset an entire synced log and then re-pushed the truncation).
    struct Document: Codable {
        var schemaVersion: Int = timelineCueSchemaVersion
        var cues: [Cue] = []

        init(schemaVersion: Int = timelineCueSchemaVersion, cues: [Cue] = []) {
            self.schemaVersion = schemaVersion
            self.cues = cues
        }

        enum CodingKeys: String, CodingKey { case schemaVersion, cues }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? timelineCueSchemaVersion
            cues = ((try? c.decode([LenientCue].self, forKey: .cues)) ?? []).compactMap(\.cue)
        }
    }

    private struct LenientCue: Decodable {
        let cue: Cue?
        init(from decoder: Decoder) throws { cue = try? Cue(from: decoder) }
    }

    /// The cues, ALWAYS ordered oldest → newest by `atMs`. Sorted at every mutation so the menu and
    /// the editor never have to sort in a view body, and so two devices that added cues in a
    /// different order still render the same list.
    private(set) var cues: [Cue] = []
    /// Monotonic; bumped on every real mutation.
    private(set) var revision = 0

    @ObservationIgnored private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (registration reads the SAME URL the store was
    /// constructed with — never re-derives it, so fixture seams stay intact).
    var syncFileURL: URL { fileURL }

    /// A hand-made list; a cap only exists so a runaway caller can't grow the file without bound.
    /// Past it the OLDEST-CREATED cue is dropped (not the earliest on the timeline — a bookmark
    /// deep in 1998 is not more disposable than one from last week).
    nonisolated static let maxCues = 500
    /// Names are shown in a menu; a novel pasted in would make it unusable.
    nonisolated static let maxNameLength = 60

    init(fileURL: URL = TimelineCueStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            cues = doc.cues.sorted { $0.atMs < $1.atMs }
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-timeline-cues.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (deterministic, never touches the
    /// user's real cues). Mirrors `CollectionActivityStore.launchURL`.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdj-uitest-timeline-cues.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    // MARK: - Mutations

    /// Drop a named cue at `atMs`. Returns nil (and writes nothing) for a blank name or a
    /// nonsensical position, so a stray tap can never persist an anonymous marker.
    @discardableResult
    func add(name: String, atMs: Double,
             at nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Cue? {
        let trimmed = Self.clean(name)
        guard !trimmed.isEmpty, atMs > 0 else { return nil }
        let cue = Cue(id: UUID(), name: trimmed, atMs: atMs, createdAtMs: nowMs)
        cues.append(cue)
        trimToCap()
        sortAndPublish()
        return cue
    }

    /// Rename in place. A blank new name is REJECTED (the cue keeps its old name) rather than
    /// leaving an unlabelled row in the jump menu.
    @discardableResult
    func rename(_ id: UUID, to name: String) -> Bool {
        let trimmed = Self.clean(name)
        guard !trimmed.isEmpty, let idx = cues.firstIndex(where: { $0.id == id }),
              cues[idx].name != trimmed else { return false }
        cues[idx].name = trimmed
        sortAndPublish()
        return true
    }

    /// Move a cue to a different instant (dragging a bookmark, or fixing one set at the wrong spot).
    @discardableResult
    func move(_ id: UUID, toMs: Double) -> Bool {
        guard toMs > 0, let idx = cues.firstIndex(where: { $0.id == id }),
              cues[idx].atMs != toMs else { return false }
        cues[idx].atMs = toMs
        sortAndPublish()
        return true
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool {
        guard let idx = cues.firstIndex(where: { $0.id == id }) else { return false }
        cues.remove(at: idx)
        sortAndPublish()
        return true
    }

    /// Test / import seam: replace the whole list (persists).
    func replaceAll(_ newCues: [Cue]) {
        cues = newCues
        trimToCap()
        sortAndPublish()
    }

    /// Wipe (account deletion). Deletes the on-disk document entirely — no residual empty-but-
    /// present JSON — so the `AccountDeletionService` "each store removes its persisted file"
    /// contract holds, exactly like `CollectionActivityStore.clear()`.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        cues = []
        revision &+= 1
    }

    // MARK: - Reads

    /// The cue whose position is nearest `atMs`, within `toleranceMs`. Used to answer "is there
    /// already a bookmark here?" before dropping a second one on the same afternoon.
    func nearest(to atMs: Double, toleranceMs: Double) -> Cue? {
        cues.min { abs($0.atMs - atMs) < abs($1.atMs - atMs) }
            .flatMap { abs($0.atMs - atMs) <= toleranceMs ? $0 : nil }
    }

    // MARK: - Internals

    private static func clean(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
    }

    private func trimToCap() {
        guard cues.count > Self.maxCues else { return }
        // Oldest-CREATED first (a legacy cue with no creation stamp counts as oldest).
        let doomed = cues.sorted { ($0.createdAtMs ?? 0) < ($1.createdAtMs ?? 0) }
            .prefix(cues.count - Self.maxCues)
            .map(\.id)
        let drop = Set(doomed)
        cues.removeAll { drop.contains($0.id) }
    }

    private func sortAndPublish() {
        cues.sort { $0.atMs != $1.atMs ? $0.atMs < $1.atMs : $0.id.uuidString < $1.id.uuidString }
        revision &+= 1
        save()
    }

    private func save() {
        let doc = Document(cues: cues)
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Re-adopt the on-disk document after CloudSyncService pulled a newer cloud copy.
    /// WHOLE-DOCUMENT replace (LWW) — see the class doc for why this is a union's opposite here.
    /// Returns false always: this store never produces a superset that needs pushing back, so a
    /// pull can leave the file clean and the sync loop terminates (the ping-pong
    /// `CollectionActivityStore.reloadFromDisk` documents).
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return false }
        let incoming = doc.cues.sorted { $0.atMs < $1.atMs }
        if incoming != cues {
            cues = incoming
            revision &+= 1
        }
        return false
    }
}

let timelineCueSchemaVersion = 1
