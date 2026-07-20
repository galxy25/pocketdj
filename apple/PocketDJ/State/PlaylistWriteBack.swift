import Foundation
import Observation

/// The WRITE half of two-way collection sync (Levi 2026-07-20).
///
/// `syncConvertedCollections` / `reconcilePlaylist` have always been PULL-ONLY: an Apple
/// Music playlist changes upstream and the on-device duplicate follows it. Nothing ever
/// went the other way — adding a song to an Apple Music playlist from inside PocketDJ
/// silently only ever touched the local duplicate. This queue is the missing outbound leg:
/// every add to a source playlist lands (a) in the on-device duplicate immediately and
/// (b) in the REAL Apple Music library playlist as soon as MusicKit will take it.
///
/// WHY A DURABLE QUEUE AND NOT A FIRE-AND-FORGET AWAIT. The write can fail for reasons that
/// have nothing to do with the user's intent — offline, MusicKit not yet authorized, the
/// catalog song momentarily unresolvable — and the add has ALREADY happened locally by the
/// time we try. Dropping the write on the floor would leave the two sides permanently
/// divergent with no record that we owed Apple Music anything. So the intent is persisted
/// first and drained later, exactly like `TransferCoordinator`'s background transfers.
///
/// PERSISTENCE. Its OWN Application Support document, `pocketdj-playlist-writeback.json`
/// (the DiscoverAddsStore pattern: decode-on-init, atomic save, `PDJ_USE_FIXTURE` launch
/// seam). Deliberately NOT part of the collections document and deliberately NOT registered
/// with CloudSyncService: this is a DEVICE-LOCAL outbound intent log. Syncing it would make
/// the iPad replay a write the iPhone already delivered — the same song added to the same
/// Apple Music playlist twice.
///
/// THE SAFETY PROPERTY THIS MUST NOT BREAK. `reconcilePlaylist` computes source REMOVALS as
/// (`sourceSongIds` snapshot − current source). A locally-added song is not in that snapshot,
/// so it is never removal-eligible. That is what makes a failed write-back harmless: the add
/// simply stays local until the next successful delivery (or forever, benignly). Nothing here
/// — and nothing in `CollectionsStore.addSong(_:toIndexPlaylist:appleMusicId:)` — writes the
/// new song into `sourceSongIds`. The snapshot only ever advances from a real catalog refresh,
/// i.e. after Apple Music itself confirms the membership.
@MainActor
@Observable
final class PlaylistWriteBack {

    /// How many times a job is retried before it settles as `.failed`. Bounded on purpose:
    /// an un-deliverable write (playlist renamed away, song pulled from the catalog) must
    /// reach a terminal state instead of retrying on every launch forever.
    static let maxAttempts = 4

    /// Cap on the persisted job list. Queued + failed jobs are never pruned (they still
    /// mean something); settled `.delivered` / `.notApplicable` rows age out oldest-first.
    private static let historyLimit = 200

    // MARK: - Job

    /// Terminal-state machine. `queued` is the ONLY non-terminal state; every other value
    /// means the queue is done with this job and will not retry it unaided.
    enum JobState: String, Codable, Sendable {
        case queued
        /// Written to the real Apple Music library playlist.
        case delivered
        /// This platform/build can't write to Apple Music at all — macOS (and Catalyst),
        /// where `MusicLibrary`'s write methods are `@available(…, unavailable)`. The local
        /// add stands; there is nothing to retry, ever.
        case notApplicable
        /// `maxAttempts` deliveries all threw. Retryable only by explicit user action.
        case failed
    }

    /// One owed write: "this song belongs in that Apple Music playlist".
    ///
    /// `playlistName` is the join key, not `indexPlaylistId`: our `IndexPlaylist.id` comes
    /// from the indexer's Library.xml persistent id, which MusicKit knows nothing about, and
    /// `LibraryPlaylistFilter` exposes exactly `{id, name}` — so NAME is the only handle the
    /// two worlds share. The id is kept anyway for de-dupe and for showing the user which
    /// playlist a stuck job belongs to.
    struct Job: Codable, Identifiable, Equatable, Sendable {
        var id: String
        var indexPlaylistId: String
        var playlistName: String
        var songId: String
        var appleMusicId: String
        var queuedAtMs: Double
        var attempts: Int
        var lastError: String?
        var state: JobState
        /// Backoff gate — a job isn't retried before this instant. nil ⇒ eligible now.
        var nextAttemptAtMs: Double?
        /// When the job reached a terminal state (drives history pruning).
        var settledAtMs: Double?

