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

    /// Holds a request in flight until `open()` — `arrived()` waits until one is held.
    private actor Gate {
        private var isOpen = false
        private var held: [CheckedContinuation<Void, Never>] = []
        private var arrivals: [CheckedContinuation<Void, Never>] = []
        private var didArrive = false
        func hold() async {
            didArrive = true
            arrivals.forEach { $0.resume() }; arrivals = []
            if isOpen { return }
            await withCheckedContinuation { held.append($0) }
        }
        func arrived() async {
            if didArrive { return }
            await withCheckedContinuation { arrivals.append($0) }
        }
        func open() {
            isOpen = true
            held.forEach { $0.resume() }; held = []
        }
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

    /// `pocketsOn: nil` leaves the choice unmade (a fresh install / an update from before it existed).
    private func makeEnv(recOn: Bool = true, pocketsOn: Bool? = true, locationOn: Bool = true,
                         gate: Gate? = nil) -> Env {
        let suite = "pdj.pockets.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults)
        settings.recEngineEnabled = recOn
        if let pocketsOn { settings.listeningPocketsEnabled = pocketsOn }
        let history = PlayHistoryStore(fileURL: tempURL("history"))
        let spy = Spy()
        let provider = StubProvider()
        provider.isActive = locationOn
        let client = ListeningPocketsClient(base: URL(string: "https://pockets.test")!,
                                            enrollSecret: "enroll-secret",
                                            transport: { req in
                                                if req.httpMethod == "DELETE", let gate { await gate.hold() }
                                                return spy.record(req)
                                            })
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

    /// Pockets are their own opt-in: an engine that was already on does NOT switch them on, so an
    /// update never starts uploading skip outcomes (90 days of them) unasked.
    func testPocketsStayOffUntilChosenEvenWithTheEngineOn() async {
        let env = makeEnv(recOn: true, pocketsOn: nil)
        XCTAssertNil(env.settings.listeningPocketsChoice, "never asked")
        XCTAssertFalse(env.settings.listeningPocketsEnabled)
        XCTAssertFalse(env.svc.isEnabled)
        play(env, "sng_1", minutesAgo: 10)
        let sent = await env.svc.flushNow()
        env.svc.startAutoFlush()
        XCTAssertFalse(sent)
        XCTAssertFalse(env.svc.isAutoFlushArmed)
        XCTAssertTrue(env.spy.requests.isEmpty)
    }

    func testPocketsChoicePersistsAsTriState() {
        let suite = "pdj.pockets.choice.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let s = SettingsStore(defaults: defaults)
        s.recEngineEnabled = true
        s.persist()
        XCTAssertNil(SettingsStore(defaults: defaults).listeningPocketsChoice, "unasked survives a reload as unasked")
        s.listeningPocketsEnabled = false
        s.persist()
        XCTAssertEqual(SettingsStore(defaults: defaults).listeningPocketsChoice, false, "a decline is remembered")
        s.listeningPocketsEnabled = true
        s.persist()
        XCTAssertEqual(SettingsStore(defaults: defaults).listeningPocketsEnabled, true)
    }

    /// The gate closing (pockets or engine off) fires `onDisabled` — the app turns places & trips
    /// off with it, so location never keeps collecting with nothing to feed.
    func testGateClosingFiresOnDisabled() {
        let env = makeEnv()
        var fired = 0
        env.svc.onDisabled = { fired += 1 }
        env.svc.enabledDidChange()
        XCTAssertEqual(fired, 0, "still enabled")
        env.settings.listeningPocketsEnabled = false
        env.svc.enabledDidChange()
        XCTAssertEqual(fired, 1)
        env.settings.listeningPocketsEnabled = true
        env.settings.recEngineEnabled = false
        env.svc.enabledDidChange()
        XCTAssertEqual(fired, 2, "the engine turning off closes it too")
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

    /// The server keeps `ord` immutable from the first insert, so it must not restart per upload:
    /// two same-minute plays sent by DIFFERENT flushes still get 0 and 1 (a 0/0 tie would fall
    /// back to the random UUID on the server and could flip a skip run's order).
    func testOrdIsStableAcrossFlushes() async throws {
        let env = makeEnv(locationOn: false)
        let first = play(env, "sng_a", minutesAgo: 30, seconds: 5)
        await env.svc.flushNow()
        XCTAssertEqual(Spy.events(try XCTUnwrap(env.spy.posts().last)).first?["ord"] as? Int, 0)
        // A second play in the same minute lands after that upload (a quick skip).
        let second = play(env, "sng_b", minutesAgo: 30, seconds: 40)
        env.history.markSkipped(eventId: second.id)
        await env.svc.flushNow()
        let resend = Spy.events(try XCTUnwrap(env.spy.posts().last))
        XCTAssertEqual(resend.map { $0["id"] as? String }, [second.id.uuidString],
                       "only the new play re-sends")
        XCTAssertEqual(resend.first?["ord"] as? Int, 1, "its ord counts the play uploaded earlier")
        // A peer's play in that minute is its own stream: ord restarts for it.
        let peer = play(env, "sng_p", minutesAgo: 30, seconds: 20, origin: .some("PEER-INSTALL"))
        let ords = ListeningPocketsService.ordinals(env.history.events, installId: env.history.installId)
        XCTAssertEqual(ords[first.id], 0)
        XCTAssertEqual(ords[second.id], 1)
        XCTAssertEqual(ords[peer.id], 0)
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

    /// "Fresh data is uploaded again from now on": after the erase, plays from before it never
    /// re-upload — not on the next flush, not after a relaunch, not after a profile rebind.
    func testDeleteCloudDataFloorsUploadsAtTheErase() async throws {
        let env = makeEnv(locationOn: false)
        play(env, "sng_old1", minutesAgo: 600)
        play(env, "sng_old2", minutesAgo: 10)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.posts().count, 1)
        let ok = await env.svc.deleteCloudData(key: Self.key, profileId: Self.profile)
        XCTAssertTrue(ok)
        XCTAssertEqual(env.svc.uploadFloorMs, Self.nowMs)
        let resent = await env.svc.flushNow()
        XCTAssertFalse(resent, "the erased window is not re-uploaded")
        XCTAssertEqual(env.spy.posts().count, 1)

        // A play after the erase uploads — alone.
        let fresh = play(env, "sng_new", minutesAgo: -1)
        await env.svc.flushNow()
        XCTAssertEqual(Spy.events(try XCTUnwrap(env.spy.posts().last)).map { $0["id"] as? String },
                       [fresh.id.uuidString])

        // The floor survives a relaunch and a profile rebind (which resets the fingerprints).
        let spy2 = Spy()
        let svc2 = ListeningPocketsService(
            history: env.history, settings: env.settings, credentials: { (Self.key, "rebound-profile") },
            provider: env.provider,
            client: ListeningPocketsClient(base: URL(string: "https://pockets.test")!, transport: { spy2.record($0) }),
            now: { Date(timeIntervalSince1970: Self.nowMs / 1000) },
            syncFileURL: env.syncURL, cacheFileURL: env.cacheURL)
        svc2.fixtureForTesting = false
        await svc2.flushNow()
        XCTAssertEqual(spy2.posts().flatMap { Spy.events($0).compactMap { $0["songId"] as? String } }, ["sng_new"])
    }

    /// No flush may START while the DELETE is in flight — a batch landing after it would rebuild
    /// the profile the user just erased.
    func testNoFlushStartsWhileTheDeleteIsInFlight() async throws {
        let gate = Gate()
        let env = makeEnv(locationOn: false, gate: gate)
        play(env, "sng_1", minutesAgo: 10)
        let deletion = Task { await env.svc.deleteCloudData(key: Self.key, profileId: Self.profile) }
        await gate.arrived()                       // the DELETE is now held in flight
        let sent = await env.svc.flushNow()        // e.g. the auto-flush loop's tick
        XCTAssertFalse(sent)
        XCTAssertTrue(env.spy.posts().isEmpty, "nothing uploaded during the erase")
        await gate.open()
        let ok = await deletion.value
        XCTAssertTrue(ok)
        XCTAssertEqual(env.spy.requests.map(\.httpMethod), ["DELETE"])
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
