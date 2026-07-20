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
    /// `playlistName` is only the BOOTSTRAP key. Our `IndexPlaylist.id` is the indexer's
    /// Library.xml persistent id, which MusicKit has never heard of, so the very first
    /// delivery for a playlist has to start from the name — but a name is a terrible join
    /// key (Levi 2026-07-20: "Sap " in the index vs. "Sap" in the live library lost a song
    /// silently). So the name is used ONCE to resolve the playlist's stable MusicKit
    /// library id, and `musicKitPlaylistId` is what every write actually uses from then on.
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
        /// The stable MusicKit library-playlist id this job resolved to, once known.
        /// OPTIONAL and additive: an older document has no such key, and a document written
        /// by this build still decodes on a build that doesn't know the field — which is why
        /// `schemaVersion` does NOT move (a bump would strand the user's queued writes).
        var musicKitPlaylistId: String?
        /// Human-readable note about HOW the playlist was resolved when the answer wasn't
        /// obvious (several library playlists share the name). Surfaced in Settings ▸ Sync
        /// so a guess is visible rather than silent — the failure mode this whole change is
        /// about is a wrong-or-missing playlist join that nobody could see.
        var resolutionNote: String?

        enum CodingKeys: String, CodingKey {
            case id, indexPlaylistId, playlistName, songId, appleMusicId,
                 queuedAtMs, attempts, lastError, state, nextAttemptAtMs, settledAtMs,
                 musicKitPlaylistId, resolutionNote
        }

        init(id: String, indexPlaylistId: String, playlistName: String, songId: String,
             appleMusicId: String, queuedAtMs: Double, attempts: Int = 0, lastError: String? = nil,
             state: JobState = .queued, nextAttemptAtMs: Double? = nil, settledAtMs: Double? = nil,
             musicKitPlaylistId: String? = nil, resolutionNote: String? = nil) {
            self.id = id; self.indexPlaylistId = indexPlaylistId; self.playlistName = playlistName
            self.songId = songId; self.appleMusicId = appleMusicId; self.queuedAtMs = queuedAtMs
            self.attempts = attempts; self.lastError = lastError; self.state = state
            self.nextAttemptAtMs = nextAttemptAtMs; self.settledAtMs = settledAtMs
            self.musicKitPlaylistId = musicKitPlaylistId; self.resolutionNote = resolutionNote
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
            musicKitPlaylistId = try? c.decode(String.self, forKey: .musicKitPlaylistId)
            resolutionNote = try? c.decode(String.self, forKey: .resolutionNote)
        }
    }

    /// `resolvedPlaylistIds` is additive and OPTIONAL for the same reason the Job fields are:
    /// a document written before this change has no such key and must still decode into a
    /// working queue. schemaVersion stays at 1 on purpose.
    private struct Document: Codable {
        var schemaVersion: Int = 1
        var jobs: [Job] = []
        var resolvedPlaylistIds: [String: String]?
    }

    // MARK: - State

    private(set) var jobs: [Job] = []
    /// True while `run()` is draining (a second call is a no-op, so the UI can call it freely).
    private(set) var isRunning = false
    /// Most recent delivery failure, for a Settings/debug surface. Cleared on a clean drain.
    private(set) var lastError: String?

    /// A resolution the transport had to GUESS at — several library playlists share the
    /// indexed name and no track overlap arbitrated between them. Distinct from `lastError`
    /// on purpose: this describes a delivery that SUCCEEDED, possibly into the wrong
    /// playlist, so it must survive the clean-drain reset that clears `lastError`. Retired
    /// only when a later resolution for that playlist comes back unambiguous.
    private(set) var resolutionWarning: String?

    /// indexPlaylistId → stable MusicKit library-playlist id. Persisted so the resolve — which
    /// costs a fetch of the user's ENTIRE library playlist list — happens once per playlist
    /// ever, not once per queued song. Invalidated (per key) when a write reports `playlistGone`.
    private(set) var resolvedPlaylistIds: [String: String] = [:]

    /// Catalog seam for disambiguation: given an `indexPlaylistId`, the Apple Music store ids
    /// of the songs the INDEX thinks are in that playlist. Used only to pick between several
    /// live library playlists that share a name. Defaults to nothing, because the queue has no
    /// business knowing about the catalog — the app wires it at init.
    @ObservationIgnored var appleMusicIdsForIndexPlaylist: ((String) -> [String])?

    /// How many of the indexed playlist's track ids are handed to the transport for
    /// disambiguation. This picks between candidates; it does not verify membership, so a
    /// sample is as good as the whole list and far cheaper to compare.
    private static let disambiguationSampleLimit = 50

    @ObservationIgnored private let fileURL: URL
    /// The MusicKit seam. nil ⇒ nothing can be written from this build/platform (see
    /// `makeDefaultTransport`); tests substitute a stub and drive the whole queue with no
    /// account, no entitlement, and no network — the `AppleMusicFavoritesTransport` idiom.
    @ObservationIgnored var transport: (any PlaylistWriteBackTransport)?

    init(fileURL: URL = PlaylistWriteBack.defaultURL(),
         transport: (any PlaylistWriteBackTransport)? = nil) {
        self.fileURL = fileURL
        self.transport = transport
        let doc = Self.decode(fileURL)
        jobs = doc.jobs
        resolvedPlaylistIds = doc.resolvedPlaylistIds ?? [:]
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

    private nonisolated static func decode(_ url: URL) -> Document {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return Document() }
        return doc
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

        // Seed the job with the playlist's already-known MusicKit id when we have one: the
        // second song added to a playlist should never pay for the all-playlists fetch again.
        let job = Job(id: "wbj_" + UUID().uuidString, indexPlaylistId: indexPlaylistId,
                      playlistName: playlistName, songId: songId, appleMusicId: amId,
                      queuedAtMs: Self.nowMs,
                      musicKitPlaylistId: resolvedPlaylistIds[indexPlaylistId])
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
    ///
    /// THE JOIN, in order: use the id we already resolved for this playlist; otherwise resolve
    /// it by name ONCE and remember it. If the write comes back `playlistGone` the remembered
    /// id is stale (the playlist was deleted, or MusicKit re-minted it), so it is forgotten and
    /// re-resolved exactly once before giving up — one retry, not a loop, because a genuinely
    /// missing playlist would otherwise re-resolve forever inside a single attempt.
    @discardableResult
    private func attempt(_ jobId: String, transport: any PlaylistWriteBackTransport) async -> Bool {
        guard let job = jobs.first(where: { $0.id == jobId }) else { return true }
        do {
            let target = try await playlistId(for: job, transport: transport)
            do {
                try await transport.addSong(appleMusicId: job.appleMusicId, toPlaylistId: target)
            } catch PlaylistWriteBackError.playlistGone {
                forgetResolution(for: job.indexPlaylistId)
                let fresh = try await playlistId(for: job, transport: transport, forceResolve: true)
                try await transport.addSong(appleMusicId: job.appleMusicId, toPlaylistId: fresh)
            }
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

    /// The MusicKit id to write into, resolving (and remembering) it if we don't have one yet.
    /// Throws `playlistNotFound` when the live library has nothing by that name — an actionable
    /// end state: the user renamed or deleted the playlist and only they can say what to do.
    private func playlistId(for job: Job, transport: any PlaylistWriteBackTransport,
                            forceResolve: Bool = false) async throws -> String {
        if !forceResolve {
            if let known = resolvedPlaylistIds[job.indexPlaylistId] { return known }
            if let stored = job.musicKitPlaylistId, !stored.isEmpty {
                // The map is device-local and can be lost (fresh install restoring the queue
                // from a backup); the job carries its own copy, so re-seed the map from it.
                resolvedPlaylistIds[job.indexPlaylistId] = stored
                return stored
            }
        }
        let sample = Array((appleMusicIdsForIndexPlaylist?(job.indexPlaylistId) ?? [])
            .prefix(Self.disambiguationSampleLimit))
        guard let resolved = try await transport.resolvePlaylistId(name: job.playlistName,
                                                                   expectedAppleMusicIds: sample) else {
            throw PlaylistWriteBackError.playlistNotFound(job.playlistName)
        }
        resolvedPlaylistIds[job.indexPlaylistId] = resolved
        // A resolution the transport had to GUESS at (duplicate names) is recorded on the job
        // AND on `resolutionWarning`, because the whole point of this change is that a wrong
        // playlist join must never again be invisible.
        //
        // Deliberately NOT `lastError`: that means "the last thing that FAILED" and `run()`
        // clears it whenever a drain succeeds — which is precisely the case a guess survives.
        // A song written into the wrong playlist is a SUCCESSFUL delivery, so routing the
        // warning through lastError would erase it at the exact moment it started to matter.
        let note = transport.lastResolutionNote
        update(job.id) { $0.musicKitPlaylistId = resolved; $0.resolutionNote = note }
        // An unambiguous resolution for this playlist retires an earlier guess about it.
        resolutionWarning = note ?? (jobs.contains { $0.resolutionNote != nil } ? resolutionWarning : nil)
        save()
        return resolved
    }

    /// Drop a stale mapping (from both the map and every job that cached it) so the next
    /// attempt starts over from the name.
    private func forgetResolution(for indexPlaylistId: String) {
        resolvedPlaylistIds[indexPlaylistId] = nil
        for i in jobs.indices where jobs[i].indexPlaylistId == indexPlaylistId {
            jobs[i].musicKitPlaylistId = nil
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
    func reloadFromDisk() {
        let doc = Self.decode(fileURL)
        jobs = doc.jobs
        resolvedPlaylistIds = doc.resolvedPlaylistIds ?? [:]
    }

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
        let doc = Document(jobs: jobs, resolvedPlaylistIds: resolvedPlaylistIds)
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
    /// A previously-resolved MusicKit playlist id no longer resolves. NOT a user-facing end
    /// state: the queue catches this one, forgets the mapping, and re-resolves by name once.
    case playlistGone(String)

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
        case .playlistGone(let id):
            return "That Apple Music playlist is no longer in your library (\(id))."
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
    /// Resolve an indexed playlist to its STABLE MusicKit library-playlist id — the one join
    /// key that survives the name drift between Library.xml and MusicKit. Returns nil when the
    /// live library has no playlist that could plausibly be this one.
    ///
    /// `expectedAppleMusicIds` is a SAMPLE of the indexed playlist's track catalog ids, used
    /// ONLY to break a tie between several library playlists sharing a name. It is not a
    /// membership check and must never be treated as one.
    func resolvePlaylistId(name: String, expectedAppleMusicIds: [String]) async throws -> String?
    /// Add the catalog song `appleMusicId` to the library playlist with this MusicKit id.
    /// Throws `PlaylistWriteBackError.playlistGone` when the id no longer resolves, so the
    /// caller can drop its cached mapping and re-resolve once; throws anything else for retry.
    func addSong(appleMusicId: String, toPlaylistId playlistId: String) async throws
    /// Set by `resolvePlaylistId` when the answer was a GUESS (duplicate names, no track
    /// overlap to arbitrate). Defaulted so a stub never has to care.
    var lastResolutionNote: String? { get }
}

extension PlaylistWriteBackTransport {
    var lastResolutionNote: String? { nil }
}

#if canImport(MusicKit) && !os(macOS) && !targetEnvironment(macCatalyst)
import MusicKit

/// Production transport.
///
/// THE JOIN IS BY MUSICKIT ID, NOT BY NAME (Levi 2026-07-20). The previous implementation
/// resolved the live playlist with `.filter(matching: \.name, equalTo: playlistName)` — an
/// EXACT string match — and that lost a real song: "Sweet Thing" never reached Apple Music
/// because the indexed name is `"Sap "` (trailing space, straight out of Library.xml) while
/// the live library playlist is `"Sap"`. Exact-match found nothing and the job died quietly.
/// Names drift between Library.xml and MusicKit in every direction — whitespace, case,
/// diacritics — so the name is now used ONCE, fuzzily, to find the playlist's `id`, and the
/// id is what every subsequent write uses.
///
/// Three lookups, because the id spaces don't meet:
///   1. `MusicLibraryRequest<Playlist>()` with NO filter — the whole library playlist list,
///      matched in tiers locally (see `resolvePlaylistId`). Filtering server-side by name
///      can't express "trimmed" or "case-insensitive", which is exactly what we need.
///   2. `MusicLibraryRequest<Playlist>.filter(matching: \.id, equalTo:)` — the STABLE join.
///      `LibraryPlaylistFilter` exposes `{id, name}` (verified in the iOS 26 SDK
///      swiftinterface), so `id` is filterable; and `MusicLibrary.add(_:to:)` needs a
///      Playlist OBJECT, which is why a stored id still costs one request.
///   3. `MusicCatalogResourceRequest<Song>(matching: \.id, equalTo:)` — our
///      `IndexSong.appleMusicId` IS a catalog store id (resolved by
///      `scripts/resolve-apple-music-catalog.mjs`), so this is exact. Same idiom as
///      `AppleMusicProvider.fetchSong(storeID:)`.
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

    private(set) var lastResolutionNote: String?

    // MARK: Resolve

    func resolvePlaylistId(name: String, expectedAppleMusicIds: [String]) async throws -> String? {
        guard canWrite else { throw PlaylistWriteBackError.notAuthorized }
        lastResolutionNote = nil

        // No filter: fetch them all and match in tiers below. This is the expensive call, which
        // is why the queue caches the answer per playlist rather than repeating it per song.
        let all = try await MusicLibraryRequest<MusicKit.Playlist>().response().items
        let candidates = Self.candidates(named: name, in: Array(all))
        guard !candidates.isEmpty else { return nil }
        guard candidates.count > 1 else { return candidates[0].id.rawValue }

        // Several playlists really do share the name. Prefer the one whose tracks overlap what
        // the index says this playlist contains.
        let expected = Set(expectedAppleMusicIds)
        var best = candidates[0]
        var bestOverlap = -1
        for candidate in candidates {
            var overlap = 0
            if !expected.isEmpty, let tracks = (try? await candidate.with([.tracks]))?.tracks {
                for track in tracks where Self.catalogIds(of: track).contains(where: expected.contains) {
                    overlap += 1
                }
            }
            if overlap > bestOverlap { best = candidate; bestOverlap = overlap }
        }
        if bestOverlap <= 0 {
            // A tie, or nothing to arbitrate with: we take the first, but that IS a guess, and
            // a silent guess is the failure mode this whole path exists to end. Say so.
            lastResolutionNote = "Your library has \(candidates.count) playlists named “\(name)” — "
                + "PocketDJ picked the first one. If the song lands in the wrong playlist, rename them apart."
            best = candidates[0]
        }
        return best.id.rawValue
    }

    /// Every id a library track might be known by on the CATALOG side. `Track.id` is the
    /// LIBRARY id for a library track (`i.…`), which never equals one of our store ids — the
    /// catalog id is only reachable through `playParameters`, which MusicKit exposes as an
    /// opaque `Codable` blob rather than typed fields. Round-tripping it through JSON is the
    /// only way to read it, and it is best-effort by nature: a miss just means this candidate
    /// scores no overlap and the disambiguation falls back to "first, and say so".
    private static func catalogIds(of track: MusicKit.Track) -> [String] {
        var ids = [track.id.rawValue]
        if let params = track.playParameters,
           let data = try? JSONEncoder().encode(params),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["catalogId", "catalogID", "id"] {
                if let value = obj[key] as? String { ids.append(value) }
            }
        }
        return ids
    }

    /// Name matching in widening tiers, stopping at the first tier that matches ANYTHING —
    /// so an exact name always beats a fuzzy one and we never widen further than we must.
    ///   (a) exact;
    ///   (b) whitespace-trimmed — THE "Sap " CASE: Library.xml keeps the trailing space the
    ///       user typed, MusicKit reports the name trimmed, and exact match found nothing;
    ///   (c) trimmed + case- and diacritic-insensitive, for the rest of the drift.
    static func candidates(named name: String,
                           in playlists: [MusicKit.Playlist]) -> [MusicKit.Playlist] {
        let exact = playlists.filter { $0.name == name }
        if !exact.isEmpty { return exact }

        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = playlists.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == target
        }
        if !trimmed.isEmpty { return trimmed }

        let folded = target.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return playlists.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == folded
        }
    }

    // MARK: Write

    func addSong(appleMusicId: String, toPlaylistId playlistId: String) async throws {
        guard canWrite else { throw PlaylistWriteBackError.notAuthorized }

        // Resolve the id back into a Playlist OBJECT — `MusicLibrary.add(_:to:)` takes the
        // item, not the id. An empty result means the playlist was deleted (or MusicKit
        // re-minted its id): distinct from a write failure, so the queue can re-resolve.
        var listReq = MusicLibraryRequest<MusicKit.Playlist>()
        listReq.filter(matching: \.id, equalTo: MusicItemID(playlistId))
        listReq.limit = 1
        guard let playlist = try await listReq.response().items.first else {
            throw PlaylistWriteBackError.playlistGone(playlistId)
        }

        var songReq = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id,
                                                                 equalTo: MusicItemID(appleMusicId))
        songReq.limit = 1
        guard let song = try await songReq.response().items.first else {
            throw PlaylistWriteBackError.songNotFound(appleMusicId)
        }

        _ = try await MusicLibrary.shared.add(song, to: playlist)
    }
}
#endif