        enum CodingKeys: String, CodingKey {
            case id, indexPlaylistId, playlistName, songId, appleMusicId,
                 queuedAtMs, attempts, lastError, state, nextAttemptAtMs, settledAtMs
        }

        init(id: String, indexPlaylistId: String, playlistName: String, songId: String,
             appleMusicId: String, queuedAtMs: Double, attempts: Int = 0, lastError: String? = nil,
             state: JobState = .queued, nextAttemptAtMs: Double? = nil, settledAtMs: Double? = nil) {
            self.id = id; self.indexPlaylistId = indexPlaylistId; self.playlistName = playlistName
            self.songId = songId; self.appleMusicId = appleMusicId; self.queuedAtMs = queuedAtMs
            self.attempts = attempts; self.lastError = lastError; self.state = state
            self.nextAttemptAtMs = nextAttemptAtMs; self.settledAtMs = settledAtMs
        }

        /// LENIENT by construction: every field falls back to a sane default so a document
        /// written by a future build (new fields) or an older one (missing fields) still
        /// decodes. A queue that fails to decode is a queue that silently forgets what the
        /// user asked for — the one failure mode this type exists to prevent.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
            indexPlaylistId = (try? c.decode(String.self, forKey: .indexPlaylistId)) ?? ""
            playlistName = (try? c.decode(String.self, forKey: .playlistName)) ?? ""
            songId = (try? c.decode(String.self, forKey: .songId)) ?? ""
            appleMusicId = (try? c.decode(String.self, forKey: .appleMusicId)) ?? ""
            queuedAtMs = (try? c.decode(Double.self, forKey: .queuedAtMs)) ?? 0
            attempts = (try? c.decode(Int.self, forKey: .attempts)) ?? 0
            lastError = try? c.decode(String.self, forKey: .lastError)
            state = (try? c.decode(JobState.self, forKey: .state)) ?? .queued
            nextAttemptAtMs = try? c.decode(Double.self, forKey: .nextAttemptAtMs)
            settledAtMs = try? c.decode(Double.self, forKey: .settledAtMs)
        }
    }

    private struct Document: Codable {
        var schemaVersion: Int = 1
        var jobs: [Job] = []
    }

    // MARK: - State

    private(set) var jobs: [Job] = []
    /// True while `run()` is draining (a second call is a no-op, so the UI can call it freely).
    private(set) var isRunning = false
    /// Most recent delivery failure, for a Settings/debug surface. Cleared on a clean drain.
    private(set) var lastError: String?

    @ObservationIgnored private let fileURL: URL
    /// The MusicKit seam. nil ⇒ nothing can be written from this build/platform (see
    /// `makeDefaultTransport`); tests substitute a stub and drive the whole queue with no
    /// account, no entitlement, and no network — the `AppleMusicFavoritesTransport` idiom.
    @ObservationIgnored var transport: (any PlaylistWriteBackTransport)?

    init(fileURL: URL = PlaylistWriteBack.defaultURL(),
         transport: (any PlaylistWriteBackTransport)? = nil) {
        self.fileURL = fileURL
        self.transport = transport
        jobs = Self.decode(fileURL)
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-playlist-writeback.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (the DiscoverAddsStore idiom).
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-playlist-writeback.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    private nonisolated static func decode(_ url: URL) -> [Job] {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return doc.jobs
    }

    // MARK: - Derived

    var pending: [Job] { jobs.filter { $0.state == .queued } }
    var failed: [Job] { jobs.filter { $0.state == .failed } }
    var pendingCount: Int { pending.count }

    /// Can this build reach Apple Music's library-playlist writes AT ALL? False on macOS /
    /// Catalyst, and false when the seam was never wired. The Add-to sheet reads this to tell
    /// the user up front that the add will stay on this device.
    var canWriteBack: Bool { transport?.isSupported ?? false }

    /// Only Apple Music source playlists have a real upstream to write back to. A vinyl /
    /// "My Digital" / Imported source playlist duplicates and adds locally, full stop.
    nonisolated static func isAppleMusicSource(_ sourceName: String) -> Bool {
        sourceName == Config.appleMusicSourceName
    }

    // MARK: - Enqueue

    /// Record an owed write. Returns nil (queues NOTHING) when there is no Apple Music
    /// identity to write — a vinyl / My Digital / Studio song has no `appleMusicId`, so
    /// there is no such thing as adding it to an Apple Music playlist; the local duplicate
    /// add is the whole of the operation. Also nil when an equivalent job is already queued
    /// or delivered, so a double-tap can't add the song upstream twice.
    @discardableResult
    func enqueue(indexPlaylistId: String, playlistName: String,
                 songId: String, appleMusicId: String?) -> Job? {
        let amId = (appleMusicId ?? "").trimmingCharacters(in: .whitespaces)
        guard !amId.isEmpty, !playlistName.isEmpty else { return nil }
        guard !jobs.contains(where: {
            $0.indexPlaylistId == indexPlaylistId && $0.songId == songId
                && ($0.state == .queued || $0.state == .delivered)
        }) else { return nil }

        let job = Job(id: "wbj_" + UUID().uuidString, indexPlaylistId: indexPlaylistId,
                      playlistName: playlistName, songId: songId, appleMusicId: amId,
                      queuedAtMs: Self.nowMs)
        jobs.append(job)
        prune()
        save()
        return job
    }

    // MARK: - Drain

    /// Fire-and-forget drain for call sites that can't await (a Button action, `.onAppear`,
    /// a scene-phase hook). Re-entrant-safe: `run()` no-ops while a drain is in flight.
    func runSoon() {
        guard !isRunning, !pending.isEmpty else { return }
        Task { await self.run() }
    }

    /// Deliver every eligible queued job, oldest first. Sequential on purpose — these are
    /// library MUTATIONS against one account, and MusicKit is happier with one at a time
    /// than with a burst.
    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        // No transport, or a platform whose MusicLibrary writes don't exist: settle the
        // queue as LOCAL-ONLY rather than spinning. This is the macOS answer — the add
        // already happened in the on-device duplicate, and that is all this build can do.
        guard let transport, transport.isSupported else {
            settleUnsupported()
            return
        }
        // Authorization / entitlement is a condition the USER can fix, so it must not burn
        // an attempt: leave the jobs queued and try again next launch.
        guard transport.canWrite else {
            lastError = "Sign in to Apple Music to finish adding these songs to your Apple Music playlists."
            return
        }

        let nowMs = Self.nowMs
        let due = jobs
            .filter { $0.state == .queued && ($0.nextAttemptAtMs ?? 0) <= nowMs }
            .sorted { $0.queuedAtMs < $1.queuedAtMs }
            .map(\.id)
        guard !due.isEmpty else { return }

        var anyFailed = false
        for id in due {
            let delivered = await attempt(id, transport: transport)
            // Persist after EVERY job, not once after the drain. `MusicLibrary.add` is not
            // idempotent and the write it performs is not retractable from this app, so the
            // ledger has to be durable at each transition: if iOS jettisons the process
            // mid-drain (a background kill during job 2 is ordinary, not exotic), an
            // in-memory-only `.delivered` for job 1 is lost, the next launch sees it still
            // `.queued`, re-delivers it, and the song appears TWICE in the user's real
            // Apple Music playlist. One extra small write per job is the correct trade
            // against a duplicate the user has to clean up by hand.
            save()
            if !delivered { anyFailed = true }
        }
        if !anyFailed { lastError = nil }
        prune()
        save()
    }

    /// One delivery attempt. Returns true on success. Never throws — a stuck job is a
    /// recorded state, not an error the caller has to handle.
    @discardableResult
    private func attempt(_ jobId: String, transport: any PlaylistWriteBackTransport) async -> Bool {
        guard let job = jobs.first(where: { $0.id == jobId }) else { return true }
        do {
            try await transport.addSong(appleMusicId: job.appleMusicId,
                                        toPlaylistNamed: job.playlistName)
            update(jobId) {
                $0.attempts += 1
                $0.lastError = nil
                $0.state = .delivered
                $0.nextAttemptAtMs = nil
                $0.settledAtMs = Self.nowMs
            }
            return true
        } catch {
            let attempts = job.attempts + 1
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            update(jobId) {
                $0.attempts = attempts
                $0.lastError = message
                if attempts >= Self.maxAttempts {
                    $0.state = .failed
                    $0.nextAttemptAtMs = nil
                    $0.settledAtMs = Self.nowMs
                } else {
                    $0.nextAttemptAtMs = Self.nowMs + Self.backoffMs(attempts)
                }
            }
            lastError = message
            return false
        }
    }

    /// Settle every queued job as "this device can't do that" — terminal, so the queue
    /// stops thinking it owes Apple Music anything (macOS, or an unwired seam).
    private func settleUnsupported() {
        let ids = pending.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids {
            update(id) {
                $0.state = .notApplicable
                $0.nextAttemptAtMs = nil
                $0.settledAtMs = Self.nowMs
                $0.lastError = "Apple Music playlists can’t be edited from this device — the song was added to your local copy only."
            }
        }
        prune()
        save()
    }

    /// Re-arm a `.failed` job (an explicit user retry — "the playlist is back, try again").
    func retry(_ jobId: String) {
        update(jobId) {
            guard $0.state == .failed else { return }
            $0.state = .queued; $0.attempts = 0; $0.lastError = nil
            $0.nextAttemptAtMs = nil; $0.settledAtMs = nil
        }
        save()
    }
    func retryFailed() {
        for id in failed.map(\.id) { retry(id) }
    }

    /// Forget a job outright (the user gave up on it). Only meaningful for settled jobs.
    func discard(_ jobId: String) {
        jobs.removeAll { $0.id == jobId }
        save()
    }

    /// Re-decode after an external write (parity with the other durable stores; this
    /// document is NOT cloud-synced, so in practice only tests call it).
    func reloadFromDisk() { jobs = Self.decode(fileURL) }

    // MARK: - Internals

    private static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    /// 30 s → 1 min → 2 min. Short enough that a "was offline for a second" job lands in the
    /// same session, long enough that four failures don't all happen inside one screen tap.
    private static func backoffMs(_ attempts: Int) -> Double {
        30_000 * pow(2, Double(max(0, attempts - 1)))
    }

    private func update(_ jobId: String, _ body: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        body(&jobs[i])
    }

    /// Bound the document: settled `.delivered` / `.notApplicable` rows age out oldest-first
    /// once the list exceeds `historyLimit`. Queued and failed jobs are always kept — they
    /// still represent something the user asked for.
    private func prune() {
        guard jobs.count > Self.historyLimit else { return }
        let settled = jobs
            .filter { $0.state == .delivered || $0.state == .notApplicable }
            .sorted { ($0.settledAtMs ?? $0.queuedAtMs) < ($1.settledAtMs ?? $1.queuedAtMs) }
        var drop = Set<String>()
        var overflow = jobs.count - Self.historyLimit
        for job in settled where overflow > 0 {
            drop.insert(job.id); overflow -= 1
        }
        guard !drop.isEmpty else { return }
        jobs.removeAll { drop.contains($0.id) }
    }

    private func save() {
        let doc = Document(jobs: jobs)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Transport factory

    /// The production transport, or nil on a platform that simply cannot do this. Wired at
    /// app init; kept here so exactly one place knows the platform answer.
    static func makeDefaultTransport() -> (any PlaylistWriteBackTransport)? {
        #if canImport(MusicKit) && !os(macOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 16.0, visionOS 1.0, *) { return MusicKitPlaylistWriteBackTransport() }
        return nil
        #else
        return nil
        #endif
    }
}

