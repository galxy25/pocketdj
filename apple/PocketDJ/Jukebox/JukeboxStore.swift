import Foundation
import Observation

/// APP-SCOPED Jukebox Hero session engine (docs/design/jukebox-hero.md). While a jukebox
/// is live it runs one background loop that, every few seconds:
///   • posts a player-state snapshot (now playing + up next, from the app-scoped
///     `SetlistPlayer`) to the jukebox server, which publishes it to S3 for the guests'
///     pages — S3 is the distribution, so any number of guests costs the host nothing;
///   • polls the server for new guest requests and runs each through `JukeboxMatcher`
///     (catalog fuzzy match + on-device FM pick + Apple Music search) into the inbox.
/// The HOST decides each request: deny, play next, play last, or a random slot — queue
/// placements ride the SetlistPlayer live-edit API, and playback flows through the
/// existing provider chain (Apple Music stream → rip-server stream/rip; no new paths).
///
/// App-scoped (created in `PocketDJApp.init`, injected via `.environment`) so a running
/// jukebox survives navigation — and the session persists in UserDefaults so an app
/// relaunch re-adopts it (the party doesn't end because the app restarted).
@MainActor
@Observable
final class JukeboxStore {

    /// A guest request in the host's inbox. `match` is nil while matching is in flight;
    /// `.none` when nothing matched (deny is the only action).
    struct InboxItem: Identifiable, Equatable {
        var request: JukeboxRequest
        var match: JukeboxMatch?
        var id: String { request.id }
    }

    private(set) var session: JukeboxSessionInfo?
    /// View + Hear mode (default OFF = view-only request line). When on, snapshots carry
    /// the current track's public S3 rip URL so guest pages can play along. Persisted
    /// beside the session; flipping it posts a fresh snapshot on the next loop turn.
    var hearEnabled = false {
        didSet {
            guard hearEnabled != oldValue else { return }
            defaults.set(hearEnabled, forKey: Self.hearKey)
            Task { await tick() }   // guests see the mode flip promptly, not next heartbeat
        }
    }
    private(set) var inbox: [InboxItem] = []
    /// The last transport failure, for a subtle "reconnecting" hint — the loop keeps
    /// retrying on its own; a flaky Funnel link must not kill the party.
    private(set) var lastError: String?
    private(set) var starting = false
    private(set) var ending = false

    private let app: AppModel
    private let sequencer: SetlistPlayer
    private let player: PlayerEngine
    private let coordinator: PlaybackCoordinator
    private let rips: RipsStore
    private let mix: MixEngine
    private let burns: BurnStore
    /// Wired in App.init (the RipsStore.settings pattern) — server URL + token live there.
    @ObservationIgnored var settings: SettingsStore?

    // Seams (wired in App.init; stubbed in tests).
    /// Builds the on-device pick model once per session; nil ⇒ top-candidate fallback.
    @ObservationIgnored var makePickModel: @MainActor () -> (any JukeboxPickModel)? = {
        JukeboxPickModelFactory.make()
    }
    /// Apple Music catalog search (`AppleMusicProvider.search`); nil ⇒ catalog-only matching.
    @ObservationIgnored var searchAppleMusic: (@MainActor (String) async -> [StreamingTrack])?
    /// URLSession for the jukebox client — injectable so unit tests stub the transport.
    @ObservationIgnored var urlSession: URLSession = .shared

    private var loopTask: Task<Void, Never>?
    private var pickModel: (any JukeboxPickModel)?
    /// The server's request cursor (poll `?since=seq`).
    private var seq = 0
    /// Requests already decided locally — never re-inboxed even if a poll races the decision.
    private var decided = Set<String>()
    private var lastPostedState: JukeboxStatePayload?
    private var lastStatePostAt: TimeInterval = 0

    /// Accepted-but-not-yet-burned tracks headed for the AUTO-MIX queue. A Mix deck can
    /// only load a BURNED file, so accepting an unburned request during a broadcast
    /// kicks a rip+burn and parks the insert here; the loop tick lands each one the
    /// moment its file exists (or lets it go after 15 minutes / when nothing's on air).
    struct PendingMixInsert {
        let songId: String
        let loadable: MixLoadable
        let durationMs: Int
        let placement: JukeboxDecisionAction
        let deadline: TimeInterval
    }
    private(set) var pendingMixInserts: [PendingMixInsert] = []

    private let defaults: UserDefaults
    private static let sessionKey = "pdj.jukebox.session.v1"
    private static let hearKey = "pdj.jukebox.hear.v1"

