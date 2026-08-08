import Foundation
import Observation

/// APP-SCOPED Music with Friends engine — the turn-based suggestion game riding the
/// SAME jukebox broker (`SettingsStore.jukeboxServerURL`/`jukeboxToken`, `/mwf/...`
/// routes). Holds the persisted session list (leader + joined, one shape), the deep-link
/// signals RootView consumes, the leader's match+decide pipeline, and the session-
/// collection download. Polling is the source of truth (the session screen owns a 4 s
/// poll); pushes only make it feel instant.
@MainActor
@Observable
final class MusicWithFriendsStore {

    /// Leader + joined sessions, newest first (UserDefaults `pdj.mwf.sessions.v1`).
    private(set) var sessions: [MwFSessionEntry] = []
    /// Set when a link/push wants a session OPEN — RootView consumes (atomic take).
    var pendingOpenId: String?
    /// A link arrived for an UNKNOWN session — drives the Join sheet.
    var pendingJoin: MwFLink?
    private(set) var creating = false
    private(set) var joining = false
    /// The last LEADER-VERB error (approve/reject/+1/config/end) PER SESSION — the session
    /// screen's banner, keyed by session id (like `lastState`) so one session's failure can
    /// never render inside another session's screen (two macOS windows on different
    /// sessions must not both paint it). `create`/`join` deliberately do NOT write here:
    /// they RETURN their error so a sheet renders its OWN message, and the 4 s poll (which
    /// runs in every open window) can neither clear a sheet's error nor be mistaken for one.
    private(set) var lastErrors: [String: String] = [:]
    /// The 4 s poll's own error, kept apart from every user-initiated verb's surface — and
    /// keyed PER SESSION for the same reason `lastErrors` is: the session screen renders it,
    /// and every open window polls its own session, so a store-global field would paint
    /// session A's unreachable-broker banner inside session B's screen.
    private(set) var pollErrors: [String: String] = [:]
    /// Last-known state per session (the session screen's render source + the
    /// final-score fallback when the ended state is never observed).
    private(set) var lastState: [String: MwFState] = [:]
    /// Sessions whose final score already hit the scoreboard (`pdj.mwf.scored.v1`).
    private var scoredSessionIds: Set<String> = []
    /// Leader nicety: accepted songs with a playable match also queue on the app-scoped
    /// sequencer (the jukebox accept path — one audio owner, unchanged).
    var queueAccepted = false {
        didSet {
            guard queueAccepted != oldValue else { return }
            defaults.set(queueAccepted, forKey: Self.queueAcceptedKey)
        }
    }

    // Seams (wired in App.init; stubbed in tests).
    @ObservationIgnored var settings: SettingsStore?
    @ObservationIgnored var urlSession: URLSession = .shared
    @ObservationIgnored var profileIdProvider: (() -> String)?
    /// The join/create sheets' display-name default (`ProfileStore.name`).
    @ObservationIgnored var profileNameProvider: (() -> String)?
    /// Leader-side matching — the SAME closures as the jukebox host engine.
    @ObservationIgnored var makePickModel: @MainActor () -> (any JukeboxPickModel)? = {
        JukeboxPickModelFactory.make()
    }
    @ObservationIgnored var searchAppleMusic: (@MainActor (String) async -> [StreamingTrack])?
    @ObservationIgnored var push: PushRegistrationService?
    @ObservationIgnored var scoreboard: GameScoreboardStore?
    @ObservationIgnored var collectionsStore: CollectionsStore?
    @ObservationIgnored var appModel: AppModel?
    @ObservationIgnored var sequencer: SetlistPlayer?
    /// Stable per-install client id (server-side pacing + correlation only — the broker
    /// refuses it as proof of identity, see `MwFJoinSecret`).
    @ObservationIgnored var deviceClientId: () -> String = { DeviceIdentity.current }
    /// Per-install RE-JOIN credential (never broadcast on any other call).
    @ObservationIgnored var joinSecret: () -> String = { MwFJoinSecret.current }