// MARK: - Errors

enum PlaylistWriteBackError: Error, LocalizedError {
    case unsupportedPlatform
    case notAuthorized
    case songNotFound(String)
    case playlistNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Apple Music playlists can’t be edited from this device."
        case .notAuthorized:
            return "PocketDJ isn’t connected to Apple Music."
        case .songNotFound(let id):
            return "Couldn’t find this song in the Apple Music catalog (\(id))."
        case .playlistNotFound(let name):
            return "Couldn’t find an Apple Music playlist named “\(name)” in your library."
        }
    }
}

// MARK: - Transport seam

/// The MusicKit seam, mirroring `AppleMusicFavoritesTransport`: the real implementation is
/// the only thing in the write-back path that touches MusicKit, so every retry rule, state
/// transition, and persistence behaviour above is unit-testable against a stub.
@MainActor
protocol PlaylistWriteBackTransport: AnyObject {
    /// Can this platform write to library playlists AT ALL? PERMANENT, not a runtime
    /// condition — false on macOS / Catalyst, where `MusicLibrary.add(_:to:)` is
    /// `@available(…, unavailable)`. A false here settles jobs as `.notApplicable`.
    var isSupported: Bool { get }
    /// Can a write go out RIGHT NOW (Apple Music enabled in this build + authorized)? A
    /// false here leaves jobs queued — the user can fix it and we'll try again.
    var canWrite: Bool { get }
    /// Add the catalog song `appleMusicId` to the LIBRARY playlist named `playlistName`.
    /// Throws on any failure so the queue can retry.
    func addSong(appleMusicId: String, toPlaylistNamed playlistName: String) async throws
}

