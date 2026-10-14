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
    /// Fired when the gate CLOSES (engine or pockets turned off). The app wires it to turn places
    /// & trips off too: location collection exists only to feed pockets, so it must never keep
    /// running (CLVisit relaunches, stored coordinates) with nothing to feed.
    @ObservationIgnored var onDisabled: (() -> Void)?
    /// Supplies this install's id + device id for the batch envelope (test seam).
    @ObservationIgnored var deviceIdProvider: () -> String = { DeviceIdentity.current }
    /// "In the Pocket" rounds to upload (`InThePocketStore.uploadWires`), given this install's id.
    /// nil ⇒ no game wired (tests, older call sites) — the flush is events-only, exactly as before.
    @ObservationIgnored var roundsProvider: ((String) -> [InThePocketRoundWire])?
    /// False once `POST /pockets/rounds` answered 404 (a backend without the route). Rounds stay
    /// QUEUED — unacknowledged — and every later flush tries again. Silent, like `serviceAvailable`.
    private(set) var roundsServiceAvailable = true
    /// The collections (pockets / playlists / source playlists + the add log) for the membership
    /// snapshot (docs/design/pockets-collections.md). nil ⇒ none wired (tests, older call sites):
    /// the flush never sends `collections` / `addEvents`, exactly as before.
    @ObservationIgnored var collectionsProvider: (() -> ListeningPocketsCollections.Input)?

    @ObservationIgnored private let syncFileURL: URL
    @ObservationIgnored private let cacheFileURL: URL
    @ObservationIgnored private var sync = SyncDoc()

    // MARK: - Tuning (one place)

    /// Plays older than this never upload (and the server forgets them at 180 days anyway).
    static let windowDays: Double = 90
    /// Events per POST — half the server's 2000 cap so a batch stays far under its 4 MB body.
    static let batchCap = 1000
    /// Rounds per POST — the server's cap.
    static let roundsBatchCap = 50
    /// Results younger than this are served from cache on tab appear.
    static let resultsTTLMs: Double = 10 * 60 * 1000
    static let maxPlaces = 200
    static let maxTrips = 400

    @ObservationIgnored var autoFlushDelayNs: UInt64 = 25 * 1_000_000_000
    @ObservationIgnored var autoFlushPeriodNs: UInt64 = 600 * 1_000_000_000
    @ObservationIgnored var debounceNs: UInt64 = 5 * 1_000_000_000

    @ObservationIgnored private var isFlushing = false
    /// True while "Delete cloud data" is awaiting its DELETE — no flush may start meanwhile, or a
    /// batch could land on the server after the erase.
    @ObservationIgnored private var isDeleting = false
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
        /// Set by "Delete cloud data": plays before it never upload again. The erase is of
        /// everything uploaded so far, and the dialog promises only FRESH data afterwards — without
        /// this, clearing `sent` would make the next flush re-send the whole 90-day window. Survives
        /// every reset except account deletion (`clearLocal`).
        var uploadFloorMs: Double?
        /// Round UUID string → the round fingerprint the server acknowledged (the events idea:
        /// a round whose feedback / rating changed after its first upload re-sends).
        var sentRounds: [String: String] = [:]
        /// Content hash + send time of the last ACKNOWLEDGED collections snapshot (the 24 h /
        /// changed-content gate).
        var collectionsHash: String?
        var collectionsSentAtMs: Double?

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
            profileId = (try? c.decodeIfPresent(String.self, forKey: .profileId)) ?? nil
            sent = (try? c.decode([String: String].self, forKey: .sent)) ?? [:]
            lastResultsGeneratedAtMs = (try? c.decodeIfPresent(Double.self, forKey: .lastResultsGeneratedAtMs)) ?? nil
            uploadFloorMs = (try? c.decodeIfPresent(Double.self, forKey: .uploadFloorMs)) ?? nil
            sentRounds = (try? c.decode([String: String].self, forKey: .sentRounds)) ?? [:]
            collectionsHash = (try? c.decodeIfPresent(String.self, forKey: .collectionsHash)) ?? nil
            collectionsSentAtMs = (try? c.decodeIfPresent(Double.self, forKey: .collectionsSentAtMs)) ?? nil
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

    /// What turning pockets on sends — shown wherever the user can turn it on (Settings and the
    /// one-time offer in History ▸ Pockets), so the switch is never flipped blind.
    static let consentText = "Turning this on sends, for each play in the last 90 days and from now on: the song and its artist, "
        + "when it started (to the minute) and your time-zone offset, whether you finished or skipped it, "
        + "where in the app you played it (which collection, by id), and whether CarPlay was connected. "
        + "It also sends which songs are in each of your pockets and playlists and when you added them "
        + "(ids only, never their names). PocketDJ uses it to find the stretches where you were in a groove."

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
            onDisabled?()
        }
    }

    // MARK: - Flush

    /// Settle contexts, then upload every in-window event whose fingerprint moved, in ≤1000
    /// batches until drained. Fingerprints are remembered ONLY on 2xx. Fetches fresh results
    /// when anything was sent. Returns whether anything was sent.
    @discardableResult
    func flushNow() async -> Bool {
        guard isEnabled, !fixtureOn, !isFlushing, !isDeleting else { return false }
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
            let floor = sync.uploadFloorMs
            sync = SyncDoc()
            sync.profileId = creds.profileId
            sync.uploadFloorMs = floor
        }
        let floorMs = max(nowMs - Self.windowDays * 86_400_000, sync.uploadFloorMs ?? 0)
        let window = history.events.filter { $0.playedAt >= floorMs }
            .sorted { $0.playedAt < $1.playedAt }
        // Prune the ack map to the window — the floor is what bounds it.
        let windowIds = Set(window.map { $0.id.uuidString })
        let pruned = sync.sent.filter { windowIds.contains($0.key) }
        if pruned.count != sync.sent.count { sync.sent = pruned; persistSync() }

        let locationOn = locationOptedIn?() ?? provider.isActive
        let ords = Self.ordinals(history.events, installId: history.installId)
        var pending: [(event: ListeningPocketsUploadEvent, fingerprint: String)] = []
        for e in window {
            var wire = wireEvent(e, locationOn: locationOn)
            wire.ord = ords[e.id] ?? 0
            let fp = Self.fingerprint(wire)
            if sync.sent[wire.id] != fp { pending.append((wire, fp)) }
        }
        // Collections + rounds ride the same flush, AFTER the plays (a round's songs are plays
        // too; a membership snapshot is about the songs the plays name).
        guard !pending.isEmpty else {
            let collectionsSent = await uploadCollections(creds: creds, epoch: epoch)
            guard epoch == flushEpoch else { return collectionsSent }
            let roundsSent = await uploadRounds(creds: creds, epoch: epoch)
            return collectionsSent || roundsSent
        }

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
                sentAtMs: Int64(nowMs), events: slice.map(\.event),
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
        let collectionsSent = await uploadCollections(creds: creds, epoch: epoch)
        guard epoch == flushEpoch else { return sentAny || collectionsSent }
        let roundsSent = await uploadRounds(creds: creds, epoch: epoch)
        return sentAny || collectionsSent || roundsSent
    }

    /// The membership snapshot + add history, in ONE batch of their own (`events: []` — the
    /// server accepts it) so they never push an events batch past the 4 MB body ceiling. Sent
    /// when the content hash moved or >= 24 h since the last ACKNOWLEDGED send; acknowledged only
    /// on 2xx. Oversized => the add history is dropped first, then (still oversized) the whole
    /// snapshot is skipped with the hash un-advanced. Failures are silent — the events path owns
    /// the user-visible error.
    private func uploadCollections(creds: (key: String, profileId: String), epoch: Int) async -> Bool {
        guard let payload = collectionsPayloadIfDue() else { return false }
        var batch = ListeningPocketsUploadBatch(
            deviceId: deviceIdProvider(), installId: history.installId, sentAtMs: Int64(nowMs),
            events: [], places: nil, trips: nil,
            collections: payload.collections, addEvents: payload.addEvents.isEmpty ? nil : payload.addEvents)
        if let data = try? JSONEncoder().encode(batch), data.count > ListeningPocketsCollections.byteCap {
            batch.addEvents = nil
            if let slim = try? JSONEncoder().encode(batch), slim.count > ListeningPocketsCollections.byteCap {
                return false
            }
        }
        do {
            _ = try await client.postEvents(batch, key: creds.key, profileId: creds.profileId)
        } catch {
            return false
        }
        guard epoch == flushEpoch else { return false }
        sync.collectionsHash = payload.hash
        sync.collectionsSentAtMs = nowMs
        persistSync()
        return true
    }

    /// The current payload when it is due (changed, or >= 24 h since the last ack), else nil.
    /// Nothing at all to say (no collections, no adds) is never due.
    func collectionsPayloadIfDue() -> ListeningPocketsCollections.Payload? {
        guard let input = collectionsProvider?() else { return nil }
        let payload = ListeningPocketsCollections.build(input, nowMs: nowMs, floorMs: sync.uploadFloorMs ?? 0)
        guard !payload.isEmpty,
              ListeningPocketsCollections.isDue(hash: payload.hash, lastHash: sync.collectionsHash,
                                                lastSentAtMs: sync.collectionsSentAtMs, nowMs: nowMs)
        else { return nil }
        return payload
    }

    /// Upload every finished "In the Pocket" round whose fingerprint moved, in ≤ 50 batches.
    /// Acknowledged ONLY on 2xx; ANY failure — a 404 from a backend without `/pockets/rounds`
    /// above all — leaves the rest queued for the next flush, silently (the events path owns the
    /// user-visible sync error). Rounds before the "Delete cloud data" floor never upload again.
    private func uploadRounds(creds: (key: String, profileId: String), epoch: Int) async -> Bool {
        guard let roundsProvider else { return false }
        let floorMs = max(nowMs - Self.windowDays * 86_400_000, sync.uploadFloorMs ?? 0)
        let wires = roundsProvider(history.installId).filter { Double($0.startedAtMs) >= floorMs }
        let ids = Set(wires.map(\.id))
        let pruned = sync.sentRounds.filter { ids.contains($0.key) }
        if pruned.count != sync.sentRounds.count { sync.sentRounds = pruned; persistSync() }
        var pending = wires.filter { sync.sentRounds[$0.id] != $0.fingerprint }
        var sentAny = false
        while !pending.isEmpty {
            let slice = Array(pending.prefix(Self.roundsBatchCap))
            let batch = InThePocketRoundsBatch(deviceId: deviceIdProvider(), installId: history.installId,
                                               sentAtMs: Int64(nowMs), rounds: slice)
            do {
                _ = try await client.postRounds(batch, key: creds.key, profileId: creds.profileId)
            } catch ListeningPocketsClient.ClientError.notFound {
                if epoch == flushEpoch { roundsServiceAvailable = false }
                return sentAny
            } catch {
                return sentAny
            }
            guard epoch == flushEpoch else { return sentAny }
            for w in slice { sync.sentRounds[w.id] = w.fingerprint }
            persistSync()
            pending.removeFirst(slice.count)
            sentAny = true
            roundsServiceAvailable = true
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

    /// One history event → its upload row (`ord` is filled in from `ordinals`).
    func wireEvent(_ e: PlayHistoryStore.PlayEvent, locationOn: Bool) -> ListeningPocketsUploadEvent {
        let tz = e.tzOffsetMin
            ?? TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: e.playedAt / 1000)) / 60
        // Context rides only on THIS device's plays, and only while places & trips is on.
        let ctx = (locationOn && !history.isFromAnotherDevice(e)) ? e.listeningContext : nil
        // The collection the play started from — ids only; the reserved Now Playing queue id
        // is replaced by the run's captured origin when it has one.
        let collection = ListeningPocketsCollections.context(contextId: e.originCollectionId ?? e.contextId,
                                                             source: e.source)
        return ListeningPocketsUploadEvent(
            id: e.id.uuidString, songId: e.songId, atMs: Self.flooredMinute(e.playedAt), ord: 0,
            tzOffsetMin: tz, source: e.source.rawValue, outcome: e.outcome.rawValue,
            fraction: e.listenedFraction.map { ($0 * 1000).rounded() / 1000 },
            originInstallId: e.originInstallId, artist: e.artist, carPlay: e.carPlay, ctx: ctx,
            contextId: collection?.id, contextKind: collection?.kind)
    }

    /// Coarse time on the wire: play start floored to the minute.
    static func flooredMinute(_ ms: Double) -> Int64 {
        Int64((ms / 60_000).rounded(.down)) * 60_000
    }

    /// `ord` = an event's position among the plays sharing its minute-floored `atMs` and stream
    /// (originInstallId ?? this install — the server's stream key), in play order. Restores the
    /// sequence the minute-flooring erased. Computed over the WHOLE log, not per batch: the server
    /// keeps `ord` immutable from the first insert, so two same-minute plays uploaded by different
    /// flushes (the second one's fingerprint moved later) must not both claim `ord` 0 — a tie
    /// falls back to the random UUID and can flip a skip run across a pocket boundary.
    static func ordinals(_ events: [PlayHistoryStore.PlayEvent], installId: String) -> [UUID: Int] {
        var seen: [String: Int] = [:]
        var out: [UUID: Int] = [:]
        out.reserveCapacity(events.count)
        let ordered = events.sorted {
            $0.playedAt != $1.playedAt ? $0.playedAt < $1.playedAt : $0.id.uuidString < $1.id.uuidString
        }
        for e in ordered {
            let key = "\(e.originInstallId ?? installId)|\(flooredMinute(e.playedAt))"
            let n = seen[key, default: 0]
            out[e.id] = n
            seen[key] = n + 1
        }
        return out
    }

    /// Everything about an event that can CHANGE after its first upload — a moved fingerprint
    /// is what makes a flush re-send it.
    static func fingerprint(_ e: ListeningPocketsUploadEvent) -> String {
        let pct = e.fraction.map { String(Int(($0 * 100).rounded())) } ?? "-"
        let ctx = e.ctx.map { "\($0.kind)/\($0.placeId ?? "")/\($0.tripId ?? "")/\($0.destination ?? "")" } ?? "-"
        let base = "\(e.outcome)|\(pct)|\(ctx)|\(e.tzOffsetMin ?? 0)"
        // Appended only when present, so every pre-collections fingerprint stays identical (no
        // mass re-send of 90 days on update); a play that carries a context re-sends once.
        guard let cid = e.contextId else { return base }
        return base + "|\(e.contextKind ?? "")/\(cid)"
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
        // No flush may START while the DELETE is in flight either (the auto loop keeps ticking).
        isDeleting = true
        defer { isDeleting = false }
        if let inflight = flushTask { _ = await inflight.value }   // no batch may land after the DELETE
        let erasedAtMs = nowMs
        do {
            try await client.deleteState(key: key, profileId: profileId)
        } catch ListeningPocketsClient.ClientError.notFound {
            // Not deployed — nothing to erase server-side.
        } catch {
            syncError = "Couldn't delete the listening-pockets data — try again."
            return false
        }
        resetLocalState()
        // "Fresh data from now on": plays before the erase stay off the server for good.
        sync.uploadFloorMs = max(sync.uploadFloorMs ?? 0, erasedAtMs)
        persistSync()
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
    /// Plays before this never upload (set by "Delete cloud data"; tests).
    var uploadFloorMs: Double? { sync.uploadFloorMs }
    /// Round fingerprints acknowledged so far (tests + the game's "uploaded" tick).
    var acknowledgedRounds: [String: String] { sync.sentRounds }

    private func persistSync() {
        if let data = try? JSONEncoder().encode(sync) { try? data.write(to: syncFileURL, options: .atomic) }
    }
}
