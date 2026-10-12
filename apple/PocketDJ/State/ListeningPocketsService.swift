import Foundation
import Observation

/// LISTENING POCKETS — the app side of the cloud job that finds the stretches where you were in
/// a groove (3+ songs in a row with no skip) and works out what defined them.
///
/// This service: settles location context onto plays (opt-in, iOS), uploads per-play outcomes in
/// idempotent batches to `POST /pockets/events`, fetches `GET /pockets/results` and caches them
/// so History ▸ Pockets renders offline, and erases the server state on "Delete cloud data".
///
/// PRIVACY GATE: `isEnabled` = rec engine ON **and** "Find my listening pockets" ON (or the UI
/// fixture seam). Every network method guards it first; toggle off ⇒ zero calls (the rec-engine
/// doctrine). The ONE exception is `deleteCloudData`, which only ever deletes what the user asked
/// to erase. Raw location never reaches this file — only opaque `plc_`/`trp_` ids via the
/// `ListeningContextProviding` contract.
///
/// ── WHY UPLOAD SELECTION IS A FINGERPRINT, NOT A CURSOR ─────────────────────────────────────
/// A play is uploaded at track START and its outcome lands LATER: the skip verdict, the played
/// fraction, the settled place/trip (a trip's destination is only known on arrival, and CLVisit
/// reports are back-dated by hours). So "already sent" is not enough — what matters is whether
/// the server holds the CURRENT version. Each event's upload-relevant state is reduced to a
/// fingerprint (`outcome|fraction%|ctx|tz`), remembered per event id only on 2xx; a flush sends
/// every event in the 90-day window whose fingerprint moved. The server upserts by event id with
/// monotone merge rules, so a re-send is always harmless.
///
/// The sync doc (`pocketdj-listening-pockets-sync.json`) and the results cache are DEVICE-LOCAL
/// (never CloudSync-registered): two devices uploading overlapping unions is harmless, shared
/// fingerprints would let one device's upload suppress the other's.
@MainActor
@Observable
final class ListeningPocketsService {

    // MARK: - Published state

    /// The last results document (fetched, cached, or the fixture). nil = never fetched.
    private(set) var results: ListeningPocketsResults?
    private(set) var resultsFetchedAtMs: Double?
    private(set) var isRefreshing = false
    private(set) var lastSentAtMs: Double?
    private(set) var syncError: String?
    /// False once the server answered 404 — the `/pockets` routes aren't deployed yet. Silent:
    /// the tab shows an empty state, Settings shows no error. Reset on the next success.
    private(set) var serviceAvailable = true

    // MARK: - Dependencies

    @ObservationIgnored private let history: PlayHistoryStore
    @ObservationIgnored private let settings: SettingsStore
    /// The rec engine's bearer key + scoped profile id (`RecommendationService.sharedCredentials`).
    @ObservationIgnored private let credentials: () -> (key: String, profileId: String)?
    @ObservationIgnored private let provider: any ListeningContextProviding
    @ObservationIgnored private let client: ListeningPocketsClient
    @ObservationIgnored private let now: () -> Date
    /// "Is the places & trips toggle ON?" — gates sending `ctx` at all. nil ⇒ `provider.isActive`
    /// (the app wires the store's `isEnabled`, so a temporarily revoked permission doesn't strip
    /// contexts that were already settled while it was granted).
    @ObservationIgnored var locationOptedIn: (() -> Bool)?
    /// Supplies this install's id + device id for the batch envelope (test seam).
    @ObservationIgnored var deviceIdProvider: () -> String = { DeviceIdentity.current }

    @ObservationIgnored private let syncFileURL: URL
    @ObservationIgnored private let cacheFileURL: URL
    @ObservationIgnored private var sync = SyncDoc()

    // MARK: - Tuning (one place)

    /// Plays older than this never upload (and the server forgets them at 180 days anyway).
    static let windowDays: Double = 90
    /// Events per POST — half the server's 2000 cap so a batch stays far under its 4 MB body.
    static let batchCap = 1000
    /// Results younger than this are served from cache on tab appear.
    static let resultsTTLMs: Double = 10 * 60 * 1000
    static let maxPlaces = 200
    static let maxTrips = 400

