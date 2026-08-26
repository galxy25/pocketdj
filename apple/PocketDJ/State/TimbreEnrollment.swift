import Foundation

/// EVENT-DRIVEN cloud timbre enrollment: when a song lands in a collection, ask the rip server to
/// analyse it so the recommendation engine gets smarter the more the app is used.
///
/// ── WHY THIS HANGS OFF PERSISTENCE AND NOT OFF THE ADD BUTTONS ────────────────────────────────
/// There is no single function every add passes through. `addSongs(_:to:)` covers the Add-to
/// sheet, drag/drop, multi-select and the playlist views — but `MusicWithFriendsStore` calls
/// `addSong(_:toPocket:)` directly and `CarPlayModel` has its own `addSong(_:toTargetId:)`, so a
/// per-call-site hook is already incomplete today and would rot the moment a new surface lands.
///
/// What every membership mutation DOES share is the document write: `CollectionsStore.save()` is
/// the one funnel ("every mutator funnels through here"), which is also why `membershipRevision`
/// lives there. Enrolling from the persisted membership therefore catches every path that exists
/// AND every path that does not exist yet — the Add-to sheet, paste, the queue builder, Discover
/// and recognizer adds, write-back-driven adds, converted pockets, `.pdjcollection` import, and
/// adds made on another device that arrive by CloudKit pull.
///
/// ── COST ──────────────────────────────────────────────────────────────────────────────────────
/// `enroll` diffs the membership union against a persisted id set: a set-difference over ~15k ids,
/// sub-millisecond, and it allocates nothing when nothing changed (the overwhelmingly common
/// case, since `save()` also fires for reorders, renames and setlist edits).
///
/// ── OFFLINE SAFETY ────────────────────────────────────────────────────────────────────────────
/// New ids are appended to a QUEUE FILE first and only removed once the server has accepted them.
/// A failed POST — no server configured, no network, server down — leaves them queued for the next
/// drain, so an add is never blocked, never dropped, and never retried in a tight loop. The add
/// itself never awaits any of this.
///
/// ── IDEMPOTENCE ───────────────────────────────────────────────────────────────────────────────
/// Enrolling a song that is already analysed is a no-op at four independent layers; this class is
/// only the cheapest of them. The server filters on `wantTimbre` before enqueueing, the worker
/// dedups against S3, the SQS claim bounds duplicates, and the fold is last-write-wins. So the
/// client is deliberately allowed to be approximate — it must never be the thing that decides
/// whether analysis is needed.
@MainActor
final class TimbreEnrollment {
    /// Ids already handed to the server. Persisted so a relaunch does not re-send the entire
    /// library on the first `save()`.
    private var enrolled: Set<String> = []
    /// Ids accepted by `enroll` but not yet acknowledged by the server.
    private var pending: [String] = []
    private var draining = false
    private let fileURL: URL
    /// Injected so tests can drive the class without a server (and so the app can wire whichever
    /// transport it already has). Returns true when the server accepted the ids.
    var send: ([String]) async -> Bool = { _ in false }
    /// Cap on one POST body. The server also caps; this keeps a first-launch enrollment of a large
    /// library from building one enormous request.
    private let chunk = 500

    /// Beside the other per-launch stores. A UI-test run gets a throwaway file so a fixture
    /// launch never inherits (or writes) the real device's enrollment.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-timbre-enroll.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-timbre-enrollment.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Doc.self, from: data) {
            enrolled = Set(doc.enrolled)
            pending = doc.pending
        }
    }

    private struct Doc: Codable { var enrolled: [String]; var pending: [String] }

    /// Diff the current membership union against what has already been enrolled. Returns the
    /// number of NEWLY queued ids (0 on the common no-change path).
    @discardableResult
    func enroll(memberIds: some Sequence<String>) -> Int {
        var fresh: [String] = []
        for id in memberIds where !enrolled.contains(id) {
            enrolled.insert(id)
            fresh.append(id)
        }
        guard !fresh.isEmpty else { return 0 }
        pending.append(contentsOf: fresh)
        persist()
        drain()
        return fresh.count
    }

    /// Push queued ids to the server. Safe to call at any time — on launch, on a connectivity
    /// change, after an add. Single-flight; failures leave the queue intact.
    func drain() {
        guard !draining, !pending.isEmpty else { return }
        draining = true
        let batch = Array(pending.prefix(chunk))
        Task { [weak self] in
            let ok = await self?.send(batch) ?? false
            guard let self else { return }
            if ok {
                self.pending.removeFirst(min(batch.count, self.pending.count))
                self.persist()
            }
            self.draining = false
            // Keep going only while progress is being made; a failure stops the loop and waits
            // for the next natural trigger rather than spinning against a dead server.
            if ok && !self.pending.isEmpty { self.drain() }
        }
    }

    /// Forget an id so a later add re-enrolls it. Used when the server reports it never had audio,
    /// and by tests.
    func forget(_ id: String) { enrolled.remove(id); persist() }

    var pendingCount: Int { pending.count }
    var enrolledCount: Int { enrolled.count }

    private func persist() {
        let doc = Doc(enrolled: Array(enrolled).sorted(), pending: pending)
        guard let data = try? JSONEncoder().encode(doc) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
