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
        /// We searched Apple Music and found no confident catalog match for this song, so it
        /// can never be added to a catalog playlist — a ripped/imported track that simply isn't
        /// in the Apple Music catalog. TERMINAL and NOT retryable (unlike `.failed`, which is a
        /// transient network/auth exhaustion): re-searching won't conjure a match. Drives the
        /// "not backed up" (`xmark.icloud`) badge in linked collections. Distinct from
        /// `.notApplicable` (the whole PLATFORM can't write) — here the platform can, this one
        /// SONG can't be resolved.
        case unresolvable
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
        /// Song IDENTITY, carried so the transport can resolve a catalog id ON-DEVICE when
        /// `appleMusicId` is empty (our server indexer never matched this "Apple Music (Local)"
        /// song, but the user's own catalog can). Additive-optional like every field below —
        /// an older document has no such keys and still decodes. Empty title+artist ⇒ nothing
        /// to resolve with (enqueue rejects that case up front).
        var title: String
        var artist: String
        var album: String?
        var durationMs: Int?
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
        /// obvious (several library playlists share the name). Surfaced in Settings ▸ Apple Music
        /// so a guess is visible rather than silent — the failure mode this whole change is
        /// about is a wrong-or-missing playlist join that nobody could see.
        var resolutionNote: String?

        enum CodingKeys: String, CodingKey {
            case id, indexPlaylistId, playlistName, songId, appleMusicId,
                 title, artist, album, durationMs,
                 queuedAtMs, attempts, lastError, state, nextAttemptAtMs, settledAtMs,
                 musicKitPlaylistId, resolutionNote
        }

        init(id: String, indexPlaylistId: String, playlistName: String, songId: String,
             appleMusicId: String, title: String = "", artist: String = "",
             album: String? = nil, durationMs: Int? = nil,
             queuedAtMs: Double, attempts: Int = 0, lastError: String? = nil,
             state: JobState = .queued, nextAttemptAtMs: Double? = nil, settledAtMs: Double? = nil,
             musicKitPlaylistId: String? = nil, resolutionNote: String? = nil) {
            self.id = id; self.indexPlaylistId = indexPlaylistId; self.playlistName = playlistName
            self.songId = songId; self.appleMusicId = appleMusicId
            self.title = title; self.artist = artist; self.album = album; self.durationMs = durationMs
            self.queuedAtMs = queuedAtMs
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
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            artist = (try? c.decode(String.self, forKey: .artist)) ?? ""
            album = try? c.decode(String.self, forKey: .album)
            durationMs = try? c.decode(Int.self, forKey: .durationMs)
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
    /// BOTH Apple Music sources qualify (the parity review's biggest catch): the private
    /// catalog's "Apple Music (Local)" AND the public on-device "Apple Music" library index —
    /// the write-back transport is on-device MusicKit either way, so a public user's mirror
    /// playlists are exactly as writable as the private catalog's.
    nonisolated static func isAppleMusicSource(_ sourceName: String) -> Bool {
        sourceName == Config.appleMusicSourceName || sourceName == AppleMusicLibraryStore.sourceName
    }

    // MARK: - Enqueue

    /// Record an owed write. Returns nil (queues NOTHING) when there is no way to write the
    /// song upstream — NEITHER a catalog `appleMusicId` NOR enough identity (title + artist) to
    /// resolve one on-device. A vinyl / My Digital / Studio song with no title+artist is purely
    /// a local add; there is no such thing as adding it to an Apple Music playlist. A song with
    /// only identity (no `appleMusicId` — our indexer never matched it) IS enqueued: the
    /// transport resolves the catalog id on-device at delivery (see `resolveCatalogId`), and if
    /// Apple Music has no confident match the job settles `.unresolvable`. Also nil when an
    /// equivalent job is already queued or delivered, so a double-tap can't add it twice.
    @discardableResult
    func enqueue(indexPlaylistId: String, playlistName: String,
                 songId: String, appleMusicId: String?,
                 title: String = "", artist: String = "",
                 album: String? = nil, durationMs: Int? = nil) -> Job? {
        let amId = (appleMusicId ?? "").trimmingCharacters(in: .whitespaces)
        let t = title.trimmingCharacters(in: .whitespaces)
        let ar = artist.trimmingCharacters(in: .whitespaces)
        guard !playlistName.isEmpty else { return nil }
        // Need SOMETHING to write with: a known catalog id, or enough identity to resolve one.
        guard !amId.isEmpty || (!t.isEmpty && !ar.isEmpty) else { return nil }
        // A prior TERMINAL `.unresolvable` verdict for this (playlist, song): re-searching the
        // catalog can't conjure a match, so an identity-only re-enqueue (still no store id) is a
        // no-op — this is what keeps a repeated "Send to Apple Music" backfill from re-queueing and
        // re-searching un-matchable songs forever (and the persisted queue from growing unbounded).
        // BUT if we NOW carry a real catalog id (the nightly crawl resolved it since), supersede:
        // drop the stale verdict so the song can finally deliver and its "not backed up" badge clears.
        if let stale = jobs.firstIndex(where: {
            $0.indexPlaylistId == indexPlaylistId && $0.songId == songId && $0.state == .unresolvable
        }) {
            if amId.isEmpty { return nil }
            jobs.remove(at: stale)
        }
        guard !jobs.contains(where: {
            $0.indexPlaylistId == indexPlaylistId && $0.songId == songId
                && ($0.state == .queued || $0.state == .delivered)
        }) else { return nil }

        // Seed the job with the playlist's already-known MusicKit id when we have one: the
        // second song added to a playlist should never pay for the all-playlists fetch again.
        let job = Job(id: "wbj_" + UUID().uuidString, indexPlaylistId: indexPlaylistId,
                      playlistName: playlistName, songId: songId, appleMusicId: amId,
                      title: t, artist: ar, album: album, durationMs: durationMs,
                      queuedAtMs: Self.nowMs,
                      musicKitPlaylistId: resolvedPlaylistIds[indexPlaylistId])
        jobs.append(job)
        prune()
        save()
        return job
    }

    /// One song owed to one playlist — `enqueue`'s parameters as data, for the batch path.
    struct EnqueueItem: Sendable {
        var indexPlaylistId: String
        var playlistName: String
        var songId: String
        var appleMusicId: String?
        var title: String
        var artist: String
        var album: String?
        var durationMs: Int?
    }

    /// Batch twin of `enqueue` — the multi-select / drag-&-drop / paste add path. Identical
    /// per-item eligibility + dedup semantics, but the queued/delivered and unresolvable
    /// lookups run against Sets built ONCE, and `prune()` + `save()` run ONCE at the end —
    /// a confirmed select-all-sized batch stays O(n), not O(n²) scans + n full-document
    /// rewrites. The caller fires ONE `runSoon()` after. Returns the newly queued count.
    @discardableResult
    func enqueueMany(_ items: [EnqueueItem]) -> Int {
        guard !items.isEmpty else { return 0 }
        var live = Set<String>()                    // queued/delivered → skip
        var unresolvableJobIds: [String: String] = [:]  // key → job id (supersede candidates)
        for j in jobs {
            let key = j.indexPlaylistId + "\u{1}" + j.songId
            switch j.state {
            case .queued, .delivered: live.insert(key)
            case .unresolvable: unresolvableJobIds[key] = j.id
            default: break
            }
        }
        var newJobs: [Job] = []
        var dropIds = Set<String>()
        for item in items {
            let amId = (item.appleMusicId ?? "").trimmingCharacters(in: .whitespaces)
            let t = item.title.trimmingCharacters(in: .whitespaces)
            let ar = item.artist.trimmingCharacters(in: .whitespaces)
            guard !item.playlistName.isEmpty else { continue }
            guard !amId.isEmpty || (!t.isEmpty && !ar.isEmpty) else { continue }
            let key = item.indexPlaylistId + "\u{1}" + item.songId
            guard !live.contains(key) else { continue }          // also dedups within the batch
            if let stale = unresolvableJobIds[key] {             // same supersede rule as enqueue
                if amId.isEmpty { continue }
                dropIds.insert(stale)
                unresolvableJobIds[key] = nil
            }
            live.insert(key)
            newJobs.append(Job(id: "wbj_" + UUID().uuidString, indexPlaylistId: item.indexPlaylistId,
                               playlistName: item.playlistName, songId: item.songId, appleMusicId: amId,
                               title: t, artist: ar, album: item.album, durationMs: item.durationMs,
                               queuedAtMs: Self.nowMs,
                               musicKitPlaylistId: resolvedPlaylistIds[item.indexPlaylistId]))
        }
        guard !newJobs.isEmpty || !dropIds.isEmpty else { return 0 }
        if !dropIds.isEmpty { jobs.removeAll { dropIds.contains($0.id) } }
        jobs.append(contentsOf: newJobs)
        prune()
        save()
        return newJobs.count
    }

    /// A song the queue has DETERMINED can't be backed up to Apple Music — searched and found no
    /// confident catalog match (`.unresolvable`). Keyed by songId (unresolvability is a property
    /// of the song, not the playlist). Drives the collection row's `xmark.icloud` badge.
    ///
    /// SUPERSEDED by a later success: if ANY job for the same song is `.delivered` (it's upstream
    /// now — e.g. the nightly crawl gave it a store id and it delivered to another linked list) or
    /// `.queued` (a fresh attempt is in flight), the old verdict no longer holds and the badge
    /// clears. Without this the badge could linger forever on a song that IS now backed up.
    func isUnsyncable(_ songId: String) -> Bool {
        let mine = jobs.filter { $0.songId == songId }
        guard mine.contains(where: { $0.state == .unresolvable }) else { return false }
        return !mine.contains { $0.state == .delivered || $0.state == .queued }
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
            // The catalog id to write: the job's own (indexer-resolved), or — when our indexer
            // never matched this "Apple Music (Local)" song — one resolved ON-DEVICE from the
            // carried identity. A THROW here (network/auth) is transient → the generic catch
            // below backs off and retries. A nil RESULT means Apple Music was searched and has
            // no confident match: TERMINAL `.unresolvable` (re-searching won't help), NOT a
            // retryable failure — so it doesn't burn `maxAttempts` or set the drain's lastError.
            let catalogId: String
            if !job.appleMusicId.isEmpty {
                catalogId = job.appleMusicId
            } else {
                let identity = WriteBackSong(appleMusicId: "", title: job.title, artist: job.artist,
                                             album: job.album, durationMs: job.durationMs)
                if let resolved = try await transport.resolveCatalogId(for: identity), !resolved.isEmpty {
                    catalogId = resolved
                    // PERSIST the resolved id — with a durable save() — BEFORE the non-retractable
                    // `MusicLibrary.add`. If iOS jettisons the process after the add but before the
                    // delivered-state save (the "ordinary, not exotic" window above), the next
                    // launch re-attempts with THIS same id; the delivery-time idempotency pre-check
                    // then sees it already in the playlist and skips — no duplicate. Without this,
                    // the re-attempt would re-resolve and could land a DIFFERENT-but-valid id,
                    // adding the song twice. (`WriteBackMatcher` is deterministic, so a re-resolve
                    // would normally match, but persisting closes the window unconditionally.)
                    update(jobId) { $0.appleMusicId = resolved }
                    save()
                } else {
                    update(jobId) {
                        $0.attempts += 1
                        $0.state = .unresolvable
                        $0.nextAttemptAtMs = nil
                        $0.settledAtMs = Self.nowMs
                        $0.lastError = "This song isn’t on Apple Music, so it can’t be added to the playlist — it stays in your local copy."
                    }
                    return true
                }
            }
            let target = try await playlistId(for: job, transport: transport)
            do {
                try await transport.addSong(appleMusicId: catalogId, toPlaylistId: target)
            } catch PlaylistWriteBackError.playlistGone {
                forgetResolution(for: job.indexPlaylistId)
                let fresh = try await playlistId(for: job, transport: transport, forceResolve: true)
                try await transport.addSong(appleMusicId: catalogId, toPlaylistId: fresh)
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

    /// Drop still-UNDELIVERED write-backs (`.queued` / `.failed`) for `songIds` owed to
    /// `indexPlaylistId`. Used when a pocket is RE-LINKED to a different source: a song added while
    /// the pocket was mis-linked (offline / not-yet-authorized, so the job never drained) must not
    /// still deliver to the OLD, wrong playlist once connectivity returns. Scoped to the pocket's
    /// own songs so another collection's legitimate pending write to the same source is untouched.
    /// `.delivered` jobs are already upstream and irretrievable — left alone.
    func cancelPending(indexPlaylistId: String, songIds: Set<String>) {
        let before = jobs.count
        jobs.removeAll {
            $0.indexPlaylistId == indexPlaylistId && songIds.contains($0.songId)
                && ($0.state == .queued || $0.state == .failed)
        }
        if jobs.count != before { save() }
    }

    /// Empty the whole outbound queue and delete its backing document — a full wipe.
    ///
    /// DEVICE-LOCAL and irreversible: this log is never cloud-synced (see the type doc), so
    /// there is no other copy to restore from. Any still-`.queued` write is abandoned; the
    /// local duplicate add it recorded stands, and the safety property holds (a dropped
    /// write-back only ever leaves a song local, never removes one). Resets the @Observable
    /// state in-memory so Settings ▸ Apple Music empties immediately, then removes the file the same
    /// forgiving way `launchURL()` does — `try?` swallows a not-yet-written document.
    func clear() {
        jobs = []
        resolvedPlaylistIds = [:]
        lastError = nil
        resolutionWarning = nil
        try? FileManager.default.removeItem(at: fileURL)
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
            .filter { $0.state == .delivered || $0.state == .notApplicable || $0.state == .unresolvable }
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
        // MusicKit path: full capability, including remove/reorder via MusicLibrary.edit.
        if #available(iOS 16.0, visionOS 1.0, *) { return MusicKitPlaylistWriteBackTransport() }
        return nil
        #elseif canImport(MusicKit)
        // macOS / Catalyst: MusicLibrary's write methods are @available(macOS, unavailable), but the
        // WEB API has no such restriction and MusicDataRequest works here. So the Mac now delivers
        // adds ON DEVICE too, instead of waiting up to a day for the server sync's push — and it
        // resolves a catalog id itself, covering songs the indexer never resolved one for (which
        // the server push silently drops). Append-only: `reconcile` reports `.unsupported`.
        if #available(macOS 14.0, *) { return WebAPIPlaylistWriteBackTransport(sender: MusicDataRequestSender()) }
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
/// A song's IDENTITY handed to the transport so it can resolve a catalog id ON-DEVICE when the
/// indexer never minted one. `appleMusicId` is the known catalog id ("" when unknown — the case
/// that drives resolution); title/artist are the match keys; album + duration disambiguate.
struct WriteBackSong: Sendable, Equatable {
    var appleMusicId: String
    var title: String
    var artist: String
    var album: String?
    var durationMs: Int?
}

/// One Apple Music catalog search result, projected free of MusicKit so the matching decision is
/// pure and unit-testable (the MusicKit transport maps `MusicKit.Song` into this).
struct WriteBackCatalogCandidate: Sendable, Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String?
    var durationSec: Double?
}

/// The on-device catalog-match DECISION, factored out of the MusicKit transport so its (subtle,
/// wrong-add-dangerous) rules are testable with no account. CONSERVATIVE on purpose: adding the
/// WRONG song to the user's real Apple Music playlist is worse than not adding at all, so an
/// unconfident or ambiguous result returns nil (→ the job settles `.unresolvable`). DETERMINISTIC
/// on purpose: two independent runs over the same candidates pick the SAME id (stable min-id
/// tie-break), so a re-resolve after a crash / on a peer device can't diverge into a duplicate add.
enum WriteBackMatcher {
    /// Normalize a title/artist/album for matching: fold case + diacritics, then keep only letters
    /// and digits. `keepVersion: false` ALSO drops any parenthetical/bracketed span ("(feat. …)",
    /// "[Remastered]", "(Taylor's Version)") — the LOOSE base-title key that survives metadata
    /// drift. `keepVersion: true` preserves those characters — the STRICT key that tells
    /// version/part siblings apart so we never substitute one recording for another.
    static func matchKey(_ s: String, keepVersion: Bool) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if !keepVersion {
            while let open = t.firstIndex(where: { $0 == "(" || $0 == "[" }) {
                let close: Character = t[open] == "(" ? ")" : "]"
                if let end = t[open...].firstIndex(of: close) {
                    t.removeSubrange(open...end)
                } else {
                    t.removeSubrange(open...); break   // unbalanced — drop the tail
                }
            }
        }
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Best catalog id to write for `song`, or nil when nothing is confident / the top score is
    /// ambiguous across DISTINCT artists. See the type doc for the two invariants.
    static func bestMatch(for song: WriteBackSong,
                          among candidates: [WriteBackCatalogCandidate]) -> String? {
        let wantBase = matchKey(song.title, keepVersion: false)
        let wantFull = matchKey(song.title, keepVersion: true)
        let wantArtist = matchKey(song.artist, keepVersion: true)
        guard !wantBase.isEmpty, !wantArtist.isEmpty else { return nil }
        let userHasMarker = wantFull != wantBase   // user's title carries a version/part tag

        struct Scored { let id: String; let artist: String; let score: Int }
        var scored: [Scored] = []
        for c in candidates {
            let cBase = matchKey(c.title, keepVersion: false)
            guard cBase == wantBase else { continue }
            let cFull = matchKey(c.title, keepVersion: true)
            let titleFullMatch = cFull == wantFull
            // The user asked for a version/part-marked title → only the SAME full-title identity
            // qualifies; never fall back to the base master (the "(Taylor's Version)" trap).
            if userHasMarker && !titleFullMatch { continue }
            // The CANDIDATE carries a marker the user's plain title didn't ask for (a live/remix/
            // edit variant) → it needs hard proof (duration/album), not just a matching artist.
            let candidateIsUnwantedVariant = (cFull != cBase) && !userHasMarker

            let cArtist = matchKey(c.artist, keepVersion: true)
            let artistExact = cArtist == wantArtist
            guard artistExact || cArtist.contains(wantArtist) || wantArtist.contains(cArtist) else { continue }

            var score = 0
            var durationCorroborated = false
            if let want = song.durationMs {
                if let got = c.durationSec {
                    let diffSec = abs(got - Double(want) / 1000)
                    if diffSec <= 4 { score += 3; durationCorroborated = true }
                    else if diffSec <= 12 { score += 1; durationCorroborated = true }
                    else { continue }   // >12 s apart — a different recording, reject outright
                }
                // else: we know our length but the catalog doesn't expose one — no signal.
            }
            let albumMatch: Bool = {
                guard let al = song.album, !al.isEmpty else { return false }
                return matchKey(c.album ?? "", keepVersion: false) == matchKey(al, keepVersion: false)
            }()
            if albumMatch { score += 2 }
            if artistExact { score += 2 }
            if titleFullMatch && userHasMarker { score += 2 }

            // CONFIDENCE FLOOR: a bare title match is never enough to write to the user's REAL
            // playlist. Require corroboration — and for a candidate that's an UNWANTED variant,
            // only duration/album count (a matching artist alone can't tell live from studio).
            let strong = durationCorroborated || albumMatch
            let corroborated = candidateIsUnwantedVariant
                ? strong
                : (artistExact || strong || (titleFullMatch && userHasMarker))
            guard corroborated else { continue }

            scored.append(Scored(id: c.id, artist: cArtist, score: score))
        }
        guard let topScore = scored.map(\.score).max() else { return nil }
        let top = scored.filter { $0.score == topScore }
        // Ambiguous across DIFFERENT artists at the top score → refuse to guess.
        if Set(top.map(\.artist)).count > 1 { return nil }
        // Deterministic pick among same-artist editions — stable across independent resolutions.
        return top.map(\.id).min()
    }
}

@MainActor
/// Outcome of reconciling an app-created Apple Music playlist to an exact ordered track list
/// (the destructive remove+reorder half of the hybrid sync).
enum PlaylistReconcileResult: Equatable {
    /// Replaced the playlist's contents with `count` ordered tracks; `added`/`removed` are the
    /// net membership delta vs. what was live before the edit (reorders alone are 0/0) — the
    /// audit-trail numbers the sync UI reports.
    case edited(count: Int, added: Int, removed: Int)
    case alreadyInSync    // live contents already equal the target — no destructive edit performed
    case notEditable      // the playlist isn't app-created (user-authored) — never replace-all
    case skippedEmpty     // empty target — refuse to wipe the playlist
    case unsupported      // platform without MusicKit library editing (macOS/Catalyst)
}

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
    /// Resolve a song with NO known catalog id to one ON-DEVICE (our indexer missed it, but the
    /// user's own Apple Music catalog can match it). Returns the catalog store id on a confident
    /// match, or nil when Apple Music has none — the queue reads nil as `.unresolvable`. THROWS
    /// only on a transient failure (network/auth) the queue should retry. Defaulted to nil so a
    /// stub that only cares about the catalog-id path never has to implement it.
    func resolveCatalogId(for song: WriteBackSong) async throws -> String?
    /// Set by `resolvePlaylistId` when the answer was a GUESS (duplicate names, no track
    /// overlap to arbitrate). Defaulted so a stub never has to care.
    var lastResolutionNote: String? { get }
    /// Reconcile an EXISTING app-created library playlist to `orderedAppleMusicIds` — replace its
    /// contents with exactly that ordered catalog-id list (the remove-missing + reorder half of the
    /// hybrid sync the append-only Web API can't do). See `PlaylistReconcileResult`. Defaulted to
    /// `.unsupported` so non-MusicKit platforms + stubs need not implement it.
    func reconcile(playlistId: String, orderedAppleMusicIds: [String]) async throws -> PlaylistReconcileResult
}

extension PlaylistWriteBackTransport {
    var lastResolutionNote: String? { nil }
    func resolveCatalogId(for song: WriteBackSong) async throws -> String? { nil }
    func reconcile(playlistId: String, orderedAppleMusicIds: [String]) async throws -> PlaylistReconcileResult { .unsupported }
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

        // IDEMPOTENT DELIVERY. `MusicLibrary.add` is NOT idempotent — adding a song already in the
        // playlist appends a SECOND copy the user must remove by hand. The queue's (id,song) dedup
        // and the collections' source snapshot both guard the enqueue, but neither is watertight
        // across the whole system: the queue is device-local (a PEER device, or a same-device job
        // pruned past the 200-cap, has no record of a prior delivery) and the snapshot only advances
        // on a catalog re-index, lagging delivery. The BACKFILL re-drives adds from the cloud-synced
        // activity log, so it can present exactly such an already-delivered song. This check closes
        // that at the mutation point: if the song is already in the real playlist, treat the write
        // as done. SAFE by construction — catalog ids are unique, so a match is never a false
        // positive; a miss (best-effort id extraction) merely falls through to the add, i.e. the
        // pre-existing behaviour. See `catalogIds(of:)`.
        if let tracks = (try? await playlist.with([.tracks]))?.tracks,
           tracks.contains(where: { Self.catalogIds(of: $0).contains(appleMusicId) }) {
            return
        }

        var songReq = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id,
                                                                 equalTo: MusicItemID(appleMusicId))
        songReq.limit = 1
        guard let song = try await songReq.response().items.first else {
            throw PlaylistWriteBackError.songNotFound(appleMusicId)
        }

        _ = try await MusicLibrary.shared.add(song, to: playlist)
    }

    // MARK: Resolve a missing catalog id ON-DEVICE

    /// Our server indexer resolves `appleMusicId` from the public iTunes Search API and misses a
    /// chunk of "Apple Music (Local)" songs (obscure/underground catalog, metadata drift). But if
    /// the song is genuinely on Apple Music, the user's OWN catalog search finds it on-device.
    /// This searches by "title artist" and hands the results to `WriteBackMatcher.bestMatch`, which
    /// applies the conservative + deterministic match rules (see its doc). No confident match ⇒ nil
    /// ⇒ the job settles `.unresolvable` (the "not backed up" badge), never a wrong add.
    func resolveCatalogId(for song: WriteBackSong) async throws -> String? {
        guard canWrite else { throw PlaylistWriteBackError.notAuthorized }
        let term = "\(song.title) \(song.artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        var req = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
        req.limit = 25
        let candidates = try await req.response().songs.map {
            WriteBackCatalogCandidate(id: $0.id.rawValue, title: $0.title, artist: $0.artistName,
                                      album: $0.albumTitle, durationSec: $0.duration)
        }
        return WriteBackMatcher.bestMatch(for: song, among: candidates)
    }

    // MARK: Reconcile (the destructive remove + reorder half of the hybrid)

    /// Replace an app-created library playlist's contents with EXACTLY `orderedAppleMusicIds`, in
    /// order — the half the Apple Music Web API can't do (it's append-only). Guards, in order:
    ///  1. never edit toward an EMPTY list (a replace-all with [] wipes the playlist);
    ///  2. only edit a playlist THIS APP can edit (`isEditable`) — never a user-authored Music.app
    ///     playlist (both a MusicKit permission fact and the core data-safety rule);
    ///  3. resolve EVERY id to a `Song` FIRST — a partial resolve must NOT edit, or it truncates the
    ///     playlist to only the resolvable songs; abort instead;
    ///  4. idempotent — if the live ordered catalog ids already equal the target, skip the edit.
    /// DEVICE-ONLY (needs authorization + a subscription); untestable on the Simulator.
    func reconcile(playlistId: String, orderedAppleMusicIds ids: [String]) async throws -> PlaylistReconcileResult {
        guard canWrite else { throw PlaylistWriteBackError.notAuthorized }
        guard !ids.isEmpty else { return .skippedEmpty }

        var listReq = MusicLibraryRequest<MusicKit.Playlist>()
        listReq.filter(matching: \.id, equalTo: MusicItemID(playlistId))
        listReq.limit = 1
        guard let playlist = try await listReq.response().items.first else {
            throw PlaylistWriteBackError.playlistGone(playlistId)
        }

        // Fetch the live contents FIRST — and make the fetch LOAD-BEARING (a plain `try`, not
        // `try?`): a transient failure here must skip this playlist for the pass (the caller's
        // `try?` absorbs the throw; reconcile re-runs next sync), never fall through to a blind
        // replace-all reported as "+everything". The in-sync no-op check also runs before the
        // per-song catalog resolution below (a 1,000-song playlist would otherwise pay 1,000
        // lookups just to learn nothing changed). A live track may carry several catalog ids, so
        // membership checks the full id set.
        let tracks = try await playlist.with([.tracks]).tracks.map(Array.init) ?? []
        let liveIdSets = tracks.map { Set(Self.catalogIds(of: $0)) }
        if tracks.count == ids.count {
            let live = tracks.map { Self.catalogIds(of: $0).first(where: ids.contains) ?? "" }
            if live == ids { return .alreadyInSync }
        }
        let added = ids.filter { id in !liveIdSets.contains(where: { $0.contains(id) }) }.count
        let removed = liveIdSets.filter { set in !ids.contains(where: { set.contains($0) }) }.count
        // Resolve every id BEFORE editing — abort on any miss so we never truncate.
        var songs: [MusicKit.Song] = []
        songs.reserveCapacity(ids.count)
        for id in ids {
            var songReq = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: MusicItemID(id))
            songReq.limit = 1
            guard let song = try await songReq.response().items.first else {
                throw PlaylistWriteBackError.songNotFound(id)
            }
            songs.append(song)
        }
        // MusicKit has no pre-check for "did this app create this playlist" — a replace-all `edit`
        // succeeds ONLY on playlists the app owns and THROWS on a user-authored / foreign one. So we
        // FAIL CLOSED: attempt the edit and, on any failure, leave the playlist untouched and report
        // `.notEditable`. (DEVICE-VERIFY which playlists qualify — Web-API-created ones may or may
        // not be MusicKit-editable; if not, only on-device-created playlists reconcile, which is the
        // safe outcome, never a clobbered user playlist.)
        do {
            _ = try await MusicLibrary.shared.edit(playlist, items: songs)
            return .edited(count: songs.count, added: added, removed: removed)
        } catch {
            return .notEditable
        }
    }
}
#endif