#if canImport(MusicKit) && !os(macOS) && !targetEnvironment(macCatalyst)
import MusicKit

/// Production transport.
///
/// Two lookups, because the two id spaces don't meet:
///   1. `MusicCatalogResourceRequest<Song>(matching: \.id, equalTo:)` — our
///      `IndexSong.appleMusicId` IS a catalog store id (resolved by
///      `scripts/resolve-apple-music-catalog.mjs`), so this is exact. Same idiom as
///      `AppleMusicProvider.fetchSong(storeID:)`.
///   2. `MusicLibraryRequest<Playlist>.filter(matching: \.name, equalTo:)` — resolves the
///      LIVE library playlist. By NAME because that is the only field the two worlds share:
///      `LibraryPlaylistFilter` exposes exactly `{id, name}` (verified in the iOS 26 SDK
///      swiftinterface) and our `IndexPlaylist.id` is the indexer's Library.xml persistent
///      id, which MusicKit has never heard of.
///
/// KNOWN LIMIT of the name join: two library playlists with the SAME name are
/// indistinguishable here, and we take the first match. Failing instead would strand the
/// job permanently on a condition the user can't see; picking the first at least lands the
/// song in a playlist by that name. The file/type docs and the Add-to sheet's footer are
/// the honest disclosure.
///
/// The whole class is compiled out on macOS / Catalyst — `MusicLibrary`'s write methods
/// don't exist there — so `makeDefaultTransport()` returns nil and the queue resolves
/// LOCAL-ONLY rather than pretending it will retry.
@available(iOS 16.0, visionOS 1.0, *)
@MainActor
final class MusicKitPlaylistWriteBackTransport: PlaylistWriteBackTransport {

    var isSupported: Bool { true }

    var canWrite: Bool {
        AppleMusicCredentials.isEnabled && MusicAuthorization.currentStatus == .authorized
    }

    func addSong(appleMusicId: String, toPlaylistNamed playlistName: String) async throws {
        guard canWrite else { throw PlaylistWriteBackError.notAuthorized }

        var songReq = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id,
                                                                 equalTo: MusicItemID(appleMusicId))
        songReq.limit = 1
        guard let song = try await songReq.response().items.first else {
            throw PlaylistWriteBackError.songNotFound(appleMusicId)
        }

        var listReq = MusicLibraryRequest<MusicKit.Playlist>()
        listReq.filter(matching: \.name, equalTo: playlistName)
        listReq.limit = 1
        guard let playlist = try await listReq.response().items.first else {
            throw PlaylistWriteBackError.playlistNotFound(playlistName)
        }

        _ = try await MusicLibrary.shared.add(song, to: playlist)
    }
}
#endif
