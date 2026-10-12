import XCTest
@testable import PocketDJ

/// ListeningPocketsService — the privacy gate (zero requests while off), the wire contract
/// (headers + the §5.1 body: minute-floored `atMs` + `ord`, outcome strings, ctx only on local
/// events), fingerprint idempotency (unchanged ⇒ not re-sent; a later skip/ctx ⇒ re-sent), the
/// silent 404, the lazy settle pass (`.pending` stays untagged), and the delete cascade.
@MainActor
final class ListeningPocketsServiceTests: XCTestCase {

    // MARK: - Fakes

    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var status = 200
        var body = Data(#"{"ok":true}"#.utf8)
        var statusByMethod: [String: Int] = [:]

        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
        func posts() -> [URLRequest] { requests.filter { $0.httpMethod == "POST" } }
        func record(_ req: URLRequest) -> (Data, URLResponse) {
            lock.lock(); _requests.append(req)
            let code = statusByMethod[req.httpMethod ?? ""] ?? status
            lock.unlock()
            return (body, HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
        /// The decoded body of a POST.
        static func json(_ req: URLRequest) -> [String: Any] {
            guard let data = req.httpBody,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return obj
        }
        static func events(_ req: URLRequest) -> [[String: Any]] {
            (json(req)["events"] as? [[String: Any]]) ?? []
        }
    }

    @MainActor
    private final class StubProvider: ListeningContextProviding {
        var isSupported = true
        var isActive = true
        var revision = 0
        var lookup: (Date) -> ListeningContextLookup = { _ in .unavailable }
        var places: [ListeningPlaceLabel] = []
        var trips: [ListeningTripLabel] = []
        func context(at date: Date) -> ListeningContextLookup { lookup(date) }
        func placeLabels() -> [ListeningPlaceLabel] { places }
        func tripLabels() -> [ListeningTripLabel] { trips }
        func label(for tag: ListeningContextTag) -> String? { nil }
    }

    private struct Env {
        let svc: ListeningPocketsService
        let spy: Spy
        let history: PlayHistoryStore
        let settings: SettingsStore
        let provider: StubProvider
        let syncURL: URL
        let cacheURL: URL
    }

    private static let key = "k-bearer"
    private static let profile = String(repeating: "ab", count: 32)
    /// 2026-10-12T12:00:00Z — every test runs on this fixed clock.
    private static let nowMs = 1_791_806_400_000.0

    private func tempURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-pockets-\(name)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeEnv(recOn: Bool = true, pocketsOn: Bool = true, locationOn: Bool = true) -> Env {
        let suite = "pdj.pockets.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults)
        settings.recEngineEnabled = recOn
        settings.listeningPocketsEnabled = pocketsOn
        let history = PlayHistoryStore(fileURL: tempURL("history"))
        let spy = Spy()
        let provider = StubProvider()
        provider.isActive = locationOn
        let client = ListeningPocketsClient(base: URL(string: "https://pockets.test")!,
                                            enrollSecret: "enroll-secret",
                                            transport: { spy.record($0) })
        let syncURL = tempURL("sync"), cacheURL = tempURL("cache")
        // Credentials are handed out regardless of the toggles here — the gate under test is the
        // service's OWN (the real `sharedCredentials` is nil while the engine is off as well).
        let svc = ListeningPocketsService(
            history: history, settings: settings,
            credentials: { (Self.key, Self.profile) },
            provider: provider, client: client,
            now: { Date(timeIntervalSince1970: Self.nowMs / 1000) },
            syncFileURL: syncURL, cacheFileURL: cacheURL)
        svc.fixtureForTesting = false
        svc.deviceIdProvider = { "DEVICE-1" }
        return Env(svc: svc, spy: spy, history: history, settings: settings, provider: provider,
                   syncURL: syncURL, cacheURL: cacheURL)
    }

    @discardableResult
    private func play(_ env: Env, _ song: String, minutesAgo: Double, seconds: Double = 0,
                      origin: String?? = .none) -> PlayHistoryStore.PlayEvent {
        let at = Self.nowMs - minutesAgo * 60_000 + seconds * 1000
        var ev = PlayHistoryStore.PlayEvent(
            id: UUID(), songId: song, playedAt: at, source: .mix, contextId: nil, contextName: nil,
            title: nil, artist: "Artist \(song)",
            originInstallId: origin ?? env.history.installId)
        ev.tzOffsetMin = -420
        env.history.replaceAll(env.history.events + [ev])
        return ev
    }

    // MARK: - The privacy gate

    func testDisabledMakesZeroRequests() async {
        for (rec, pockets) in [(false, true), (true, false), (false, false)] {
            let env = makeEnv(recOn: rec, pocketsOn: pockets)
            play(env, "sng_1", minutesAgo: 10)
            XCTAssertFalse(env.svc.isEnabled)
            let sent = await env.svc.flushNow()
            await env.svc.refreshResults(force: true)
            await env.svc.refreshNow()
            env.svc.flushSoon()
            env.svc.startAutoFlush()
            XCTAssertFalse(sent)
            XCTAssertFalse(env.svc.isAutoFlushArmed)
            XCTAssertTrue(env.spy.requests.isEmpty, "rec=\(rec) pockets=\(pockets) must send NOTHING")
        }
    }

    // MARK: - Wire contract

    func testHeadersBearerScopedProfileAndEnrollOnPostOnly() async throws {
        let env = makeEnv()
        play(env, "sng_1", minutesAgo: 10)
        let sent = await env.svc.flushNow()
        XCTAssertTrue(sent)
        let post = try XCTUnwrap(env.spy.posts().first)
        XCTAssertEqual(post.url?.path, "/pockets/events")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.key)")
        XCTAssertEqual(post.value(forHTTPHeaderField: "X-PocketDJ-Profile"), Self.profile)
        XCTAssertEqual(post.value(forHTTPHeaderField: "X-PocketDJ-Enroll"), "enroll-secret")
        XCTAssertNotNil(post.value(forHTTPHeaderField: "X-PocketDJ-Device"))
        // The post-flush results fetch: GET, bearer, no enroll secret.
        let get = try XCTUnwrap(env.spy.requests.first { $0.httpMethod == "GET" })
        XCTAssertEqual(get.url?.path, "/pockets/results")
        XCTAssertEqual(get.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.key)")
        XCTAssertEqual(get.value(forHTTPHeaderField: "X-PocketDJ-Profile"), Self.profile)
        XCTAssertNil(get.value(forHTTPHeaderField: "X-PocketDJ-Enroll"))
    }

    func testBodyMatchesUploadV1() async throws {
        let env = makeEnv()
        // Two plays in the SAME minute (ord 0, 1), one skipped; a completed one; a peer's play
        // carrying a ctx that must NOT be uploaded; a play outside the 90-day window.
        let a = play(env, "sng_a", minutesAgo: 30, seconds: 5)
        let b = play(env, "sng_b", minutesAgo: 30, seconds: 40)
        env.history.markSkipped(eventId: b.id)
        env.history.noteListened(eventId: b.id, fraction: 0.12)
        let c = play(env, "sng_c", minutesAgo: 20)
        env.history.noteListened(eventId: c.id, fraction: 0.96)
        var peer = play(env, "sng_p", minutesAgo: 10, origin: .some("PEER-INSTALL"))
        peer.listeningContext = .place("plc_0f1e2d3c4b5a6978")
        env.history.replaceAll(env.history.events.map { $0.id == peer.id ? peer : $0 })
        play(env, "sng_old", minutesAgo: 91 * 24 * 60)

        await env.svc.flushNow()
        let post = try XCTUnwrap(env.spy.posts().first)
        let body = Spy.json(post)
        XCTAssertEqual(body["v"] as? Int, 1)
        XCTAssertEqual(body["installId"] as? String, env.history.installId)
        XCTAssertEqual(body["deviceId"] as? String, "DEVICE-1")
        XCTAssertNotNil(body["sentAtMs"])
        let events = Spy.events(post)
        XCTAssertEqual(events.map { $0["songId"] as? String }, ["sng_a", "sng_b", "sng_c", "sng_p"],
                       "oldest first; the out-of-window play is not uploaded")
        let minute = ListeningPocketsService.flooredMinute(a.playedAt)
        XCTAssertEqual(minute % 60_000, 0)
        XCTAssertEqual((events[0]["atMs"] as? NSNumber)?.int64Value, minute)
        XCTAssertEqual((events[1]["atMs"] as? NSNumber)?.int64Value, minute)
        XCTAssertEqual(events[0]["ord"] as? Int, 0)
        XCTAssertEqual(events[1]["ord"] as? Int, 1, "same minute + stream ⇒ ord restores the order")
        XCTAssertEqual(events[2]["ord"] as? Int, 0)
        XCTAssertEqual(events[0]["id"] as? String, a.id.uuidString)
        XCTAssertEqual(events[0]["outcome"] as? String, "unknown")
        XCTAssertEqual(events[1]["outcome"] as? String, "skipped")
        XCTAssertEqual(events[1]["fraction"] as? Double, 0.12)
        XCTAssertEqual(events[2]["outcome"] as? String, "completed")
        XCTAssertEqual(events[0]["tzOffsetMin"] as? Int, -420)
        XCTAssertEqual(events[0]["source"] as? String, "mix")
        XCTAssertEqual(events[0]["artist"] as? String, "Artist sng_a")
        // Nullable fields are explicit nulls, not absent keys.
        XCTAssertTrue(events[0]["fraction"] is NSNull)
        XCTAssertTrue(events[0]["ctx"] is NSNull)
        XCTAssertTrue(events[0]["carPlay"] is NSNull)
        XCTAssertEqual(events[3]["originInstallId"] as? String, "PEER-INSTALL")
        XCTAssertTrue(events[3]["ctx"] is NSNull, "a peer's ctx never rides THIS device's upload")
    }

    func testCtxAndLabelsRideOnlyWhileLocationIsOn() async throws {
        let env = makeEnv(locationOn: true)
        env.provider.places = [ListeningPlaceLabel(id: "plc_0f1e2d3c4b5a6978", rank: 1,
                                                   label: "Location A", shareOfTime: 0.6234)]
        env.provider.trips = [ListeningTripLabel(id: "trp_3c9a0b1d2e4f5a6b", origin: "plc_0f1e2d3c4b5a6978",
                                                 destination: nil, label: "Leaving A", occurrences: 3)]
        let tag = ListeningContextTag.trip("trp_3c9a0b1d2e4f5a6b", origin: "plc_0f1e2d3c4b5a6978",
                                           destination: nil)
        env.provider.lookup = { _ in .settled(tag) }
        play(env, "sng_1", minutesAgo: 400)
        await env.svc.flushNow()
        let post = try XCTUnwrap(env.spy.posts().first)
        let ctx = try XCTUnwrap(Spy.events(post).first?["ctx"] as? [String: Any])
        XCTAssertEqual(ctx["kind"] as? String, "trip")
        XCTAssertEqual(ctx["tripId"] as? String, "trp_3c9a0b1d2e4f5a6b")
        XCTAssertEqual(ctx["origin"] as? String, "plc_0f1e2d3c4b5a6978")
        XCTAssertNil(ctx["destination"], "an unknown destination is omitted, never an empty id")
        let body = Spy.json(post)
        let places = try XCTUnwrap(body["places"] as? [[String: Any]])
        XCTAssertEqual(places.first?["label"] as? String, "Location A")
        XCTAssertEqual(places.first?["share"] as? Double, 0.623)
        let trips = try XCTUnwrap(body["trips"] as? [[String: Any]])
        XCTAssertTrue(trips.first?["destination"] is NSNull)

        // Location off: the same stamped play re-uploads WITHOUT ctx, and no labels ride.
        let off = makeEnv(locationOn: false)
        var ev = play(off, "sng_1", minutesAgo: 400)
        ev.listeningContext = tag
        off.history.replaceAll([ev])
        await off.svc.flushNow()
        let offPost = try XCTUnwrap(off.spy.posts().first)
        XCTAssertTrue(Spy.events(offPost).first?["ctx"] is NSNull)
        XCTAssertNil(Spy.json(offPost)["places"])
        XCTAssertNil(Spy.json(offPost)["trips"])
    }

    // MARK: - Idempotency (fingerprints)

    func testUnchangedIsNotResentAndAChangeIs() async throws {
        let env = makeEnv(locationOn: false)
        let a = play(env, "sng_a", minutesAgo: 30)
        play(env, "sng_b", minutesAgo: 20)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.posts().count, 1)
        XCTAssertEqual(env.svc.acknowledgedFingerprints.count, 2)

        // Nothing moved → a flush is zero requests.
        let before = env.spy.requests.count
        let sent = await env.svc.flushNow()
        XCTAssertFalse(sent)
        XCTAssertEqual(env.spy.requests.count, before, "a quiet flush makes no request at all")

        // The skip verdict lands later → exactly that event re-sends, with its new outcome.
        env.history.markSkipped(eventId: a.id)
        await env.svc.flushNow()
        let resend = try XCTUnwrap(env.spy.posts().last)
        let events = Spy.events(resend)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["id"] as? String, a.id.uuidString)
        XCTAssertEqual(events.first?["outcome"] as? String, "skipped")
    }

    func testFingerprintsPersistAcrossRelaunchAndResetOnProfileChange() async throws {
        let env = makeEnv(locationOn: false)
        play(env, "sng_a", minutesAgo: 30)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.posts().count, 1)
        // A relaunched service on the same files: nothing to send.
        let spy2 = Spy()
        let svc2 = ListeningPocketsService(
            history: env.history, settings: env.settings, credentials: { (Self.key, Self.profile) },
            provider: env.provider,
            client: ListeningPocketsClient(base: URL(string: "https://pockets.test")!, transport: { spy2.record($0) }),
            now: { Date(timeIntervalSince1970: Self.nowMs / 1000) },
            syncFileURL: env.syncURL, cacheFileURL: env.cacheURL)
        svc2.fixtureForTesting = false
        await svc2.flushNow()
        XCTAssertTrue(spy2.posts().isEmpty, "the acknowledged fingerprints survived the relaunch")
        // A different scoped profile (key rebind): everything re-sends.
        let spy3 = Spy()
        let svc3 = ListeningPocketsService(
            history: env.history, settings: env.settings, credentials: { (Self.key, "other-profile") },
            provider: env.provider,
            client: ListeningPocketsClient(base: URL(string: "https://pockets.test")!, transport: { spy3.record($0) }),
            now: { Date(timeIntervalSince1970: Self.nowMs / 1000) },
            syncFileURL: env.syncURL, cacheFileURL: env.cacheURL)
        svc3.fixtureForTesting = false
        await svc3.flushNow()
        XCTAssertEqual(spy3.posts().count, 1)
    }

    func testBatchesCapAtOneThousand() async throws {
        let env = makeEnv(locationOn: false)
        var evs: [PlayHistoryStore.PlayEvent] = []
        for i in 0..<1500 {
            evs.append(PlayHistoryStore.PlayEvent(
                id: UUID(), songId: "sng_\(i)", playedAt: Self.nowMs - Double(1500 - i) * 60_000,
                source: .playlist, contextId: nil, contextName: nil, title: nil, artist: nil,
                originInstallId: env.history.installId))
        }
        env.history.replaceAll(evs)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.posts().map { Spy.events($0).count }, [1000, 500])
        XCTAssertEqual(env.svc.acknowledgedFingerprints.count, 1500)
    }

    // MARK: - Failure modes

    func testNotFoundMarksServiceUnavailableSilently() async {
        let env = makeEnv()
        env.spy.status = 404
        play(env, "sng_1", minutesAgo: 10)
        let sent = await env.svc.flushNow()
        XCTAssertFalse(sent)
        XCTAssertFalse(env.svc.serviceAvailable)
        XCTAssertNil(env.svc.syncError, "a not-yet-deployed route is not a user-facing error")
        XCTAssertTrue(env.svc.acknowledgedFingerprints.isEmpty, "nothing acknowledged on a non-2xx")
        // Recovery: the next success flips it back.
        env.spy.status = 200
        await env.svc.flushNow()
        XCTAssertTrue(env.svc.serviceAvailable)
    }

    func testKeyMismatchSurfacesAnErrorAndAcksNothing() async {
        let env = makeEnv()
        env.spy.status = 403
        env.spy.body = Data(#"{"error":"key-mismatch"}"#.utf8)
        play(env, "sng_1", minutesAgo: 10)
        await env.svc.flushNow()
        XCTAssertNotNil(env.svc.syncError)
        XCTAssertTrue(env.svc.acknowledgedFingerprints.isEmpty)
    }

    // MARK: - Settle pass

    func testPendingStaysUntaggedThenSettledIsStampedAndResent() async throws {
        let env = makeEnv(locationOn: true)
        env.provider.lookup = { _ in .pending }
        let ev = play(env, "sng_1", minutesAgo: 30)
        await env.svc.flushNow()
        XCTAssertNil(env.history.events.first?.listeningContext, ".pending is never stamped")
        XCTAssertTrue(Spy.events(try XCTUnwrap(env.spy.posts().first)).first?["ctx"] is NSNull)

        // Later the trip arrives somewhere: the settle pass stamps it and the moved fingerprint re-sends.
        let tag = ListeningContextTag.trip("trp_3c9a0b1d2e4f5a6b", origin: "plc_0f1e2d3c4b5a6978",
                                           destination: "plc_8899aabbccddeeff")
        env.provider.lookup = { _ in .settled(tag) }
        await env.svc.flushNow()
        XCTAssertEqual(env.history.events.first?.listeningContext, tag)
        let resend = try XCTUnwrap(env.spy.posts().last)
        XCTAssertEqual(env.spy.posts().count, 2)
        let ctx = try XCTUnwrap(Spy.events(resend).first?["ctx"] as? [String: Any])
        XCTAssertEqual(ctx["destination"] as? String, "plc_8899aabbccddeeff")
        XCTAssertEqual(Spy.events(resend).first?["id"] as? String, ev.id.uuidString)
    }

    func testSettlePassSkipsPeersAndInactiveProvider() {
        let env = makeEnv(locationOn: true)
        env.provider.lookup = { _ in .settled(.place("plc_0f1e2d3c4b5a6978")) }
        let peer = play(env, "sng_p", minutesAgo: 30, origin: .some("PEER"))
        let mine = play(env, "sng_m", minutesAgo: 20)
        env.svc.settleContexts()
        XCTAssertNil(env.history.events.first { $0.id == peer.id }?.listeningContext)
        XCTAssertNotNil(env.history.events.first { $0.id == mine.id }?.listeningContext)

        let inactive = makeEnv(locationOn: false)
        inactive.provider.lookup = { _ in .settled(.place("plc_0f1e2d3c4b5a6978")) }
        play(inactive, "sng_x", minutesAgo: 20)
        inactive.svc.settleContexts()
        XCTAssertNil(inactive.history.events.first?.listeningContext, "an inactive provider is never asked")
    }

    // MARK: - Results + delete cascade

    func testResultsAreCachedForOfflineRelaunch() async throws {
        let env = makeEnv()
        env.spy.body = Data(#"{"v":1,"generatedAtMs":1791806000000,"stale":true,"algo":{"version":1,"params":{}},"pockets":[],"patterns":[]}"#.utf8)
        await env.svc.refreshResults(force: true)
        XCTAssertEqual(env.svc.results?.stale, true)
        XCTAssertEqual(env.svc.results?.generatedAtMs, 1_791_806_000_000)
        // Within the TTL a non-forced refresh makes no request.
        let n = env.spy.requests.count
        await env.svc.refreshIfStale()
        XCTAssertEqual(env.spy.requests.count, n)
        // A fresh service on the same cache file renders without the network.
        let svc2 = ListeningPocketsService(
            history: env.history, settings: env.settings, credentials: { nil },
            provider: env.provider, client: ListeningPocketsClient(transport: { _ in throw URLError(.notConnectedToInternet) }),
            syncFileURL: env.syncURL, cacheFileURL: env.cacheURL)
        XCTAssertEqual(svc2.results?.generatedAtMs, 1_791_806_000_000)
    }

    func testDeleteCloudDataSendsDeleteAndClearsLocalState() async throws {
        let env = makeEnv()
        play(env, "sng_1", minutesAgo: 10)
        await env.svc.flushNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.syncURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.cacheURL.path))
        env.spy.body = Data(#"{"deleted":true}"#.utf8)
        let ok = await env.svc.deleteCloudData(key: "the-key", profileId: "the-profile")
        XCTAssertTrue(ok)
        let del = try XCTUnwrap(env.spy.requests.last)
        XCTAssertEqual(del.httpMethod, "DELETE")
        XCTAssertEqual(del.url?.path, "/pockets/state")
        XCTAssertEqual(del.value(forHTTPHeaderField: "Authorization"), "Bearer the-key")
        XCTAssertEqual(del.value(forHTTPHeaderField: "X-PocketDJ-Profile"), "the-profile")
        XCTAssertEqual(del.value(forHTTPHeaderField: "X-PocketDJ-Enroll"), "enroll-secret")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.syncURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.cacheURL.path))
        XCTAssertNil(env.svc.results)
        XCTAssertTrue(env.svc.acknowledgedFingerprints.isEmpty, "a re-enable re-uploads fresh")
    }

    func testDeleteRunsEvenWhenDisabledAnd404IsSuccess() async {
        let env = makeEnv(recOn: false)
        env.spy.status = 404
        let ok = await env.svc.deleteCloudData(key: "k", profileId: "p")
        XCTAssertTrue(ok, "not deployed ⇒ nothing stored ⇒ deleted")
        XCTAssertEqual(env.spy.requests.map(\.httpMethod), ["DELETE"])
    }

    /// The real cascade: RecommendationService's "Delete cloud data" → the pockets DELETE, with
    /// the rec engine's own bearer + scoped id.
    func testRecommendationServiceDeleteCascadesIntoPockets() async throws {
        let env = makeEnv()
        let recSpy = Spy()
        recSpy.body = Data(#"{"deleted":true}"#.utf8)
        let rec = RecommendationService(
            client: RecEngineClient(base: URL(string: "https://rec.test")!, transport: { recSpy.record($0) }),
            settings: env.settings, history: env.history,
            favorites: FavoritesStore(fileURL: tempURL("fav")),
            activity: CollectionActivityStore(fileURL: tempURL("act")),
            collections: CollectionsStore(fileURL: tempURL("coll")),
            profileIdProvider: { "profile-1" },
            keyFileURL: tempURL("key"), stateFileURL: tempURL("state"))
        rec.fixtureForTesting = false
        let creds = try XCTUnwrap(rec.sharedCredentials(), "enabled ⇒ credentials (key minted)")
        XCTAssertEqual(creds.profileId.count, 64, "the SCOPED id (HMAC hex), never the broadcast one")
        XCTAssertNotEqual(creds.profileId, "profile-1")
        rec.onDeleteCloudData = { [weak svc = env.svc] key, pid in
            await svc?.deleteCloudData(key: key, profileId: pid)
        }
        env.spy.body = Data(#"{"deleted":true}"#.utf8)
        let ok = await rec.deleteCloudData()
        XCTAssertTrue(ok)
        let del = try XCTUnwrap(env.spy.requests.first { $0.httpMethod == "DELETE" })
        XCTAssertEqual(del.value(forHTTPHeaderField: "Authorization"), "Bearer \(creds.key)")
        XCTAssertEqual(del.value(forHTTPHeaderField: "X-PocketDJ-Profile"), creds.profileId)

        // …and with the engine off there are no credentials to hand out.
        env.settings.recEngineEnabled = false
        XCTAssertNil(rec.sharedCredentials())
    }

    // MARK: - Fixture seam

    func testFixtureServesCannedResultsWithZeroNetwork() async {
        let env = makeEnv(recOn: false)
        env.svc.fixtureForTesting = true
        XCTAssertTrue(env.svc.isEnabled)
        play(env, "sng_1", minutesAgo: 10)
        await env.svc.refreshNow()
        let sent = await env.svc.flushNow()
        XCTAssertFalse(sent)
        XCTAssertTrue(env.spy.requests.isEmpty)
        // The test bundle's host app carries the bundled fixture.
        if ListeningPocketsService.fixtureResults() != nil {
            XCTAssertFalse(env.svc.results?.patterns.isEmpty ?? true)
        }
    }
}