    private let defaults: UserDefaults
    private static let sessionsKey = "pdj.mwf.sessions.v1"
    private static let scoredKey = "pdj.mwf.scored.v1"
    private static let queueAcceptedKey = "pdj.mwf.queueAccepted.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var client: MwFClient {
        MwFClient(baseURL: settings?.jukeboxServerURL ?? "",
                  token: settings?.jukeboxToken ?? "",
                  profileId: profileIdProvider?() ?? "",
                  session: urlSession)
    }

    func entry(_ id: String) -> MwFSessionEntry? { sessions.first { $0.id == id } }

    // MARK: - Persistence

    /// Load the persisted session list + scored set (call once from App.init).
    func loadPersisted() {
        if let data = defaults.data(forKey: Self.sessionsKey),
           let list = try? JSONDecoder().decode([MwFSessionEntry].self, from: data) {
            sessions = list
        }
        if let scored = defaults.stringArray(forKey: Self.scoredKey) {
            scoredSessionIds = Set(scored)
        }
        queueAccepted = defaults.bool(forKey: Self.queueAcceptedKey)
    }

    private func persistSessions() {
        if let data = try? JSONEncoder().encode(sessions) { defaults.set(data, forKey: Self.sessionsKey) }
    }

    private func persistScored() {
        defaults.set(Array(scoredSessionIds), forKey: Self.scoredKey)
    }

    /// Account-deletion seam: forget EVERY Music-with-Friends trace this store owns — the
    /// session entries (which hold bearer memberKeys/leaderKeys), the scored-session set,
    /// the queue-accepted preference, the cached states, and any pending link signals —
    /// including the persisted UserDefaults copies. The per-install re-join secret is reset
    /// separately (`MwFJoinSecret.reset()`, beside the other identity resets).
    func eraseAll() {
        sessions = []
        lastState = [:]
        scoredSessionIds = []
        pendingOpenId = nil
        pendingJoin = nil
        lastErrors = [:]
        pollErrors = [:]
        queueAccepted = false
        defaults.removeObject(forKey: Self.sessionsKey)
        defaults.removeObject(forKey: Self.scoredKey)
        defaults.removeObject(forKey: Self.queueAcceptedKey)
    }

    // MARK: - Create / join / open

    /// Create a session. Returns the error to show (nil = success) — the CALLER owns the
    /// message, so a concurrent poll in another window can never clear or forge it.
    @discardableResult
    func create(name: String, theme: String, displayName: String, settings s: MwFSettings) async -> String? {
        guard !creating else { return "A session is already being created." }
        creating = true
        defer { creating = false }
        do {
            let r = try await client.create(name: name, theme: theme, leaderName: displayName,
                                            clientId: deviceClientId(), joinSecret: joinSecret(),
                                            settings: s)
            guard let sid = r.sessionId, let mid = r.memberId, let mk = r.memberKey else {
                return "The server's create reply was incomplete."
            }
            let entry = MwFSessionEntry(id: sid, memberId: mid, memberKey: mk,
                                        leaderKey: r.leaderKey, name: r.name ?? name,
                                        theme: r.theme ?? theme, url: r.url, apiBase: nil,
                                        expiresAt: r.expiresAt, pocketId: nil,
                                        joinedAt: Date().timeIntervalSince1970 * 1000)
            sessions.removeAll { $0.id == sid }
            sessions.insert(entry, at: 0)
            persistSessions()
            pendingOpenId = sid
            await registerPushIfPossible(for: entry)
            return nil
        } catch JukeboxClient.ClientError.http(let code) where code == 404 {
            return await mwfUnavailableMessage(base: nil)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// A raw 404 from `/mwf` usually means the live broker predates v3 (no `/mwf` routes
    /// at all — the deploy ordering between an app update and the iMac broker restart is
    /// enforced by nothing). Probe `/health` (the capability flag exists for exactly this,
    /// like the v2 played-history rollout) and turn the bare "HTTP 404" into an actionable
    /// message when the server really is older.
    private func mwfUnavailableMessage(base: String?) async -> String {
        let probe = JukeboxClient(baseURL: base ?? settings?.jukeboxServerURL ?? "",
                                  token: settings?.jukeboxToken ?? "",
                                  profileId: profileIdProvider?() ?? "",
                                  session: urlSession)
        if let health = try? await probe.health(), (health.version ?? 0) < 3 || health.mwf != true {
            return "The jukebox server is running an older version without Music with Friends"
                + " — update it (scripts/update-jukeboxserver.sh on the host) and try again."
        }
        return "Music with Friends isn't available on this server (HTTP 404)."
    }

    /// A tapped `/mwf/` link: a known session opens; an unknown one drives the Join sheet.
    /// BOTH branches raise `pendingOpenId` — that is the only signal RootView watches, and
    /// the Join sheet lives on GamesView, which is in the hierarchy ONLY while the Games
    /// tab is showing. Without it, a link tapped from History (the default launch tab) set
    /// `pendingJoin` and nothing happened until the user wandered into Games. RootView's
    /// consume lands on the Games tab and skips the session push when there is no entry,
    /// which is exactly the unknown-session case.
    func handleOpenedLink(_ link: MwFLink) {
        if !sessions.contains(where: { $0.id == link.sessionId }) { pendingJoin = link }
        pendingOpenId = link.sessionId
    }

    /// Join a session. Returns the error to show (nil = success), like `create`.
    @discardableResult
    func join(link: MwFLink, name: String) async -> String? {
        guard !joining else { return "A join is already in flight." }
        joining = true
        defer { joining = false }
        if sessions.contains(where: { $0.id == link.sessionId }) {
            pendingJoin = nil
            pendingOpenId = link.sessionId
            return nil
        }
        // The public state.json carries the broker's apiBase + the theme — the same
        // no-preconfig join the jukebox guest flow uses. Best-effort: a miss falls
        // back to the configured server URL.
        var apiBase: String?
        var theme: String?
        var sessionName: String?
        if let stateURL = link.stateURL, let pub = try? await client.publicState(url: stateURL) {
            apiBase = pub.apiBase
            theme = pub.theme
            sessionName = pub.name
        }
        do {
            let r = try await client.join(apiBase: apiBase, sessionId: link.sessionId,
                                          name: name, clientId: deviceClientId(),
                                          joinSecret: joinSecret(),
                                          memberKey: entry(link.sessionId)?.memberKey)
            guard let mid = r.memberId, let mk = r.memberKey else {
                return "The server's join reply was incomplete."
            }
            let base = link.guestBase?.absoluteString ?? "https://\(MwFLink.universalHost)"
            let entry = MwFSessionEntry(id: link.sessionId, memberId: mid, memberKey: mk,
                                        leaderKey: nil, name: r.sessionName ?? sessionName,
                                        theme: r.theme ?? theme,
                                        url: "\(base)/mwf/\(link.sessionId)/", apiBase: apiBase,
                                        expiresAt: r.expiresAt, pocketId: nil,
                                        joinedAt: Date().timeIntervalSince1970 * 1000)
            sessions.insert(entry, at: 0)
            persistSessions()
            pendingJoin = nil
            pendingOpenId = link.sessionId
            await registerPushIfPossible(for: entry)
            return nil
        } catch JukeboxClient.ClientError.http(let code) where code == 404 {
            return await mwfUnavailableMessage(base: apiBase)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Polling + verbs

    /// One poll turn for the session screen. A 404/410 folds the session locally
    /// (marks the cached state ended) and records the final score ONCE.
    @discardableResult
    func refresh(_ id: String) async -> MwFState? {
        guard let entry = entry(id) else { return nil }
        do {
            let st = try await client.state(entry)
            lastState[id] = st
            if let i = sessions.firstIndex(where: { $0.id == id }) {
                var e = sessions[i]
                var changed = false
                if let n = st.name, e.name != n { e.name = n; changed = true }
                if let t = st.theme, e.theme != t { e.theme = t; changed = true }
                if let x = st.expiresAt, e.expiresAt != x { e.expiresAt = x; changed = true }
                if changed { sessions[i] = e; persistSessions() }
            }
            if st.ended == true { recordFinalScoreIfNeeded(id) }
            pollErrors[id] = nil
            return st
        } catch JukeboxClient.ClientError.http(let code) where code == 401 {
            // The broker no longer recognizes our memberKey — a session.json restored from
            // a backup that predates this member loses it server-side, and `join()`
            // early-returns for known sessions, so nothing else ever re-presents the
            // stored credentials. Recover HERE (single-flight): re-join with the stored
            // memberKey, then fall back to the joinSecret (which mints a fresh member when
            // the old one is gone), and retry the poll once.
            // `self.` is load-bearing: the `entry` constant above shadows the METHOD for the
            // whole function body, so a bare `entry(id)` would not even compile.
            if await recoverMembership(id), let rebound = self.entry(id),
               let st = try? await client.state(rebound) {
                lastState[id] = st
                if st.ended == true { recordFinalScoreIfNeeded(id) }
                pollErrors[id] = nil
                return st
            }
            pollErrors[id] = "The server no longer recognizes this device — try leaving and rejoining."
            return lastState[id]
        } catch JukeboxClient.ClientError.http(let code) where code == 404 || code == 410 {
            if lastState[id] != nil {
                lastState[id]?.ended = true
            } else {
                var st = MwFState()
                st.sessionId = id
                st.ended = true
                lastState[id] = st
            }
            recordFinalScoreIfNeeded(id)
            return lastState[id]
        } catch {
            pollErrors[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return lastState[id]
        }
    }

    /// Single-flight guard per session on the membership recovery below.
    @ObservationIgnored private var recovering: Set<String> = []

    /// Re-establish membership after the broker forgot us (a restored session.json missing
    /// this member): first PRESENT the stored memberKey (re-binds the exact member when it
    /// still exists), then fall back to the joinSecret-only join, which mints a fresh
    /// member. Either success re-binds the entry's memberId/memberKey (the leaderKey — a
    /// session-level credential — is kept as-is). Returns whether the entry was re-bound.
    func recoverMembership(_ id: String) async -> Bool {
        guard let e = entry(id), !recovering.contains(id) else { return false }
        recovering.insert(id)
        defer { recovering.remove(id) }
        let name = (profileNameProvider?() ?? "").trimmingCharacters(in: .whitespaces)
        let display = name.isEmpty ? "Player" : name
        for presented in [e.memberKey, nil] {
            guard let r = try? await client.join(apiBase: e.apiBase, sessionId: id,
                                                 name: display, clientId: deviceClientId(),
                                                 joinSecret: joinSecret(), memberKey: presented),
                  let mid = r.memberId, let mk = r.memberKey else { continue }
            if let i = sessions.firstIndex(where: { $0.id == id }) {
                sessions[i].memberId = mid
                sessions[i].memberKey = mk
                persistSessions()
            }
            return true
        }
        return false
    }

    /// Suggest a song. THROWS so the screen can surface the server's turn rejection
    /// (409 "not your turn") gracefully.
    func suggest(_ id: String, title: String, artist: String) async throws {
        guard let entry = entry(id) else { return }
        _ = try await client.suggest(entry, title: title, artist: artist)
        _ = await refresh(id)
    }

    func plusOne(_ id: String, suggestionId: String) async {
        guard let entry = entry(id) else { return }
        lastErrors[id] = nil
        do {
            try await client.plusOne(entry, suggestionId: suggestionId)
            _ = await refresh(id)
        } catch {
            lastErrors[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Leader verbs

    /// Accept a suggestion: run the jukebox matcher first so the decision carries a
    /// playable match (catalog id → appleMusicId → title/artist-only), then decide.
    func approve(_ id: String, suggestion: MwFSuggestion) async {
        guard let entry = entry(id), entry.isLeader, let sgId = suggestion.id else { return }
        lastErrors[id] = nil
        let title = suggestion.title ?? ""
        let artist = suggestion.artist ?? ""
        var match = MwFMatch(songId: nil, appleMusicId: nil, title: title, artist: artist, lengthMs: nil)
        if let appModel {
            let matcher = JukeboxMatcher(model: makePickModel(), searchAppleMusic: searchAppleMusic)
            switch await matcher.match(title: title, artist: artist, app: appModel) {
            case .catalog(let song):
                match = MwFMatch(songId: song.id, appleMusicId: song.appleMusicId,
                                 title: song.name, artist: song.artist, lengthMs: song.length)
            case .appleMusic(let storeID, let t, let a):
                match = MwFMatch(songId: nil, appleMusicId: storeID, title: t, artist: a, lengthMs: nil)
            case .none:
                break
            }
        }
        do {
            try await client.decide(entry, suggestionId: sgId, action: "accepted", match: match)
            if queueAccepted { queueMatchIfPlayable(match) }
            _ = await refresh(id)
        } catch {
            lastErrors[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func reject(_ id: String, suggestion: MwFSuggestion) async {
        guard let entry = entry(id), entry.isLeader, let sgId = suggestion.id else { return }
        lastErrors[id] = nil
        do {
            try await client.decide(entry, suggestionId: sgId, action: "rejected", match: nil)
            _ = await refresh(id)
        } catch {
            lastErrors[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func updateSettings(_ id: String, _ s: MwFSettings) async {
        guard let entry = entry(id), entry.isLeader else { return }
        lastErrors[id] = nil
        do {
            let confirmed = try await client.configure(entry, settings: s)
            if lastState[id] != nil { lastState[id]?.settings = confirmed }
        } catch {
            lastErrors[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func endSession(_ id: String) async {
        guard let entry = entry(id), entry.isLeader else { return }
        lastErrors[id] = nil
        do { try await client.end(entry) } catch {
            lastErrors[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        // Local fold regardless — an unreachable broker must not trap the leader.
        if lastState[id] != nil { lastState[id]?.ended = true }
        recordFinalScoreIfNeeded(id)
    }

    // MARK: - Scores

    /// The local user's derived score in a state payload.
    func myScore(_ state: MwFState) -> Int {
        let you = state.you?.memberId
            ?? sessions.first { $0.id == state.sessionId }?.memberId
        return state.score(of: you)
    }

    /// Record the local user's final score to the scoreboard ONCE per session —
    /// only once the session is over (ended observed, or the entry aged past its
    /// expiry; the last-known cached state stands in when the ended state was
    /// never observed).
    func recordFinalScoreIfNeeded(_ id: String) {
        guard !scoredSessionIds.contains(id), let entry = entry(id) else { return }
        let st = lastState[id]
        let expired = entry.expiresAt.map { Date().timeIntervalSince1970 * 1000 > $0 } ?? false
        guard st?.ended == true || expired else { return }
        let theme = st?.theme ?? entry.theme
        var detail = ["sessionId": id]
        if let theme { detail["theme"] = theme }
        scoreboard?.record(game: .musicWithFriends,
                           score: st.map { myScore($0) } ?? 0,
                           settingsSummary: theme.map { String($0.prefix(60)) },
                           detail: detail)
        scoredSessionIds.insert(id)
        persistScored()
    }

    /// Leave a session LOCALLY (server membership persists; the departed member's
    /// turns simply time out — documented v1 limitation).
    func leave(_ id: String) {
        recordFinalScoreIfNeeded(id)
        sessions.removeAll { $0.id == id }
        persistSessions()
        lastState[id] = nil
        lastErrors[id] = nil
        pollErrors[id] = nil
    }

    // MARK: - Push

    /// Ask notification permission IN CONTEXT (right after create/join) and register
    /// the device token with the broker. Polling covers everything when this fails.
    func registerPushIfPossible(for entry: MwFSessionEntry) async {
        guard let push, push.isSupported else { return }
        if push.deviceTokenHex == nil {
            _ = await push.requestAndRegister()
        }
        // The token often arrives asynchronously — updateDeviceToken re-registers then.
        guard let hex = push.deviceTokenHex else { return }
        try? await client.registerDevice(entry, platform: push.platformString, token: hex)
    }

    /// Account-deletion counterpart of `registerPushIfPossible`: withdraw this device's APNs
    /// token from EVERY session it was registered with, while the memberKeys that authorize
    /// the call still exist (`eraseAll()` destroys them a moment later). Best-effort and
    /// bounded — every call carries a 6 s timeout and they run concurrently, so an
    /// unreachable broker costs the deletion one timeout, not one per session. A failure is
    /// survivable (the registration dies with the session's 24 h TTL); silently keeping a
    /// live token on someone else's broker after "delete everything" is not.
    func unregisterPushEverywhere() async {
        let live = sessions.filter { !$0.memberKey.isEmpty }
        guard !live.isEmpty else { return }
        // MainActor-inheriting Tasks (like `updateDeviceToken`) — started together, awaited
        // together, no value crosses an isolation boundary.
        let inFlight = live.map { entry in
            Task { try? await self.client.unregisterDevice(entry) }
        }
        for task in inFlight { _ = await task.value }
    }

    /// Token rotation / late arrival: re-register on every live session (fire-and-forget).
    func updateDeviceToken(_ hex: String) {
        guard let push else { return }
        for entry in sessions where lastState[entry.id]?.ended != true {
            Task { try? await client.registerDevice(entry, platform: push.platformString, token: hex) }
        }
    }

    // MARK: - Queue-accepted (leader nicety — global playback session reuse)

    /// Internal (not private) so a test can drive it synchronously — the sequencer tears a
    /// non-playable queue down on its next runloop turn, which an `await` would allow.
    func queueMatchIfPlayable(_ match: MwFMatch) {
        guard let sequencer else { return }
        let item: SetlistPlayer.Item
        if let songId = match.songId {
            item = SetlistPlayer.Item(id: songId, title: match.title ?? "",
                                      artist: match.artist ?? "", lengthMs: match.lengthMs)
        } else if let storeID = match.appleMusicId {
            item = SetlistPlayer.Item(id: AppleMusicCatalog.namespacedSongID(storeID),
                                      title: match.title ?? "", artist: match.artist ?? "")
        } else {
            return
        }
        // NEVER append into a live Collectors Puzzle round: the engine maps its queue
        // index onto the sequencer's, so a foreign append desynchronizes the decision log
        // (the round is a scored, timed run — the accept simply doesn't auto-queue).
        if sequencer.sourceSetlistId?.hasPrefix(CollectorsPuzzleEngine.runTagPrefix) == true { return }
        if sequencer.isRunning {
            sequencer.appendToQueue([item])
        } else {
            sequencer.play([item])
        }
    }

    // MARK: - Collection download

    /// Materialize the session collection as a local pocket (idempotent: the pocket id
    /// persists on the entry; re-downloads only add missing members). Unresolved
    /// entries become provisional "Imported" songs (the DiscoverAdds doctrine —
    /// superseded later when a real index row lands under the same appleMusicId).
    /// Returns the pocket id.
    @discardableResult
    func downloadCollection(_ id: String, state: MwFState) async -> String? {
        guard let collectionsStore, let appModel else { return nil }
        let entries = state.collection ?? []
        guard !entries.isEmpty else { return nil }
        var memberIds: [String] = []
        var payload = PortableItems.Payload()
        for e in entries {
            if let sid = e.songId, appModel.songsById[sid] != nil {
                memberIds.append(sid)
            } else if let am = e.appleMusicId, let sid = appModel.songId(forAppleMusicId: am) {
                memberIds.append(sid)
            } else {
                let pid = e.songId ?? "mwf_" + Self.stableHash(e)
                memberIds.append(pid)
                payload.songs.append(PortableItems.Song(
                    id: pid, name: e.title ?? "Unknown", artist: e.artist ?? "",
                    albumId: nil, trackNumber: nil, year: nil, lengthMs: e.lengthMs,
                    bpm: nil, key: nil, camelot: nil, appleMusicId: e.appleMusicId))
            }
        }
        if !payload.isEmpty { collectionsStore.materializePortableItems(payload) }
        if let i = sessions.firstIndex(where: { $0.id == id }),
           let pocketId = sessions[i].pocketId, collectionsStore.pocket(pocketId) != nil {
            for sid in memberIds { collectionsStore.addSong(sid, toPocket: pocketId) }
            return pocketId
        }
        let pocket = collectionsStore.createPocket("MwF — \(state.name ?? "Session")",
                                                   songIds: memberIds,
                                                   description: state.theme)
        if let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].pocketId = pocket.id
            persistSessions()
        }
        return pocket.id
    }

    /// Deterministic provisional id for an entry with no songId (FNV-1a of its identity).
    nonisolated static func stableHash(_ e: MwFCollectionEntry) -> String {
        String(format: "%08x",
               PRNG.fnv1a("\(e.title ?? "")|\(e.artist ?? "")|\(e.appleMusicId ?? "")"))
    }
}
