import Foundation
import Observation
import CryptoKit

/// The cloud RECOMMENDATION ENGINE orchestrator (WS-E): while — and ONLY while — the Settings
/// toggle "Use PocketDJ Recommendation Engine" is ON (default OFF), it batch-uploads deltas
/// derived from the EXISTING stores (play history / favorites / collection activity /
/// collections membership — no new recording hooks) to `Config.recEngineBase`, and serves the
/// two suggestion surfaces: the History ▸ For You tab and the Suggested-collections rows on
/// SongDetail + the Add-to-Collection sheet.
///
/// PRIVACY GATE: every network-touching method guards `isEnabled` first. There is no other
/// call site that can reach `RecEngineClient`, so toggle-off means literally zero calls.
///
/// TWO documents, deliberately different sync scopes:
///  • `pocketdj-rec-key.json` — the per-profile random bearer key, CloudSync-registered
///    ("rec-key") so every device of the same Apple ID presents the SAME key and the server's
///    trust-on-first-use binding holds across them. Minted lazily on the first flush while
///    enabled. NOTE: two devices enabling near-simultaneously can race the CloudKit LWW — the
///    loser's early uploads 403 until its key-doc pull lands (`reloadKeyFromDisk`), then
///    self-heal on the next flush.
///  • `pocketdj-rec-sync.json` — per-device upload cursors, NOT CloudSync-registered on
///    purpose: the server dedupes by event id, so two devices uploading overlapping unions is
///    harmless, while shared cursors would let one device's advance starve the other's upload.
///
/// ── Why the cursors are a WINDOW, not a high-water mark ─────────────────────────────────────
/// The three source stores are CloudKit-synced with UNION merges that insert a PEER's events
/// carrying their ORIGINAL, older timestamps (`PlayHistoryStore.reloadFromDisk` and friends).
/// The engine toggle lives in `SettingsStore` (UserDefaults, device-local by design), so
/// "ON on the phone, OFF on the Mac" is the NORMAL configuration — the Mac uploads nothing and
/// its plays arrive here below this device's high-water mark. A strict `atMs > cursor` filter
/// therefore skipped them FOREVER, silently: the server's history permanently missed every
/// play made on the other device.
///
/// So each stream selects `atMs >= cursor - overlapWindow` (30 days) MINUS the ids this device
/// has already had acknowledged (`SyncState.uploaded*`, pruned by the same floor). Re-sends are
/// harmless — the server dedupes plays/activity/puzzle by event id and merges favorites LWW —
/// and the ack list is what keeps a quiet flush at zero requests instead of re-uploading the
/// whole window every 10 minutes. It also fixes the exact-millisecond straddle at a batch
/// boundary that the strict `>` could strand.
///
/// ── Why the rec server sees a DERIVED profile id, not the broadcast one ─────────────────────
/// `PDJIdentityHeaders` stamps the raw profile id onto every authenticated PocketDJ call —
/// including calls to USER-CONFIGURED third-party endpoints (a friend's jukebox broker, a
/// shared rip server), which is exactly what the header is for. But the rec engine keys its
/// state object AND its `DELETE /state` route by that same header, so any hostile host the
/// user ever pointed the app at learned enough to target this profile's rec data for deletion
/// or a rebind race (the enrollment secret it also needs ships in every .ipa — extractable).
/// The rec engine therefore gets its OWN id: `HMAC-SHA256(profileId, key: bearerKey)` —
/// computable only with the bearer key, which never leaves this app's CloudKit-private key
/// doc. Same-Apple-ID devices share both inputs, so they still converge on one server-side
/// state object. Profiles enrolled by older builds under the RAW id are migrated by a
/// one-time `DELETE` of the old object on the first flush (`migrateOffBroadcastProfileId`),
/// which also RESETS the cursors so this device's whole local window re-uploads under the
/// scoped id on that same flush — the scoped id addresses an empty object, and without the
/// reset the acks would suppress exactly the history the deleted object used to hold.
@MainActor
@Observable
final class RecommendationService {

    // MARK: - View models

    struct SongSuggestion: Identifiable, Equatable {
        var songId: String
        var name: String
        var artist: String
        var reasons: [String]
        var id: String { songId }
    }

    struct CollectionSuggestion: Identifiable, Equatable {
        var id: String
        var kind: String
        var name: String
        var reasons: [String]
    }

    // MARK: - Observable state

    private(set) var forYou: [SongSuggestion] = []
    private(set) var forYouFetchedAtMs: Double?
    private(set) var isLoadingForYou = false
    private(set) var lastSyncedAtMs: Double?
    private(set) var syncError: String?

    // MARK: - Persisted documents

    /// The CloudKit-synced key doc (lenient decode — the settings-blob doctrine).
    private struct KeyDoc: Codable {
        var schemaVersion: Int?
        var key: String?
    }