    @ObservationIgnored var autoFlushDelayNs: UInt64 = 25 * 1_000_000_000
    @ObservationIgnored var autoFlushPeriodNs: UInt64 = 600 * 1_000_000_000
    @ObservationIgnored var debounceNs: UInt64 = 5 * 1_000_000_000

    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private var flushTask: Task<Bool, Never>?
    /// Invalidation epoch (the RecommendationService pattern): bumped by a toggle, a delete or a
    /// local clear; an in-flight flush re-checks it after every await and abandons on a move.
    @ObservationIgnored private var flushEpoch = 0
    @ObservationIgnored private var autoFlushTask: Task<Void, Never>?
    @ObservationIgnored private var autoFlushGeneration = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    /// Device-local upload bookkeeping.
    struct SyncDoc: Codable, Equatable {
        var schemaVersion = 1
        /// The scoped profile id the fingerprints belong to — a key rebind resets `sent`.
        var profileId: String?
        /// Event UUID string → the fingerprint the server acknowledged.
        var sent: [String: String] = [:]
        var lastResultsGeneratedAtMs: Double?

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
            profileId = (try? c.decodeIfPresent(String.self, forKey: .profileId)) ?? nil
            sent = (try? c.decode([String: String].self, forKey: .sent)) ?? [:]
            lastResultsGeneratedAtMs = (try? c.decodeIfPresent(Double.self, forKey: .lastResultsGeneratedAtMs)) ?? nil
        }
    }

    init(history: PlayHistoryStore,
         settings: SettingsStore,
         credentials: @escaping () -> (key: String, profileId: String)?,
         provider: any ListeningContextProviding,
         client: ListeningPocketsClient = ListeningPocketsClient(),
         now: @escaping () -> Date = Date.init,
         syncFileURL: URL = ListeningPocketsService.launchSyncURL(),
         cacheFileURL: URL = ListeningPocketsService.launchCacheURL()) {
        self.history = history
        self.settings = settings
        self.credentials = credentials
        self.provider = provider
        self.client = client
        self.now = now
        self.syncFileURL = syncFileURL
        self.cacheFileURL = cacheFileURL
        if let data = try? Data(contentsOf: syncFileURL),
           let doc = try? JSONDecoder().decode(SyncDoc.self, from: data) {
            sync = doc
        }
        if Self.fixtureOnEnv {
            results = Self.fixtureResults()
        } else if let data = try? Data(contentsOf: cacheFileURL),
                  let cached = try? JSONDecoder().decode(ListeningPocketsResults.self, from: data) {
            results = cached
        }
    }

    // MARK: - File locations (the launchURL fixture-seam idiom)

    nonisolated static func defaultSyncURL() -> URL {
        appSupport().appendingPathComponent("pocketdj-listening-pockets-sync.json")
    }
    nonisolated static func defaultCacheURL() -> URL {
        appSupport().appendingPathComponent("pocketdj-listening-pockets.json")
    }
    nonisolated static func launchSyncURL() -> URL {
        fixtureURL("pdj-uitest-listening-pockets-sync.json") ?? defaultSyncURL()
    }
    nonisolated static func launchCacheURL() -> URL {
        fixtureURL("pdj-uitest-listening-pockets.json") ?? defaultCacheURL()
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

    /// UI-test seam: canned results, zero network. Requires BOTH env vars (the rec fixture rule).
    nonisolated static let fixtureOnEnv: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["PDJ_POCKETS_FIXTURE"] == "1" && env["PDJ_USE_FIXTURE"] != nil
    }()
    @ObservationIgnored var fixtureForTesting: Bool?
    private var fixtureOn: Bool { fixtureForTesting ?? Self.fixtureOnEnv }

    /// THE privacy gate — every network-touching method guards this first.
    var isEnabled: Bool {
        fixtureOn || (settings.recEngineEnabled && settings.listeningPocketsEnabled)
    }

    /// The bundled canned results (`listening-pockets-fixture.json`).
    static func fixtureResults() -> ListeningPocketsResults? {
        guard let url = Bundle.main.url(forResource: "listening-pockets-fixture", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ListeningPocketsResults.self, from: data)
    }

    // MARK: - Auto flush

    var isAutoFlushArmed: Bool { autoFlushTask != nil }

    /// Idempotent: ONE loop — 25 s launch settle, then a flush every 10 min while enabled. Exits
    /// when disabled (`enabledDidChange` re-arms). Generation-guarded exactly like the rec loop
    /// (a cancelled loop's tail must never detach the handle of the loop that replaced it).
    func startAutoFlush() {
        guard autoFlushTask == nil, isEnabled, !fixtureOn else { return }
        autoFlushGeneration &+= 1
        let generation = autoFlushGeneration
        autoFlushTask = Task { [weak self] in
            let delay = self?.autoFlushDelayNs ?? 25 * 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            while !Task.isCancelled {
                guard let self, self.isEnabled else { break }
                _ = await self.flushNow()
                try? await Task.sleep(nanoseconds: self.autoFlushPeriodNs)
            }
            guard let self, self.autoFlushGeneration == generation else { return }
            self.autoFlushTask = nil
        }
    }

    /// 5 s debounce then flush (the scenePhase-background hook).
    func flushSoon() {
        guard isEnabled, !fixtureOn else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNs ?? 5 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            _ = await self?.flushNow()
        }
    }

    /// Settings toggled (rec engine OR pockets). OFF stops the loops (server data is kept — the
    /// rec-engine rule; deletion is the explicit button). ON arms the loop.
    func enabledDidChange() {
        flushEpoch &+= 1
        if isEnabled {
            startAutoFlush()
        } else {
            autoFlushTask?.cancel(); autoFlushTask = nil
            debounceTask?.cancel(); debounceTask = nil
            syncError = nil
        }
    }

    // MARK: - Flush

    /// Settle contexts, then upload every in-window event whose fingerprint moved, in ≤1000
    /// batches until drained. Fingerprints are remembered ONLY on 2xx. Fetches fresh results
    /// when anything was sent. Returns whether anything was sent.
    @discardableResult
    func flushNow() async -> Bool {
        guard isEnabled, !fixtureOn, !isFlushing else { return false }
        isFlushing = true
        let epoch = flushEpoch
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            return await self.performFlush(epoch: epoch)
        }
        flushTask = task
        let sent = await task.value
        if flushTask == task { flushTask = nil }
        if sent, epoch == flushEpoch { await refreshResults(force: true) }
        return sent
    }

    private func performFlush(epoch: Int) async -> Bool {
        defer { isFlushing = false }
        guard let creds = credentials() else { return false }
        settleContexts()

        if sync.profileId != creds.profileId {
            // A different identity (first run, key rebind, migration): nothing it acknowledged
            // is on THIS profile's server state — start the fingerprints over.
            sync = SyncDoc()
            sync.profileId = creds.profileId
        }
        let floorMs = nowMs - Self.windowDays * 86_400_000
        let window = history.events.filter { $0.playedAt >= floorMs }
            .sorted { $0.playedAt < $1.playedAt }
        // Prune the ack map to the window — the floor is what bounds it.
        let windowIds = Set(window.map { $0.id.uuidString })
        let pruned = sync.sent.filter { windowIds.contains($0.key) }
        if pruned.count != sync.sent.count { sync.sent = pruned; persistSync() }

        let locationOn = locationOptedIn?() ?? provider.isActive
        var pending: [(event: ListeningPocketsUploadEvent, fingerprint: String)] = []
        for e in window {
            let wire = wireEvent(e, locationOn: locationOn)
            let fp = Self.fingerprint(wire)
            if sync.sent[wire.id] != fp { pending.append((wire, fp)) }
        }
        guard !pending.isEmpty else { return false }

        let places: [ListeningPocketsPlaceWire]?
        let trips: [ListeningPocketsTripWire]?
        if provider.isActive {
            places = provider.placeLabels().prefix(Self.maxPlaces).map {
                ListeningPocketsPlaceWire(id: $0.id, rank: $0.rank, label: $0.label,
                                          share: ($0.shareOfTime * 1000).rounded() / 1000)
            }
            trips = provider.tripLabels().prefix(Self.maxTrips).map {
                ListeningPocketsTripWire(id: $0.id, origin: $0.origin, destination: $0.destination,
                                         label: $0.label, occurrences: $0.occurrences)
            }
        } else {
            places = nil; trips = nil
        }

        var sentAny = false
        while !pending.isEmpty {
            let slice = Array(pending.prefix(Self.batchCap))
            let batch = ListeningPocketsUploadBatch(
                deviceId: deviceIdProvider(), installId: history.installId,
                sentAtMs: Int64(nowMs), events: Self.assignOrd(slice.map(\.event)),
                places: places, trips: trips)
            do {
                _ = try await client.postEvents(batch, key: creds.key, profileId: creds.profileId)
            } catch is CancellationError {
                return sentAny
            } catch let e as URLError where e.code == .cancelled {
                return sentAny
            } catch ListeningPocketsClient.ClientError.notFound {
                guard epoch == flushEpoch else { return sentAny }
                serviceAvailable = false   // routes not deployed yet — silent, retried next cycle
                return sentAny
            } catch let e as ListeningPocketsClient.ClientError {
                guard epoch == flushEpoch else { return sentAny }
                syncError = Self.message(for: e)
                return sentAny
            } catch {
                guard epoch == flushEpoch else { return sentAny }
                syncError = "Couldn't reach the listening-pockets service."
                return sentAny
            }
            guard epoch == flushEpoch else { return sentAny }   // deleted / toggled mid-flight
            for item in slice { sync.sent[item.event.id] = item.fingerprint }
            persistSync()
            pending.removeFirst(slice.count)
            sentAny = true
            serviceAvailable = true
            syncError = nil
            lastSentAtMs = nowMs
        }
        return sentAny
    }

    /// The settle pass: stamp every LOCAL in-window play still missing a context with what the
    /// provider now calls SETTLED for its timestamp. `.pending` (a trip still under way, a visit
    /// that may yet be back-dated over it) and `.unavailable` stay nil — asked again next flush.
    func settleContexts() {
        guard provider.isActive else { return }
        let floorMs = nowMs - Self.windowDays * 86_400_000
        var tags: [UUID: ListeningContextTag] = [:]
        for e in history.events where e.listeningContext == nil && e.playedAt >= floorMs
            && !history.isFromAnotherDevice(e) {
            if case .settled(let tag) = provider.context(at: Date(timeIntervalSince1970: e.playedAt / 1000)) {
                tags[e.id] = tag
            }
        }
        history.stampContexts(tags)
    }

    // MARK: - Wire mapping

    private var nowMs: Double { now().timeIntervalSince1970 * 1000 }

    /// One history event → its upload row (`ord` assigned per batch by `assignOrd`).
    func wireEvent(_ e: PlayHistoryStore.PlayEvent, locationOn: Bool) -> ListeningPocketsUploadEvent {
        let tz = e.tzOffsetMin
            ?? TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: e.playedAt / 1000)) / 60
        // Context rides only on THIS device's plays, and only while places & trips is on.
        let ctx = (locationOn && !history.isFromAnotherDevice(e)) ? e.listeningContext : nil
        return ListeningPocketsUploadEvent(
            id: e.id.uuidString, songId: e.songId, atMs: Self.flooredMinute(e.playedAt), ord: 0,
            tzOffsetMin: tz, source: e.source.rawValue, outcome: e.outcome.rawValue,
            fraction: e.listenedFraction.map { ($0 * 1000).rounded() / 1000 },
            originInstallId: e.originInstallId, artist: e.artist, carPlay: e.carPlay, ctx: ctx)
    }

    /// Coarse time on the wire: play start floored to the minute.
    static func flooredMinute(_ ms: Double) -> Int64 {
        Int64((ms / 60_000).rounded(.down)) * 60_000
    }

    /// `ord` = order among THIS batch's events sharing `atMs` and stream (originInstallId ??
    /// uploader), in play order — restores the sequence the minute-flooring erased.
    static func assignOrd(_ events: [ListeningPocketsUploadEvent]) -> [ListeningPocketsUploadEvent] {
        var seen: [String: Int] = [:]
        return events.map { e in
            var e = e
            let key = "\(e.originInstallId ?? "-")|\(e.atMs)"
            e.ord = seen[key, default: 0]
            seen[key] = e.ord + 1
            return e
        }
    }

    /// Everything about an event that can CHANGE after its first upload — a moved fingerprint
    /// is what makes a flush re-send it.
    static func fingerprint(_ e: ListeningPocketsUploadEvent) -> String {
        let pct = e.fraction.map { String(Int(($0 * 100).rounded())) } ?? "-"
        let ctx = e.ctx.map { "\($0.kind)/\($0.placeId ?? "")/\($0.tripId ?? "")/\($0.destination ?? "")" } ?? "-"
        return "\(e.outcome)|\(pct)|\(ctx)|\(e.tzOffsetMin ?? 0)"
    }

    private static func message(for e: ListeningPocketsClient.ClientError) -> String {
        switch e {
        case .keyMismatch:
            return "The listening-pockets service didn't recognise this device's key. "
                + "Use \"Delete cloud data\" to reset it."
        case .enrollmentRequired:
            return "This PocketDJ build can't sign up for listening pockets. Update the app."
        case .profileCapReached:
            return "The listening-pockets service isn't accepting new profiles right now."
        default:
            return "Couldn't reach the listening-pockets service."
        }
    }

    // MARK: - Results

    /// Fetch results unless the cache is fresh (`force` ignores the TTL). The fixture seam
    /// answers from the bundle with zero network.
    func refreshResults(force: Bool = false) async {
        guard isEnabled else { return }
        if fixtureOn {
            results = Self.fixtureResults() ?? .empty
            resultsFetchedAtMs = nowMs
            return
        }
        if !force, let at = resultsFetchedAtMs, nowMs - at < Self.resultsTTLMs { return }
        guard let creds = credentials() else { return }
        let epoch = flushEpoch
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (decoded, raw) = try await client.results(key: creds.key, profileId: creds.profileId)
            guard epoch == flushEpoch else { return }
            results = decoded
            resultsFetchedAtMs = nowMs
            serviceAvailable = true
            try? raw.write(to: cacheFileURL, options: .atomic)
            sync.lastResultsGeneratedAtMs = decoded.generatedAtMs
            persistSync()
        } catch ListeningPocketsClient.ClientError.notFound {
            guard epoch == flushEpoch else { return }
            serviceAvailable = false
        } catch let e as ListeningPocketsClient.ClientError {
            guard epoch == flushEpoch else { return }
            if e != .badResponse { syncError = Self.message(for: e) }
        } catch {
            // Offline etc. — keep serving the cache; the next appear/refresh retries.
        }
    }

    /// Tab appear: refresh only when the cache is older than the TTL.
    func refreshIfStale() async {
        await refreshResults(force: false)
    }

    /// Pull-to-refresh: upload first (fresh plays should count), then fetch.
    func refreshNow() async {
        guard isEnabled else { return }
        let sent = await flushNow()
        if !sent { await refreshResults(force: true) }
    }

    // MARK: - Deletion

    /// The "Delete cloud data" cascade (`RecommendationService.onDeleteCloudData`): erase the
    /// server's pockets events + results with the credential that just erased the rec state,
    /// then the local cache + sync doc. Runs regardless of the toggles — it only ever deletes.
    /// A 404 is success (nothing deployed ⇒ nothing stored).
    @discardableResult
    func deleteCloudData(key: String, profileId: String) async -> Bool {
        flushEpoch &+= 1
        if let inflight = flushTask { _ = await inflight.value }   // no batch may land after the DELETE
        do {
            try await client.deleteState(key: key, profileId: profileId)
        } catch ListeningPocketsClient.ClientError.notFound {
            // Not deployed — nothing to erase server-side.
        } catch {
            syncError = "Couldn't delete the listening-pockets data — try again."
            return false
        }
        resetLocalState()
        return true
    }

    /// Account-deletion contract: drop every local file + in-memory state, stop the loops.
    func clearLocal() {
        flushEpoch &+= 1
        autoFlushTask?.cancel(); autoFlushTask = nil
        debounceTask?.cancel(); debounceTask = nil
        resetLocalState()
    }

    private func resetLocalState() {
        try? FileManager.default.removeItem(at: syncFileURL)
        try? FileManager.default.removeItem(at: cacheFileURL)
        sync = SyncDoc()
        results = fixtureOn ? Self.fixtureResults() : nil
        resultsFetchedAtMs = nil
        lastSentAtMs = nil
        syncError = nil
    }

    // MARK: - Test seams

    /// Fingerprints acknowledged so far (tests).
    var acknowledgedFingerprints: [String: String] { sync.sent }

    private func persistSync() {
        if let data = try? JSONEncoder().encode(sync) { try? data.write(to: syncFileURL, options: .atomic) }
    }
}