    init(app: AppModel, sequencer: SetlistPlayer, player: PlayerEngine,
         coordinator: PlaybackCoordinator, rips: RipsStore,
         mix: MixEngine, burns: BurnStore,
         defaults: UserDefaults = .standard) {
        self.app = app
        self.sequencer = sequencer
        self.player = player
        self.coordinator = coordinator
        self.rips = rips
        self.mix = mix
        self.burns = burns
        self.defaults = defaults
    }

    private var client: JukeboxClient {
        JukeboxClient(baseURL: settings?.jukeboxServerURL ?? "",
                      token: settings?.jukeboxToken ?? "",
                      session: urlSession)
    }

    // MARK: - Session lifecycle

    /// Re-adopt a persisted session after a relaunch. Called once from App.init AFTER the
    /// seams are wired (the loop needs settings + the search seam).
    func resumePersistedSession() {
        guard session == nil,
              let data = defaults.data(forKey: Self.sessionKey),
              let saved = try? JSONDecoder().decode(JukeboxSessionInfo.self, from: data) else { return }
        hearEnabled = defaults.bool(forKey: Self.hearKey)
        session = saved
        pickModel = makePickModel()
        startLoop()
    }

    /// Create a jukebox on the server (it renders + uploads the guest page and seeds
    /// `state.json`) and start the session loop. Errors land on `lastError`.
    /// `timeless: false` (the default party) auto-ends after 24 h and is sweeper-deleted
    /// at 7 days — all server-side.
    func start(name: String, timeless: Bool = false, requiresToken: Bool = true) async {
        guard session == nil, !starting else { return }
        starting = true
        defer { starting = false }
        lastError = nil
        do {
            let s = try await client.create(name: name, timeless: timeless, requiresToken: requiresToken)
            session = s
            // Record the caller's intent even though the server doesn't echo/mint the guest
            // token yet (#TOUPDATE on JukeboxSessionInfo.requiresToken) — so the live toggle
            // and the "code required" UI reflect what was requested.
            if session?.requiresToken == nil { session?.requiresToken = requiresToken }
            persistSession()
            hearEnabled = false   // every party starts as a view-only request line
            seq = 0
            inbox = []
            decided = []
            lastPostedState = nil
            pickModel = makePickModel()
            startLoop()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// End the session: the server publishes a final `ended: true` state (guest pages
    /// sign off) and this store tears down its loop. The local session clears even when
    /// the end POST fails (an unreachable server must not trap the host in a dead party).
    func end() async {
        guard let s = session, !ending else { return }
        ending = true
        defer { ending = false }
        loopTask?.cancel()
        loopTask = nil
        do { try await client.end(s) } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        session = nil
        inbox = []
        pickModel = nil
        persistSession()
    }

    /// Flip timeless mode on the live session (server-confirmed, then merged locally so
    /// the expiry row updates). Errors land on `lastError`; the local flag stays as the
    /// server last confirmed it.
    func setTimeless(_ on: Bool) async {
        guard let s = session else { return }
        do {
            let life = try await client.configure(s, timeless: on)
            session?.timeless = life.timeless ?? on
            session?.expiresAt = life.expiresAt
            persistSession()
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Flip whether the live session requires a per-session guest access token.
    ///
    /// #TOUPDATE: this only updates local state today — flipping the token on a live session
    /// means the server must mint (or revoke) the guest token and re-publish the guest page +
    /// state.json, which jukebox-server.mjs does not do yet. When it does, wire this to a
    /// `client.configure`-style `/config` call (carrying the current `timeless` so it isn't
    /// clobbered) and merge the server-confirmed value, exactly like `setTimeless`.
    func setRequiresToken(_ on: Bool) {
        guard session != nil else { return }
        session?.requiresToken = on
        persistSession()
    }

    private func persistSession() {
        if let session, let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: Self.sessionKey)
        } else {
            defaults.removeObject(forKey: Self.sessionKey)
        }
    }

    // MARK: - The session loop (state up, requests down)

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    /// One loop turn — also the test seam (tests drive ticks directly, no timers).
    func tick() async {
        guard let s = session else { return }
        drainPendingMixInserts()   // broadcast requests whose rip+burn just landed
        // State snapshot: post on CHANGE (a new track, a queue edit, pause freezing the
        // position) plus a 15 s heartbeat so guests' pages can trust `updatedAt`.
        let snap = stateSnapshot()
        let now = Date().timeIntervalSince1970
        if snap != lastPostedState || now - lastStatePostAt > 15 {
            do {
                try await client.postState(s, payload: snap)
                lastPostedState = snap
                lastStatePostAt = now
                lastError = nil
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        // New guest requests → the inbox, each matched as it arrives.
        do {
            let page = try await client.requests(s, since: seq)
            seq = max(seq, page.seq)
            for r in page.requests where r.status == "pending" {
                guard !decided.contains(r.id), !inbox.contains(where: { $0.request.id == r.id }) else { continue }
                inbox.append(InboxItem(request: r, match: nil))
                Task { await self.matchRequest(r.id) }
            }
        } catch JukeboxClient.ClientError.http(let code) where code == 404 || code == 410 {
            // The server expired (24 h lifecycle) or deleted this session — fold the
            // tent locally so the tab returns to "Start a jukebox" instead of erroring
            // every 4 s at a party that's already over.
            loopTask?.cancel()
            loopTask = nil
            session = nil
            inbox = []
            pickModel = nil
            persistSession()
            lastError = "This jukebox has ended."
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Compose the guests' view of the player, by who OWNS the audio (the
    /// NowPlayingPanel visibility doctrine): a running/auto Mix first (BROADCAST mode —
    /// the on-air deck + the auto queue's tail), then the app-scoped sequencer, then a
    /// standalone single-row play — so the page never lies silent while music plays.
    func stateSnapshot() -> JukeboxStatePayload {
        if mix.isRunning || mix.autoMixing, let onAir = mix.onAirTrack {
            let lengthMs = app.songsById[onAir.songId]?.length
            return JukeboxStatePayload(
                hear: hearEnabled,
                nowPlaying: .init(title: onAir.title, artist: onAir.artist,
                                  lengthMs: lengthMs, positionMs: nil,
                                  streamUrl: hearStreamURL(forSong: onAir.songId)),
                upNext: mix.autoUpcoming.map { .init(title: $0.title, artist: $0.artist) })
        }
        if sequencer.isRunning, sequencer.index < sequencer.queue.count {
            let it = sequencer.queue[sequencer.index]
            let am = coordinator.isAppleMusicNowPlaying(it.id)
            let seconds = am ? coordinator.appleMusic.positionSeconds : player.currentTime
            return JukeboxStatePayload(
                hear: hearEnabled,
                nowPlaying: .init(title: it.title, artist: it.artist,
                                  lengthMs: it.lengthMs, positionMs: Int(seconds * 1000),
                                  streamUrl: hearStreamURL(forSong: it.id)),
                upNext: sequencer.upcoming.map { .init(title: $0.title, artist: $0.artist) })
        }
        if let np = rips.nowPlaying {
            return JukeboxStatePayload(
                hear: hearEnabled,
                nowPlaying: .init(title: np.title, artist: np.artist, lengthMs: nil,
                                  positionMs: Int(player.currentTime * 1000),
                                  streamUrl: hearStreamURL(forSong: np.songId)),
                upNext: [])
        }
        return JukeboxStatePayload(hear: hearEnabled, nowPlaying: nil, upNext: [])
    }

    /// View + Hear: the current track's PUBLIC S3 rip mp3 (the rips-bucket manifest),
    /// nil in view-only mode or when no durable public rip exists. ONLY rips-bucket
    /// audio ever leaves the building — never a MusicKit stream, never a local file
    /// URL. An Apple Music track's stream-through-rip lands in the manifest mid-play,
    /// so a later snapshot picks it up automatically.
    private func hearStreamURL(forSong songId: String) -> String? {
        guard hearEnabled else { return nil }
        return RipsStore.cachedURL(songId, manifest: rips.manifest,
                                   ripsBase: Config.ripsBase)?.absoluteString
    }

    private func matchRequest(_ requestId: String) async {
        guard let idx = inbox.firstIndex(where: { $0.request.id == requestId }) else { return }
        let r = inbox[idx].request
        let matcher = JukeboxMatcher(model: pickModel, searchAppleMusic: searchAppleMusic)
        let match = await matcher.match(title: r.title, artist: r.artist, app: app)
        // Re-find — the inbox may have shifted (another decision) while matching ran.
        if let i = inbox.firstIndex(where: { $0.request.id == requestId }) {
            inbox[i].match = match
        }
    }

    // MARK: - Host decisions

    func deny(_ item: InboxItem) {
        resolve(item, action: .denied)
    }

    /// Accept `item` into the queue at `placement` (.next / .end / .random). The SETLIST
    /// is the shared concept: during a BROADCAST (auto-mix running) the request joins the
    /// Mix's auto queue — never displacing what a deck already committed to (in-mix
    /// actions take precedence); otherwise it joins the app-scoped sequencer, and when
    /// nothing is running at all, the accepted request STARTS the radio. The decision
    /// posts fire-and-forget — the queue edit is the user-visible truth, and the
    /// server-side status flip is best-effort cosmetics.
    func accept(_ item: InboxItem, placement: JukeboxDecisionAction) {
        guard placement != .denied, let match = item.match else { return }
        if mix.autoMixing {
            acceptIntoMix(match, placement: placement)
            resolve(item, action: placement)
            return
        }
        let queueItem: SetlistPlayer.Item
        switch match {
        case .catalog(let song):
            queueItem = SetlistPlayer.Item(id: song.id, title: song.name,
                                           artist: song.artist, lengthMs: song.length)
        case .appleMusic(let storeID, let title, let artist):
            // Apple-Music-only match: the namespaced id streams via MusicKit through the
            // normal provider chain (PlaybackCoordinator resolves `am:` ids directly).
            queueItem = SetlistPlayer.Item(id: AppleMusicCatalog.namespacedSongID(storeID),
                                           title: title, artist: artist)
        case .none:
            return
        }
        if sequencer.isRunning {
            placeInSequencer(queueItem, placement: placement)
        } else {
            sequencer.play([queueItem])
        }
        resolve(item, action: placement)
    }

    private func placeInSequencer(_ queueItem: SetlistPlayer.Item, placement: JukeboxDecisionAction) {
        switch placement {
        case .next:   sequencer.insertNextInQueue([queueItem])
        case .end:    sequencer.appendToQueue([queueItem])
        case .random: sequencer.insertRandomInQueue([queueItem])
        case .denied: break
        }
    }

    /// BROADCAST accept: a Mix deck can only load a BURNED (or studio) file, so a
    /// burned match inserts into the auto queue immediately; anything else kicks the
    /// existing rip+burn pipeline and parks a pending insert that lands when the file
    /// does. An Apple-Music-only match burns under its `amrec_<storeID>` ad-hoc id —
    /// the same id the recognizer's ＋ flow rips with.
    private func acceptIntoMix(_ match: JukeboxMatch, placement: JukeboxDecisionAction) {
        let loadable: MixLoadable
        let appleMusicId: String?
        switch match {
        case .catalog(let song):
            loadable = MixLoadable(songId: song.id, title: song.name, artist: song.artist,
                                   bpm: song.bpm, camelot: song.camelot, key: song.key,
                                   albumId: song.albumId, lengthMs: song.length)
            appleMusicId = song.appleMusicId
        case .appleMusic(let storeID, let title, let artist):
            loadable = MixLoadable(songId: AppleMusicRecognition.burnSongID(catalogSongID: nil, storeID: storeID),
                                   title: title, artist: artist,
                                   bpm: nil, camelot: nil, key: nil, albumId: nil, lengthMs: nil)
            appleMusicId = storeID
        case .none:
            return
        }
        let durationMs = loadable.lengthMs ?? PocketFitter.fallbackLengthMs
        if burns.localURLForPlayback(forSong: loadable.songId) != nil {
            mix.autoQueueInsert(.init(loadable: loadable, durationMs: durationMs), placement: placement)
        } else {
            burns.startRipAndBurn(songId: loadable.songId, title: loadable.title,
                                  artist: loadable.artist, appleMusicId: appleMusicId,
                                  lengthMs: loadable.lengthMs)
            pendingMixInserts.append(.init(songId: loadable.songId, loadable: loadable,
                                           durationMs: durationMs, placement: placement,
                                           deadline: Date().timeIntervalSince1970 + 15 * 60))
        }
    }

    /// Land parked broadcast inserts whose burn finished (loop tick). If the mix ended
    /// while the burn ran, a running sequencer inherits the request; with nothing on
    /// air the insert is let go — a dead party doesn't need a queue.
    private func drainPendingMixInserts() {
        guard !pendingMixInserts.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        var still: [PendingMixInsert] = []
        for p in pendingMixInserts {
            if now > p.deadline { continue }
            guard burns.localURLForPlayback(forSong: p.songId) != nil else {
                still.append(p)
                continue
            }
            if mix.autoMixing {
                mix.autoQueueInsert(.init(loadable: p.loadable, durationMs: p.durationMs),
                                    placement: p.placement)
            } else if sequencer.isRunning {
                placeInSequencer(SetlistPlayer.Item(id: p.songId, title: p.loadable.title,
                                                    artist: p.loadable.artist,
                                                    lengthMs: p.loadable.lengthMs),
                                 placement: p.placement)
            }
            // else: nothing on air — drop it.
        }
        pendingMixInserts = still
    }

    private func resolve(_ item: InboxItem, action: JukeboxDecisionAction) {
        decided.insert(item.request.id)
        inbox.removeAll { $0.request.id == item.request.id }
        guard let s = session else { return }
        Task { try? await client.decide(s, requestId: item.request.id, action: action) }
    }
}