    /// Device-local upload cursors. All fields default (0 / nil) so an older/partial doc
    /// decodes degraded, never resets.
    struct SyncState: Codable {
        var schemaVersion = 1
        var lastPlayAtMs: Double = 0
        var lastFavoriteAtMs: Double = 0
        var lastActivityAtMs: Double = 0
        var lastPuzzleAtMs: Double = 0
        var lastCollectionsHash: String?
        /// Hash of the last UPLOADED lifetime play-count snapshot. Gates re-sending a 20k-row map
        /// on every flush when nothing about it changed. ADDITIVE-OPTIONAL: an older doc decodes
        /// to nil, which costs exactly one re-upload.
        var lastPlayCountsHash: String?
        var lastSyncedAtMs: Double?
        /// Acknowledged uploads inside the trailing overlap window, one `"<atMs>|<id>"` entry
        /// each (see the type doc). ADDITIVE-OPTIONAL: an older doc decodes to empty, which
        /// only costs one idempotent re-send of the window.
        var uploadedPlays: [String] = []
        var uploadedFavorites: [String] = []
        var uploadedActivity: [String] = []
        var uploadedPuzzle: [String] = []
        /// Has this device finished the one-time move off the broadcast profile id (see the
        /// type doc)? ADDITIVE-OPTIONAL: a pre-scoped-id doc decodes to false, which is
        /// exactly what schedules its migration.
        var didMigrateScopedProfile: Bool = false

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, lastPlayAtMs, lastFavoriteAtMs, lastActivityAtMs,
                 lastPuzzleAtMs, lastCollectionsHash, lastPlayCountsHash, lastSyncedAtMs,
                 uploadedPlays, uploadedFavorites, uploadedActivity, uploadedPuzzle,
                 didMigrateScopedProfile
        }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
            lastPlayAtMs = (try? c.decode(Double.self, forKey: .lastPlayAtMs)) ?? 0
            lastFavoriteAtMs = (try? c.decode(Double.self, forKey: .lastFavoriteAtMs)) ?? 0
            lastActivityAtMs = (try? c.decode(Double.self, forKey: .lastActivityAtMs)) ?? 0
            lastPuzzleAtMs = (try? c.decode(Double.self, forKey: .lastPuzzleAtMs)) ?? 0
            lastCollectionsHash = try? c.decode(String.self, forKey: .lastCollectionsHash)
            lastPlayCountsHash = try? c.decode(String.self, forKey: .lastPlayCountsHash)
            lastSyncedAtMs = try? c.decode(Double.self, forKey: .lastSyncedAtMs)
            uploadedPlays = (try? c.decode([String].self, forKey: .uploadedPlays)) ?? []
            uploadedFavorites = (try? c.decode([String].self, forKey: .uploadedFavorites)) ?? []
            uploadedActivity = (try? c.decode([String].self, forKey: .uploadedActivity)) ?? []
            uploadedPuzzle = (try? c.decode([String].self, forKey: .uploadedPuzzle)) ?? []
            didMigrateScopedProfile = (try? c.decode(Bool.self, forKey: .didMigrateScopedProfile)) ?? false
        }
    }

    /// The account-deletion tombstone: the server-side DELETE that failed (offline / 503) so a
    /// later launch can finish the erasure the user asked for. Deliberately NOT CloudSynced
    /// (only "rec-key" is registered with CloudSyncService — see PocketDJApp) — it carries the
    /// bearer key, which after `clearLocal(cloudDeleted: false)` lives NOWHERE else: the key
    /// file itself is removed so a re-enable mints a FRESH identity instead of resurrecting
    /// the one whose data the user just asked to erase.
    private struct PendingDeleteDoc: Codable {
        var schemaVersion: Int?
        var key: String?
        var profileId: String?
        var requestedAtMs: Double?
        /// Failed retries so far (transient failures only — a 403 is terminal immediately).
        /// Optional so a doc written by an older build decodes; it just starts counting late.
        var attempts: Int?
        /// The RAW (broadcast) profile id, carried only while the scoped-id migration had not
        /// finished at deletion time: the old server object may still exist under it, and the
        /// user asked for that gone too.
        var legacyProfileId: String?
    }

    // MARK: - Dependencies

    @ObservationIgnored private let client: RecEngineClient
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let history: PlayHistoryStore
    @ObservationIgnored private let favorites: FavoritesStore
    @ObservationIgnored private let activity: CollectionActivityStore
    @ObservationIgnored private let collections: CollectionsStore
    @ObservationIgnored private let profileIdProvider: () -> String

    /// WS-D (Games tab / Collector's Puzzle) seam: events since a cursor. Ships nil; the Games
    /// workstream wires it in PocketDJApp when its store lands — this file must never reference
    /// a WS-D type beyond the wire struct.
    @ObservationIgnored var puzzleEventsProvider: ((_ sinceMs: Double) -> [RecPuzzleEventWire])?

    /// LIFETIME play counts (`PlayCountService.snapshot()`) — Apple's imported baseline plus this
    /// app's own plays. A closure seam like `puzzleEventsProvider`, so this service keeps its
    /// narrow store list and a test can declare the map outright. Nil ⇒ nothing is uploaded and
    /// the server's ranking is byte-identical to what it was before the signal existed.
    @ObservationIgnored var playCountsProvider: (() -> [String: Int])?

    @ObservationIgnored private let keyFileURL: URL
    @ObservationIgnored private let stateFileURL: URL
    /// Sibling of the key doc — `…-rec-pending-delete.json` next to it.
    @ObservationIgnored private var pendingDeleteFileURL: URL {
        keyFileURL.deletingLastPathComponent()
            .appendingPathComponent(keyFileURL.deletingPathExtension().lastPathComponent
                                    + "-pending-delete.json")
    }
    /// The on-disk key doc CloudSyncService syncs (same-URL doctrine as every store).
    var keySyncFileURL: URL { keyFileURL }

    @ObservationIgnored private var sync = SyncState()
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var isFlushing = false
    /// The in-flight flush drain, if any — `deleteCloudData` awaits it so a DELETE can never
    /// race a batch that would re-create the state object it just removed.
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Invalidation epoch for in-flight flushes: bumped by `clearLocal`, `deleteCloudData`,
    /// `enabledDidChange` and a key-doc rebind. `performFlush` captures it at entry and
    /// re-checks after EVERY await — moved means ABANDON: no cursor advance, no ack append,
    /// no persist, no further batches, no error surfaced. Without it a delete/toggle-off that
    /// landed mid-drain was overwritten moments later by the drain's own bookkeeping
    /// (resurrected cursors pointing past batches the server no longer has).
    @ObservationIgnored private var flushEpoch = 0
    @ObservationIgnored private var autoFlushTask: Task<Void, Never>?
    /// Which `startAutoFlush` armed the live loop. A cancelled loop's tail must not detach the
    /// handle of the loop that REPLACED it (see `startAutoFlush`).
    @ObservationIgnored private var autoFlushGeneration = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// Per-song collection-suggestion cache (wire rows so the Add sheet can re-filter): LRU
    /// cap 20, TTL 15 min.
    @ObservationIgnored private var suggestionCache: [String: (atMs: Double, wire: [RecCollectionSuggestionWire])] = [:]
    @ObservationIgnored private var suggestionCacheOrder: [String] = []
    /// Gem Collector's collection-similarity cache: sorted-id-list key → song ids. LRU 8,
    /// same 15-minute TTL as the suggestion cache.
    @ObservationIgnored private var similarCache: [String: (atMs: Double, songIds: [String])] = [:]
    @ObservationIgnored private var similarCacheOrder: [String] = []

    private static let cacheTTLMs: Double = 15 * 60 * 1000
    private static let batchCap = 500
    /// How far BELOW each cursor a flush still looks, so a peer event merged in by CloudKit with
    /// an older timestamp still uploads (see the type doc). 30 days comfortably covers CloudKit
    /// pull latency; anything older than that on a device that has been flushing is already
    /// on the server.
    private static let overlapWindowMs: Double = 30 * 24 * 60 * 60 * 1000
    /// Safety bound on each remembered-ack list (the floor is what normally prunes it). An
    /// evicted entry costs one idempotent re-send, never a lost event — but ONLY when eviction
    /// keeps the NEWEST acks (see `remember`): dropping by append order oscillated (evict →
    /// re-send → re-ack → evict) once a window held more than the cap. 25k comfortably covers
    /// a 30-day window at heavy use (~800 events/day) so the cap is a true backstop.
    static let ackCap = 25_000
    /// Client-side mirrors of the server's snapshot caps (`cleanSnapshot` in index.mjs) — the
    /// server truncates anyway; trimming here keeps the membership hash honest about what was
    /// actually uploaded. `snapshotTotalSongIdCap` mirrors MAX_SNAPSHOT_SONGIDS across ALL
    /// collections; `snapshotByteCap` keeps the encoded snapshot well under the server's 4 MB
    /// body ceiling even riding alongside a full 2000-event batch.
    private static let snapshotCollectionCap = 500
    private static let snapshotSongIdCap = 5_000
    private static let snapshotTotalSongIdCap = 100_000
    private static let snapshotByteCap = 3_500_000
    /// Mirrors the server's MAX_PLAYCOUNT_SONGS (`cleanPlayCounts` in index.mjs).
    private static let playCountsCap = 20_000
    /// Bounded lifetime of the account-deletion retry tombstone: give up (and clean up) after
    /// 20 transient failures or 30 days, whichever comes first. A 403 is terminal immediately —
    /// the carried credential can never succeed, so retrying it is pure noise.
    private static let pendingDeleteMaxAttempts = 20
    private static let pendingDeleteMaxAgeMs: Double = 30 * 24 * 60 * 60 * 1000

    init(client: RecEngineClient,
         settings: SettingsStore,
         history: PlayHistoryStore,
         favorites: FavoritesStore,
         activity: CollectionActivityStore,
         collections: CollectionsStore,
         profileIdProvider: @escaping () -> String,
         keyFileURL: URL = RecommendationService.launchKeyURL(),
         stateFileURL: URL = RecommendationService.launchStateURL()) {
        self.client = client
        self.settings = settings
        self.history = history
        self.favorites = favorites
        self.activity = activity
        self.collections = collections
        self.profileIdProvider = profileIdProvider
        self.keyFileURL = keyFileURL
        self.stateFileURL = stateFileURL
        if let data = try? Data(contentsOf: stateFileURL),
           let decoded = try? JSONDecoder().decode(SyncState.self, from: data) {
            sync = decoded
            lastSyncedAtMs = decoded.lastSyncedAtMs
        }
        key = Self.decodeKey(keyFileURL)
    }

    // MARK: - File locations (the launchURL fixture-seam idiom)

    nonisolated static func defaultKeyURL() -> URL {
        appSupport().appendingPathComponent("pocketdj-rec-key.json")
    }
    nonisolated static func defaultStateURL() -> URL {
        appSupport().appendingPathComponent("pocketdj-rec-sync.json")
    }
    nonisolated static func launchKeyURL() -> URL {
        fixtureURL("pdj-uitest-rec-key.json") ?? defaultKeyURL()
    }
    nonisolated static func launchStateURL() -> URL {
        fixtureURL("pdj-uitest-rec-sync.json") ?? defaultStateURL()
    }
    private nonisolated static func appSupport() -> URL {
        (try? FileManager.default.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
    }
    private nonisolated static func fixtureURL(_ name: String) -> URL? {
        guard ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    // MARK: - Gate

    /// UI-test / preview seam: canned suggestions with zero network. Requires BOTH env vars so
    /// a stray PDJ_REC_FIXTURE in a real run can never light the feature up.
    private static let fixtureOnEnv: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["PDJ_REC_FIXTURE"] == "1" && env["PDJ_USE_FIXTURE"] != nil
    }()

    /// Unit-test override for the env-derived fixture flag (a `static let` can't be flipped
    /// once evaluated). nil in the app — the env decides.
    @ObservationIgnored var fixtureForTesting: Bool?
    private var fixtureOn: Bool { fixtureForTesting ?? Self.fixtureOnEnv }

    /// THE privacy gate — every network-touching method guards this first.
    var isEnabled: Bool { fixtureOn || settings.recEngineEnabled }

    // MARK: - Key management

    private static func decodeKey(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(KeyDoc.self, from: data),
              let k = doc.key, !k.isEmpty else { return nil }
        return k
    }

    /// Re-decode after CloudSyncService pulled a peer's key doc — the self-heal for the
    /// two-devices-enabled-simultaneously race (the pulled key wins; next flush uses it).
    ///
    /// When the pulled key REPLACES a different local one, this device lost that race — and
    /// because the server-side profile id is DERIVED from the key (see the type doc), any
    /// batches it already uploaded live in a state object addressed by the LOSING key's id,
    /// which nothing will ever read again. So on a genuine rebind: reset the cursors (every
    /// event re-uploads under the winner's id — the server dedupes), and best-effort DELETE
    /// the orphaned object while the old key can still authorize it. That delete is the same
    /// "only ever destroys this profile's own rec data" exception `retryPendingCloudDelete`
    /// already carved out of the toggle gate.
    func reloadKeyFromDisk() {
        guard let pulled = Self.decodeKey(keyFileURL), pulled != key else { return }
        let losing = key
        key = pulled
        guard let losing else { return }   // first key on this device — nothing uploaded yet
        flushEpoch &+= 1                   // an in-flight flush is acking into the orphan
        let orphanProfile = scopedProfileId(key: losing)
        let migrated = sync.didMigrateScopedProfile
        sync = SyncState()
        sync.didMigrateScopedProfile = migrated
        persistSyncState()
        let client = client
        Task { try? await client.deleteState(key: losing, profileId: orphanProfile) }
    }

    /// The key, minted + persisted on first use (32 random bytes, hex).
    private func ensureKey() -> String {
        if let key { return key }
        let minted = Self.mintKeyValue()
        key = minted
        if let data = try? JSONEncoder().encode(KeyDoc(schemaVersion: 1, key: minted)) {
            try? data.write(to: keyFileURL, options: .atomic)
        }
        return minted
    }

    /// 32 random bytes, hex — the raw VALUE only. `ensureKey` persists it; `deleteCloudData`
    /// uses one as a NON-persisted throwaway bearer, because the delete path must never mint
    /// identity that outlives the request (R1).
    private static func mintKeyValue() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// The rec-engine-scoped profile id: `HMAC-SHA256(profileId, key: bearer)` hex. See the
    /// type doc — third parties that learned the broadcast `X-PocketDJ-Profile` cannot compute
    /// this without the bearer key, so they can no longer address this profile's rec state.
    private func scopedProfileId(key: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(profileIdProvider().utf8),
                                                  using: SymmetricKey(data: Data(key.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Auto flush

    /// Launch-settle delay and loop period. Overridable so a unit test can drive the loop's
    /// cancel/re-arm race without waiting 20 s (the `fixtureForTesting` seam idiom).
    @ObservationIgnored var autoFlushDelayNs: UInt64 = 20 * 1_000_000_000
    @ObservationIgnored var autoFlushPeriodNs: UInt64 = 600 * 1_000_000_000

    /// Test-visible: is a loop armed? (the one-loop invariant this file guards).
    var isAutoFlushArmed: Bool { autoFlushTask != nil }

    /// Idempotent: ONE loop. Initial 20 s delay (launch settle), then flush every 10 min while
    /// enabled; exits when disabled (re-armed by `enabledDidChange`).
    ///
    /// The generation guard is load-bearing: a task cancelled mid-`postEvents` unwinds
    /// ASYNCHRONOUSLY, so an off→on toggle can arm the replacement BEFORE the cancelled task
    /// reaches its tail. An unconditional `autoFlushTask = nil` there wiped the replacement's
    /// handle, defeating the `guard` below — the next arm (another toggle, or a second macOS
    /// window's `.task`) then started a SECOND concurrent loop that no toggle-off could cancel.
    func startAutoFlush() {
        guard autoFlushTask == nil else { return }
        autoFlushGeneration &+= 1
        let generation = autoFlushGeneration
        autoFlushTask = Task { [weak self] in
            let delay = self?.autoFlushDelayNs ?? 20 * 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            // Finishing an account deletion's server-side wipe is the ONE thing that runs
            // regardless of the toggle — it only ever DELETES data the user asked to erase.
            await self?.retryPendingCloudDelete()
            while !Task.isCancelled {
                guard let self, self.isEnabled else { break }
                await self.flushNow()
                try? await Task.sleep(nanoseconds: self.autoFlushPeriodNs)
            }
            guard let self, self.autoFlushGeneration == generation else { return }
            self.autoFlushTask = nil
        }
    }

    /// 5 s debounce then flush (the scenePhase-background hook).
    func flushSoon() {
        guard isEnabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.flushNow()
        }
    }

    // MARK: - Flush

    /// Upload everything inside each stream's trailing window that the server hasn't
    /// acknowledged yet, in ≤500-per-stream batches until drained (the server caps a batch at
    /// 2000 total events; 4 × 500 fits). Cursors advance ONLY to the max atMs actually SENT,
    /// acks are remembered ONLY on 2xx.
    ///
    /// The drain runs inside a stored `Task` so `deleteCloudData` can AWAIT an in-flight flush
    /// before issuing its DELETE — otherwise a suspended `postEvents` could land at the server
    /// after the deletion and re-create the state object (the batch carries the enrollment
    /// secret, so it enrolls). The epoch capture is what makes the abandoned drain inert on
    /// this side (see `flushEpoch`).
    func flushNow() async {
        guard isEnabled, !isFlushing else { return }
        isFlushing = true
        let epoch = flushEpoch
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performFlush(epoch: epoch)
        }
        flushTask = task
        _ = await task.value
        if flushTask == task { flushTask = nil }
    }

    private func performFlush(epoch: Int) async {
        defer { isFlushing = false }
        let key = ensureKey()
        let profileId = scopedProfileId(key: key)

        // One-time move off the broadcast profile id (see the type doc). Ordered BEFORE the
        // upload so the old object can't outlive the first scoped-id enrollment.
        guard await migrateOffBroadcastProfileId(key: key, epoch: epoch) else { return }

        // The trailing overlap floors — everything at/after them is a candidate, minus what the
        // server already acknowledged. This is what lets a CloudKit-merged peer event (older
        // timestamp, below the cursor) still reach the server. See the type doc.
        let playFloor = Self.windowFloor(sync.lastPlayAtMs)
        let favFloor = Self.windowFloor(sync.lastFavoriteAtMs)
        let actFloor = Self.windowFloor(sync.lastActivityAtMs)
        let puzzleFloor = Self.windowFloor(sync.lastPuzzleAtMs)
        let sentPlays = Set(sync.uploadedPlays)
        let sentFavs = Set(sync.uploadedFavorites)
        let sentActs = Set(sync.uploadedActivity)
        let sentPuzzle = Set(sync.uploadedPuzzle)

        // Snapshot the deltas ON MAIN (cheap value-type filters over @MainActor stores).
        var plays = history.events
            .filter { $0.playedAt >= playFloor
                      && !sentPlays.contains(Self.ack($0.playedAt, $0.id.uuidString)) }
            .sorted { $0.playedAt < $1.playedAt }
            .map { RecPlayEventWire(id: $0.id.uuidString, songId: $0.songId,
                                    atMs: $0.playedAt, source: $0.source.rawValue) }
        var favs = favorites.byId.values
            .filter { $0.atMs >= favFloor && !sentFavs.contains(Self.ack($0.atMs, $0.songId)) }
            .sorted { $0.atMs < $1.atMs }
            .map { RecFavoriteWire(songId: $0.songId, favorited: $0.favorited, atMs: $0.atMs) }
        var acts = activity.events
            .filter { $0.at >= actFloor && !sentActs.contains(Self.ack($0.at, $0.id.uuidString)) }
            .sorted { $0.at < $1.at }
            .map { RecActivityWire(id: $0.id.uuidString, atMs: $0.at, kind: $0.kind.rawValue,
                                   itemId: $0.itemId, collectionId: $0.collectionId,
                                   collectionKind: $0.collectionKind, collectionName: $0.collectionName) }
        var puzzle = (puzzleEventsProvider?(puzzleFloor) ?? [])
            .filter { !sentPuzzle.contains(Self.ack($0.atMs, $0.id)) }
            .sorted { $0.atMs < $1.atMs }

        let snapshot = collectionsSnapshotWire()
        let snapshotHash = Self.snapshotHash(snapshot)
        var pendingSnapshot: RecCollectionsSnapshotWire? =
            snapshotHash != sync.lastCollectionsHash ? snapshot : nil
        // Encoded-size guard: a pathological membership (100k long ids) can encode past the
        // server's body ceiling — never let the snapshot make an EVENT batch undeliverable.
        // The hash deliberately stays un-advanced, so a later, smaller membership re-attempts.
        if let snap = pendingSnapshot, let encoded = try? JSONEncoder().encode(snap),
           encoded.count > Self.snapshotByteCap {
            pendingSnapshot = nil
        }

        // LIFETIME play counts: a SNAPSHOT, hash-gated exactly like the membership one so a
        // 20k-row map isn't re-uploaded on every flush. Trimmed to the server's own cap
        // (most-played first) so the hash describes what the server actually stores.
        let playCountsSnapshot = playCountsWire()
        let playCountsHash = playCountsSnapshot.map(Self.playCountsHash)
        var pendingPlayCounts: RecPlayCountsWire? =
            (playCountsHash != nil && playCountsHash != sync.lastPlayCountsHash) ? playCountsSnapshot : nil

        guard !plays.isEmpty || !favs.isEmpty || !acts.isEmpty || !puzzle.isEmpty
                || pendingSnapshot != nil || pendingPlayCounts != nil else { return }

        while !plays.isEmpty || !favs.isEmpty || !acts.isEmpty || !puzzle.isEmpty
                || pendingSnapshot != nil || pendingPlayCounts != nil {
            let batchPlays = Array(plays.prefix(Self.batchCap))
            let batchFavs = Array(favs.prefix(Self.batchCap))
            let batchActs = Array(acts.prefix(Self.batchCap))
            let batchPuzzle = Array(puzzle.prefix(Self.batchCap))
            func makeBatch(_ snap: RecCollectionsSnapshotWire?,
                           _ counts: RecPlayCountsWire?) -> RecUploadBatch {
                RecUploadBatch(
                    deviceId: DeviceIdentity.current,
                    sentAtMs: Date().timeIntervalSince1970 * 1000,
                    plays: batchPlays.isEmpty ? nil : batchPlays,
                    favorites: batchFavs.isEmpty ? nil : batchFavs,
                    activity: batchActs.isEmpty ? nil : batchActs,
                    puzzle: batchPuzzle.isEmpty ? nil : batchPuzzle,
                    collectionsSnapshot: snap,
                    playCounts: counts)
            }
            var snapshotDelivered = pendingSnapshot != nil
            var playCountsDelivered = pendingPlayCounts != nil
            do {
                do {
                    _ = try await client.postEvents(makeBatch(pendingSnapshot, pendingPlayCounts),
                                                    key: key, profileId: profileId)
                } catch RecEngineClient.ClientError.http(413)
                            where pendingSnapshot != nil || pendingPlayCounts != nil {
                    // A SNAPSHOT is what blew the body ceiling — drop the bulk payloads, not the
                    // events. Their hashes stay un-advanced so a smaller one re-attempts later;
                    // the events must never wedge behind them.
                    guard epoch == flushEpoch else { return }
                    snapshotDelivered = false
                    playCountsDelivered = false
                    if batchPlays.isEmpty && batchFavs.isEmpty && batchActs.isEmpty
                        && batchPuzzle.isEmpty {
                        pendingSnapshot = nil
                        pendingPlayCounts = nil
                        continue   // snapshot-only batch: nothing left to deliver this round
                    }
                    _ = try await client.postEvents(makeBatch(nil, nil), key: key,
                                                    profileId: profileId)
                }
            } catch is CancellationError {
                return   // torn down mid-flight — never a user-facing error (cursors keep)
            } catch let e as URLError where e.code == .cancelled {
                return
            } catch RecEngineClient.ClientError.keyMismatch {
                guard epoch == flushEpoch else { return }
                syncError = Self.keyMismatchMessage
                return   // cursors NOT advanced
            } catch RecEngineClient.ClientError.enrollmentRequired {
                guard epoch == flushEpoch else { return }
                syncError = Self.enrollmentRequiredMessage
                return   // cursors NOT advanced
            } catch {
                guard epoch == flushEpoch else { return }
                syncError = "Couldn't reach the recommendation service."
                return   // cursors NOT advanced; retry next cycle
            }
            guard epoch == flushEpoch else { return }   // deleted/cleared while in flight
            // 2xx: advance each cursor to the max atMs actually sent, and REMEMBER the ids so
            // the overlap window doesn't re-send them next flush.
            if let last = batchPlays.last { sync.lastPlayAtMs = max(sync.lastPlayAtMs, last.atMs) }
            if let last = batchFavs.last { sync.lastFavoriteAtMs = max(sync.lastFavoriteAtMs, last.atMs) }
            if let last = batchActs.last { sync.lastActivityAtMs = max(sync.lastActivityAtMs, last.atMs) }
            if let last = batchPuzzle.last { sync.lastPuzzleAtMs = max(sync.lastPuzzleAtMs, last.atMs) }
            sync.uploadedPlays = Self.remember(sync.uploadedPlays,
                                               batchPlays.map { Self.ack($0.atMs, $0.id) }, floor: playFloor)
            sync.uploadedFavorites = Self.remember(sync.uploadedFavorites,
                                                   batchFavs.map { Self.ack($0.atMs, $0.songId) }, floor: favFloor)
            sync.uploadedActivity = Self.remember(sync.uploadedActivity,
                                                  batchActs.map { Self.ack($0.atMs, $0.id) }, floor: actFloor)
            sync.uploadedPuzzle = Self.remember(sync.uploadedPuzzle,
                                                batchPuzzle.map { Self.ack($0.atMs, $0.id) }, floor: puzzleFloor)
            if snapshotDelivered { sync.lastCollectionsHash = snapshotHash }
            if playCountsDelivered { sync.lastPlayCountsHash = playCountsHash }
            pendingSnapshot = nil
            pendingPlayCounts = nil
            plays.removeFirst(batchPlays.count)
            favs.removeFirst(batchFavs.count)
            acts.removeFirst(batchActs.count)
            puzzle.removeFirst(batchPuzzle.count)
            let now = Date().timeIntervalSince1970 * 1000
            sync.lastSyncedAtMs = now
            lastSyncedAtMs = now
            syncError = nil
            persistSyncState()
        }
    }

    /// The one-time move off the broadcast profile id (see the type doc). Returns `false` when
    /// the caller must ABANDON this flush — a transient failure (retry next cycle) or a moved
    /// epoch (a delete/toggle landed).
    ///
    /// On success the cursors RESET. The scoped id addresses a brand-new, empty state object;
    /// every event this device already acked was acked by the object that just got deleted, so
    /// leaving the acks in place would have suppressed the entire history instead of migrating
    /// it. A full re-upload is the migration — the server dedupes by event id, so a peer that
    /// already migrated pays nothing for it.
    private func migrateOffBroadcastProfileId(key: String, epoch: Int) async -> Bool {
        if sync.didMigrateScopedProfile { return true }
        if sync.lastSyncedAtMs == nil {
            // Never uploaded under ANY id — nothing server-side to migrate, nothing to re-send.
            sync.didMigrateScopedProfile = true
            persistSyncState()
            return true
        }
        do {
            try await client.deleteState(key: key, profileId: profileIdProvider())
        } catch let e as RecEngineClient.ClientError {
            guard epoch == flushEpoch else { return false }
            switch e {
            case .keyMismatch, .enrollmentRequired, .http(400..<500):
                break   // can never succeed with this credential (a peer already deleted it,
                        // or the secret rotated) — stop retrying and re-enroll the scoped id
            case .http, .badResponse:
                return false   // transient server trouble — retry the migration next flush
            }
        } catch {
            return false       // offline / cancelled — retry the migration next flush
        }
        guard epoch == flushEpoch else { return false }
        sync = SyncState()
        sync.didMigrateScopedProfile = true
        persistSyncState()
        return true
    }

    // MARK: - Overlap-window bookkeeping

    /// The floor a stream's flush filter uses: `cursor - overlapWindow`, never below 0.
    private static func windowFloor(_ cursor: Double) -> Double {
        max(0, cursor - overlapWindowMs)
    }

    /// One remembered ack, `"<atMs>|<id>"`. The timestamp rides so the list prunes EXACTLY by
    /// the window floor — a size-only cap would oscillate (evict → re-send → evict).
    private static func ack(_ atMs: Double, _ id: String) -> String {
        "\(Int(atMs.rounded()))|\(id)"
    }

    static func ackAtMs(_ entry: String) -> Double {
        guard let sep = entry.firstIndex(of: "|") else { return 0 }
        return Double(entry[entry.startIndex..<sep]) ?? 0
    }

    /// Append the acks of a delivered batch and drop everything now below the floor (with a
    /// hard `cap` backstop, newest-by-`ackAtMs` kept).
    ///
    /// The cap must evict by TIMESTAMP, not append order: the list is `old-acks + new-batch`,
    /// and a batch of freshly-merged PEER events carries OLD timestamps at the list's TAIL. A
    /// `suffix(cap)` there evicted the newest local acks to keep older peer ones — and every
    /// evicted ack is re-sent, re-acked, re-appended next flush, evicting a different slice
    /// each time: a permanent re-send churn instead of a one-off. Sorting first makes the cap
    /// hit the genuinely oldest acks, which the window floor was about to prune anyway.
    /// (Internal + parameterized cap so the eviction rule itself is testable.)
    static func remember(_ existing: [String], _ added: [String], floor: Double,
                         cap: Int = ackCap) -> [String] {
        guard !added.isEmpty || !existing.isEmpty else { return existing }
        var kept = (existing + added).filter { ackAtMs($0) >= floor }
        if kept.count > cap {
            kept.sort { a, b in
                let ta = ackAtMs(a); let tb = ackAtMs(b)
                return ta != tb ? ta < tb : a < b
            }
            kept = Array(kept.suffix(cap))
        }
        return kept
    }

    /// The current collections membership as the snapshot wire: pockets carry `songIds`
    /// directly; playlists flatten their `.song` node leaves recursively (membership, not
    /// resolution — albums/pockets are NOT expanded, mirroring `playlist(_:contains:)`).
    /// Trimmed to the server's own snapshot caps so the membership hash describes what the
    /// server actually stores.
    private func collectionsSnapshotWire() -> RecCollectionsSnapshotWire {
        var entries: [RecCollectionsSnapshotWire.Entry] = []
        // Total-songIds budget across ALL entries (mirrors the server's MAX_SNAPSHOT_SONGIDS):
        // without it, 500 collections × 5000 ids each is a legal 2.5M-id snapshot — 25× what
        // the server will keep and (encoded) far past its request-body ceiling.
        var budget = Self.snapshotTotalSongIdCap
        func capped(_ ids: [String]) -> [String] {
            let take = min(ids.count, Self.snapshotSongIdCap, max(0, budget))
            budget -= take
            return Array(ids.prefix(take))
        }
        for p in collections.pockets where entries.count < Self.snapshotCollectionCap {
            entries.append(.init(id: p.id, kind: "pocket", name: p.name,
                                 songIds: capped(p.songIds)))
        }
        for pl in collections.playlists where entries.count < Self.snapshotCollectionCap {
            var ids: [String] = []
            var seen = Set<String>()
            func walk(_ nodes: [PlaylistNode]) {
                for n in nodes {
                    if n.kind == .song, let id = n.songId, seen.insert(id).inserted { ids.append(id) }
                    if let kids = n.children { walk(kids) }
                }
            }
            walk(pl.sequences)
            entries.append(.init(id: pl.id, kind: "playlist", name: pl.name,
                                 songIds: capped(ids)))
        }
        return RecCollectionsSnapshotWire(atMs: Date().timeIntervalSince1970 * 1000,
                                          collections: entries)
    }

    /// The lifetime play counts as the snapshot wire, trimmed to the server's own cap — highest
    /// counts first, because that is exactly the order the server truncates in (`cleanPlayCounts`)
    /// and the hash must describe what it actually stores. nil when there is nothing to say.
    private func playCountsWire() -> RecPlayCountsWire? {
        // The per-feature opt-out. The Apple baseline is a far older and more complete record than
        // anything else this service uploads, so it gets its own switch rather than riding the
        // engine's — and the Play counts settings copy points at it by name.
        guard settings.shareLifetimePlayCounts else { return nil }
        guard let counts = playCountsProvider?() else { return nil }
        let positive = counts.filter { $0.value > 0 }
        guard !positive.isEmpty else { return nil }
        let trimmed: [String: Int]
        if positive.count <= Self.playCountsCap {
            trimmed = positive
        } else {
            let head = positive.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .prefix(Self.playCountsCap)
            trimmed = Dictionary(uniqueKeysWithValues: head.map { ($0.key, $0.value) })
        }
        return RecPlayCountsWire(atMs: Date().timeIntervalSince1970 * 1000, counts: trimmed)
    }

    /// Stable content hash of a play-count snapshot — over the COUNTS only, never `atMs` (which
    /// changes every call and would defeat the gate entirely, re-uploading 20k rows per flush).
    private static func playCountsHash(_ wire: RecPlayCountsWire) -> String {
        let lines = wire.counts.map { "\($0.key)|\($0.value)" }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Stable membership hash: one `id|kind|name|joined-songIds` line per entry, sorted, SHA-256.
    private static func snapshotHash(_ snapshot: RecCollectionsSnapshotWire) -> String {
        let lines = snapshot.collections
            .map { "\($0.id)|\($0.kind)|\($0.name)|\($0.songIds.joined(separator: ","))" }
            .sorted()
            .joined(separator: "\n")
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func persistSyncState() {
        if let data = try? JSONEncoder().encode(sync) {
            try? data.write(to: stateFileURL, options: .atomic)
        }
    }

    // MARK: - For You

    func refreshForYou(force: Bool = false) async {
        guard isEnabled else { return }
        if fixtureOn {
            forYou = Self.fixtureForYou
            forYouFetchedAtMs = Date().timeIntervalSince1970 * 1000
            return
        }
        let now = Date().timeIntervalSince1970 * 1000
        if !force, let at = forYouFetchedAtMs, now - at < Self.cacheTTLMs, !forYou.isEmpty { return }
        isLoadingForYou = true
        defer { isLoadingForYou = false }
        await flushNow()   // recs should see the latest plays
        do {
            let key = ensureKey()
            let resp = try await client.forYou(limit: 50, key: key,
                                               profileId: scopedProfileId(key: key))
            forYou = resp.songs.map {
                SongSuggestion(songId: $0.songId, name: $0.name ?? $0.songId,
                               artist: $0.artist ?? "", reasons: $0.reasons ?? [])
            }
            forYouFetchedAtMs = Date().timeIntervalSince1970 * 1000
            syncError = nil
        } catch RecEngineClient.ClientError.keyMismatch {
            syncError = Self.keyMismatchMessage
        } catch {
            if forYou.isEmpty { syncError = "Couldn't reach the recommendation service." }
        }
    }

    /// The wedged-key message. It names a recovery that CAN succeed: "Delete cloud data" now
    /// presents the enrollment secret, which the server accepts in place of the bound key
    /// (before that it 403'd too, so the advice looped the user between two dead ends).
    private static let keyMismatchMessage =
        "This device's recommendation key doesn't match the cloud data. Tap Delete cloud data "
        + "below to reset it — your recommendations rebuild from this device's history."

    /// The rotated-secret message (server 403 `enrollment-required` on an upload that would
    /// CREATE state): this build's baked-in secret predates a server rotation, and no in-app
    /// action can mint a new one — only an app update carries the fresh secret.
    private static let enrollmentRequiredMessage =
        "This PocketDJ build predates a recommendation-service reset. "
        + "Update the app to reconnect — your listening history is safe on this device."

    /// Fixture canned rows (only under the seam). They render standalone — For You rows never
    /// require catalog resolution.
    private static let fixtureForYou: [SongSuggestion] = [
        SongSuggestion(songId: "sng_fix_1", name: "Neon", artist: "Aria",
                       reasons: ["Same genre as recent plays"]),
        SongSuggestion(songId: "sng_fix_2", name: "Running It Up", artist: "Aria",
                       reasons: ["BPM near 120"]),
        SongSuggestion(songId: "sng_fix_3", name: "Golden Hour", artist: "Mira",
                       reasons: ["Often played together"]),
    ]

    // MARK: - Collection suggestions (SongDetail + Add sheet)

    func collectionSuggestions(for songId: String) async -> [CollectionSuggestion] {
        let wire = await rawCollectionSuggestions(for: songId)
        return wire.map {
            CollectionSuggestion(id: $0.id, kind: $0.kind ?? "playlist",
                                 name: $0.name ?? $0.id, reasons: $0.reasons ?? [])
        }
    }

    /// The cached wire rows (the Add sheet feeds these to `RecSuggestionFilter`).
    func rawCollectionSuggestions(for songId: String) async -> [RecCollectionSuggestionWire] {
        guard isEnabled else { return [] }
        if fixtureOn {
            var out: [RecCollectionSuggestionWire] = collections.playlists.prefix(2).map {
                RecCollectionSuggestionWire(id: $0.id, kind: "playlist", name: $0.name,
                                            score: 1.0, reasons: ["Fits this song"])
            }
            if let p = collections.pockets.first {
                out.append(RecCollectionSuggestionWire(id: p.id, kind: "pocket", name: p.name,
                                                       score: 1.0, reasons: ["Fits this song"]))
            }
            return out
        }
        let now = Date().timeIntervalSince1970 * 1000
        if let hit = suggestionCache[songId], now - hit.atMs < Self.cacheTTLMs { return hit.wire }
        do {
            let key = ensureKey()
            let resp = try await client.collectionSuggestions(songId: songId, key: key,
                                                              profileId: scopedProfileId(key: key))
            cacheSuggestions(songId: songId, wire: resp.suggestions, atMs: now)
            return resp.suggestions
        } catch {
            return []   // suggestion surfaces just stay hidden — never block UI
        }
    }

    // MARK: - Collection similarity (Gem Collector's cloud booster)

    /// Songs similar to a SET of collections, best first. Cached 15 min by sorted id list.
    ///
    /// Returns [] when the engine is disabled (the DEFAULT — the privacy gate is checked
    /// first, as in every other network method here), when the service is unreachable, or when
    /// the `/recs/similar` route is not deployed yet (a 404 through `ClientError.http(404)`).
    /// All three are the same outcome to the caller: Gem Collector then ranks LOCALLY, which
    /// is its normal configuration rather than a fallback — so nothing regresses if this
    /// route's deploy is delayed or rolled back.
    func similarSongs(toCollections ids: [String], limit: Int = 200) async -> [String] {
        guard isEnabled, !ids.isEmpty else { return [] }
        let cacheKey = ids.sorted().joined(separator: ",")
        if fixtureOn {
            // Deterministic canned list so UI tests are hermetic.
            return Array(collections.pockets.flatMap(\.songIds).prefix(limit))
        }
        let now = Date().timeIntervalSince1970 * 1000
        if let hit = similarCache[cacheKey], now - hit.atMs < Self.cacheTTLMs { return hit.songIds }
        do {
            let key = ensureKey()
            let resp = try await client.similarToCollections(
                collectionIds: Array(ids.prefix(3)), limit: limit, key: key,
                profileId: scopedProfileId(key: key))
            let songIds = resp.songs.map(\.songId)
            similarCache[cacheKey] = (now, songIds)
            similarCacheOrder.removeAll { $0 == cacheKey }
            similarCacheOrder.append(cacheKey)
            while similarCacheOrder.count > 8 {
                similarCache.removeValue(forKey: similarCacheOrder.removeFirst())
            }
            return songIds
        } catch {
            return []   // never surfaced, never retried — a timed round runs local-only
        }
    }

    private func cacheSuggestions(songId: String, wire: [RecCollectionSuggestionWire], atMs: Double) {
        suggestionCache[songId] = (atMs, wire)
        suggestionCacheOrder.removeAll { $0 == songId }
        suggestionCacheOrder.append(songId)
        while suggestionCacheOrder.count > 20 {
            suggestionCache.removeValue(forKey: suggestionCacheOrder.removeFirst())
        }
    }

    // MARK: - Lifecycle

    /// Settings toggled. OFF: stop the loops and clear the in-memory suggestion state (cursors
    /// + key are RETAINED — re-enable resumes incrementally; server state persists until the
    /// explicit "Delete cloud data"). ON: arm the auto-flush.
    func enabledDidChange() {
        flushEpoch &+= 1   // any in-flight drain must not outlive the toggle that saw it start
        if isEnabled {
            startAutoFlush()
        } else {
            autoFlushTask?.cancel(); autoFlushTask = nil
            debounceTask?.cancel(); debounceTask = nil
            forYou = []
            forYouFetchedAtMs = nil
            suggestionCache = [:]
            suggestionCacheOrder = []
            syncError = nil
        }
    }

    /// "Delete cloud data": remove the server-side state object. On success the cursors reset
    /// to zero so a later re-enable re-uploads history fresh. Explicitly NOT invoked by the
    /// toggle — a toggle flip stays cheap/reversible.
    ///
    /// Works even when this device's key is the WRONG one (the wedge case): the request carries
    /// the enrollment secret, which the server accepts in place of the bound key.
    ///
    /// NEVER MINTS (R1): a device that has no key, no tombstone, and no upload history owes the
    /// server nothing — the old unconditional `ensureKey()` here manufactured + persisted a
    /// brand-new identity (and a network call) out of an offline account deletion on a machine
    /// where the feature was never even on. If state must be addressed keyless (an edge that
    /// requires sync evidence WITHOUT a key), the bearer is a throwaway that never touches disk;
    /// the DELETE it authorizes rides on the enrollment secret.
    @discardableResult
    func deleteCloudData() async -> Bool {
        flushEpoch &+= 1
        if let inflight = flushTask { _ = await inflight.value }   // no batch may land after the DELETE
        if hasPendingCloudDelete { await retryPendingCloudDelete() }   // finish an owed deletion first
        let hasSyncEvidence = sync.lastSyncedAtMs != nil
            || FileManager.default.fileExists(atPath: stateFileURL.path)
        if key == nil, !hasPendingCloudDelete, !hasSyncEvidence {
            return true   // nothing owed — zero network, zero mint
        }
        let bearer = key ?? Self.mintKeyValue()   // throwaway when keyless — NOT persisted
        do {
            try await client.deleteState(key: bearer, profileId: scopedProfileId(key: bearer))
        } catch RecEngineClient.ClientError.keyMismatch, RecEngineClient.ClientError.enrollmentRequired {
            // Distinct from a transient failure: retrying with the same credential can't help.
            syncError = "The server refused to delete this profile's data. "
                + "Update to the latest PocketDJ build and try again."
            return false
        } catch {
            syncError = "Couldn't delete the cloud data — try again."
            return false
        }
        // Pre-scoped-id builds enrolled under the BROADCAST profile id; until the migration
        // flag is set that old object may still exist, and the user asked for it gone too.
        // Best-effort (the secret authorizes it even keyless): a miss is a clean 200.
        if !sync.didMigrateScopedProfile {
            try? await client.deleteState(key: bearer, profileId: profileIdProvider())
        }
        sync = SyncState()
        sync.didMigrateScopedProfile = true   // both ids are gone — nothing left to migrate
        persistSyncState()
        forYou = []
        forYouFetchedAtMs = nil
        suggestionCache = [:]
        suggestionCacheOrder = []
        syncError = nil
        return true
    }

    /// Account-deletion contract: remove both persisted files + in-memory reset.
    ///
    /// `cloudDeleted` is the RESULT of the server-side delete that ran just before. When it
    /// FAILED (offline, a 503), wiping the credential entirely would orphan the profile's
    /// `rec/state/<hash>.json` in S3 forever — the key is the only thing that can authorize
    /// the DELETE, the profile id that addresses the object is reset moments later, and the
    /// bucket has no lifecycle expiry. So on failure the credential moves INTO the tombstone
    /// (key + the exact profile id the delete must target); `retryPendingCloudDelete` finishes
    /// the job on a later launch, then removes it.
    ///
    /// The KEY FILE is removed in BOTH branches (R3): the tombstone is the credential's only
    /// legitimate afterlife. Leaving the CloudSynced key doc in place meant a re-enable reused
    /// the identity whose data the user had just asked to erase — and once the retry finally
    /// landed, it deleted the NEW profile's uploads out from under it (the wedge).
    func clearLocal(cloudDeleted: Bool = true) {
        flushEpoch &+= 1
        autoFlushTask?.cancel(); autoFlushTask = nil
        debounceTask?.cancel(); debounceTask = nil
        if cloudDeleted {
            try? FileManager.default.removeItem(at: pendingDeleteFileURL)
        } else {
            writePendingDelete()   // moves the credential into the tombstone (needs `key` set)
        }
        try? FileManager.default.removeItem(at: keyFileURL)
        key = nil
        try? FileManager.default.removeItem(at: stateFileURL)
        sync = SyncState()
        forYou = []
        forYouFetchedAtMs = nil
        lastSyncedAtMs = nil
        suggestionCache = [:]
        suggestionCacheOrder = []
        syncError = nil
    }

    /// Is a server-side deletion still owed? (Settings ▸ Debug / tests; the retry is automatic.)
    var hasPendingCloudDelete: Bool {
        FileManager.default.fileExists(atPath: pendingDeleteFileURL.path)
    }

    private func writePendingDelete() {
        guard let key else { return }
        let doc = PendingDeleteDoc(
            schemaVersion: 1, key: key, profileId: scopedProfileId(key: key),
            requestedAtMs: Date().timeIntervalSince1970 * 1000, attempts: 0,
            legacyProfileId: sync.didMigrateScopedProfile ? nil : profileIdProvider())
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: pendingDeleteFileURL, options: .atomic)
        }
    }

    /// Finish a deletion the network refused earlier. Runs on the auto-flush task's first pass
    /// (launch) and on foreground, and — deliberately — REGARDLESS of the Settings toggle: the
    /// user asked for their data to be erased, and this is the only call that can honor it.
    /// It is the single exception to "toggle off ⇒ zero network", and it only ever DELETES.
    /// No tombstone ⇒ no request at all, so a normal disabled install stays silent.
    ///
    /// BOUNDED (R3): a 403 is terminal on the spot — key-mismatch and enrollment-required alike
    /// mean this stored credential can never succeed, so the tombstone is removed and a one-time
    /// notice surfaced instead of retrying a dead request forever. Transient failures count up
    /// to `pendingDeleteMaxAttempts` (or `pendingDeleteMaxAgeMs`, whichever first), then the
    /// tombstone gives up and cleans up the same way.
    func retryPendingCloudDelete() async {
        guard let data = try? Data(contentsOf: pendingDeleteFileURL),
              let doc = try? JSONDecoder().decode(PendingDeleteDoc.self, from: data),
              let pendingKey = doc.key, !pendingKey.isEmpty,
              let pendingProfile = doc.profileId, !pendingProfile.isEmpty else { return }
        let attempts = doc.attempts ?? 0
        let ageMs = Date().timeIntervalSince1970 * 1000 - (doc.requestedAtMs ?? 0)
        if attempts >= Self.pendingDeleteMaxAttempts || ageMs > Self.pendingDeleteMaxAgeMs {
            try? FileManager.default.removeItem(at: pendingDeleteFileURL)
            syncError = Self.pendingDeleteGaveUpMessage
            return
        }
        do {
            try await client.deleteState(key: pendingKey, profileId: pendingProfile)
        } catch RecEngineClient.ClientError.keyMismatch, RecEngineClient.ClientError.enrollmentRequired {
            // Terminal: the server has already refused this exact credential — a peer finished
            // the deletion, or the secret rotated. Either way retrying is pure noise.
            try? FileManager.default.removeItem(at: pendingDeleteFileURL)
            syncError = Self.pendingDeleteGaveUpMessage
            return
        } catch {
            var updated = doc
            updated.attempts = attempts + 1
            if let data = try? JSONEncoder().encode(updated) {
                try? data.write(to: pendingDeleteFileURL, options: .atomic)
            }
            return   // still owed — the next launch/foreground tries again
        }
        // The scoped-id object is gone; sweep the pre-migration broadcast-id object too when
        // the tombstone carried one (best-effort — the enrollment secret authorizes it).
        if let legacy = doc.legacyProfileId, !legacy.isEmpty {
            try? await client.deleteState(key: pendingKey, profileId: legacy)
        }
        try? FileManager.default.removeItem(at: pendingDeleteFileURL)
        // The key file was already removed by `clearLocal`; the tombstone was the credential's
        // last copy and it just did its job.
    }

    /// One-time notice when the owed deletion is abandoned (terminal 403 / retry ceiling).
    private static let pendingDeleteGaveUpMessage =
        "PocketDJ couldn't finish deleting this profile's old recommendation data from the "
        + "server and has stopped retrying."
}
