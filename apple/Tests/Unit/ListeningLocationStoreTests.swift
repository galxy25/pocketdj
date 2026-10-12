import XCTest
@testable import PocketDJ

/// ListeningLocationStore — the opt-in gate, permission handling, persistence and privacy shape
/// of the on-device location context. A fake source stands in for CoreLocation (so the denied
/// path and unsupported platforms are testable on iOS AND macOS without a real prompt).
@MainActor
final class ListeningLocationStoreTests: XCTestCase {

    private final class FakeSource: ListeningLocationSource {
        var authorization: ListeningLocationAuthorization
        var starts = 0, stops = 0, alwaysRequests = 0
        weak var store: ListeningLocationStore?
        init(_ a: ListeningLocationAuthorization) { authorization = a }
        func start(delivering store: ListeningLocationStore) { starts += 1; self.store = store }
        func stop() { stops += 1 }
        func requestAlwaysUpgrade() { alwaysRequests += 1 }
    }

    private final class Clock { var now = Date(timeIntervalSince1970: 1_760_000_000) }

    private var clock = Clock()

    override func setUp() {
        super.setUp()
        clock = Clock()
    }

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-listening-places-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeStore(_ url: URL, source: FakeSource?, supported: Bool = true,
                           sourceMade: (() -> Void)? = nil) -> ListeningLocationStore {
        let clock = self.clock
        return ListeningLocationStore(fileURL: url, now: { clock.now }, platformSupported: supported,
                                      makeSource: { sourceMade?(); return source })
    }

    private func visit(_ lat: Double, _ fromH: Double, _ toH: Double?) -> LocationVisitSample {
        LocationVisitSample(latitude: lat, longitude: -122.6, horizontalAccuracy: 25,
                            arrival: clock.now.addingTimeInterval(fromH * 3600),
                            departure: toH.map { clock.now.addingTimeInterval($0 * 3600) })
    }

    // MARK: - Gate

    func testDefaultsOffAndDisabledIsANoOp() {
        let source = FakeSource(.whenInUse)
        let store = makeStore(tempURL(), source: source)
        XCTAssertFalse(store.isEnabled)
        XCTAssertFalse(store.isActive)
        store.startIfEnabled()
        XCTAssertEqual(source.starts, 0, "off by default — startIfEnabled starts nothing")

        store.ingestVisit(visit(45.5, -3, -1))
        XCTAssertTrue(store.engine.places.isEmpty)
        XCTAssertEqual(store.context(at: clock.now.addingTimeInterval(-2 * 3600)), .unavailable)
        XCTAssertTrue(store.placeLabels().isEmpty)
        XCTAssertTrue(store.tripLabels().isEmpty)
    }

    func testEnableStartsTrackingAndResolvesContext() {
        let source = FakeSource(.whenInUse)
        let store = makeStore(tempURL(), source: source)
        let rev0 = store.revision
        store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)
        XCTAssertTrue(store.isActive)
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(store.engine.trackingStartedAt, clock.now)
        XCTAssertGreaterThan(store.revision, rev0)

        let t0 = clock.now
        clock.now = t0.addingTimeInterval(10 * 3600)
        store.ingestVisit(visit(45.5, -10, -1))     // relative to the moved clock: t0 … t0+9h
        XCTAssertEqual(store.engine.places.count, 1)
        guard case .settled(let tag) = store.context(at: t0.addingTimeInterval(3600)) else {
            return XCTFail("expected a settled place")
        }
        XCTAssertTrue(tag.isPlace)
        XCTAssertEqual(store.label(for: tag), "Location A")
        XCTAssertEqual(store.placeLabels().map(\.label), ["Location A"])
        XCTAssertEqual(store.context(at: t0.addingTimeInterval(-60)), .unavailable, "before tracking started")
    }

    func testDisableStopsAndErases() throws {
        let url = tempURL()
        let source = FakeSource(.always)
        let store = makeStore(url, source: source)
        store.setEnabled(true)
        clock.now = clock.now.addingTimeInterval(5 * 3600)
        store.ingestVisit(visit(45.5, -4, -1))
        let tag = ListeningContextTag.place(store.engine.places[0].id)

        store.setEnabled(false)
        XCTAssertFalse(store.isEnabled)
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(source.stops, 1)
        XCTAssertTrue(store.engine.places.isEmpty)
        XCTAssertTrue(store.engine.timeline.isEmpty)
        XCTAssertTrue(store.engine.rawVisits.isEmpty)
        XCTAssertNil(store.engine.trackingStartedAt)
        XCTAssertNil(store.label(for: tag), "a tag written before the erase reads as an earlier place")

        let reloaded = makeStore(url, source: FakeSource(.always))
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertTrue(reloaded.engine.places.isEmpty)
    }

    func testEraseWhileEnabledRestartsTrackingFromNow() {
        let store = makeStore(tempURL(), source: FakeSource(.always))
        store.setEnabled(true)
        clock.now = clock.now.addingTimeInterval(5 * 3600)
        store.ingestVisit(visit(45.5, -4, -1))
        store.eraseAll()
        XCTAssertTrue(store.isEnabled)
        XCTAssertTrue(store.engine.places.isEmpty)
        XCTAssertEqual(store.engine.trackingStartedAt, clock.now)
        XCTAssertEqual(store.context(at: clock.now.addingTimeInterval(-3600)), .unavailable)
    }

    // MARK: - Permission

    func testPermissionDeniedIsInactiveUntilGranted() {
        let source = FakeSource(.denied)
        let store = makeStore(tempURL(), source: source)
        store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)
        XCTAssertEqual(store.authorization, .denied)
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(store.context(at: clock.now), .unavailable)

        // The user flips it on in Settings an hour later: tracking effectively begins at the grant.
        clock.now = clock.now.addingTimeInterval(3600)
        store.sourceAuthorizationDidChange(.whenInUse)
        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.engine.trackingStartedAt, clock.now)
        XCTAssertEqual(store.context(at: clock.now.addingTimeInterval(-1800)), .unavailable)
        XCTAssertEqual(store.context(at: clock.now), .pending)

        store.sourceAuthorizationDidChange(.denied)
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(store.context(at: clock.now), .unavailable)
    }

    func testAlwaysUpgradeIsOfferedOnce() {
        let source = FakeSource(.whenInUse)
        let store = makeStore(tempURL(), source: source)
        store.requestAlwaysUpgrade()
        XCTAssertEqual(source.alwaysRequests, 0, "nothing to upgrade while off")
        store.setEnabled(true)
        XCTAssertFalse(store.didRequestAlways)
        store.requestAlwaysUpgrade()
        XCTAssertEqual(source.alwaysRequests, 1)
        XCTAssertTrue(store.didRequestAlways)
    }

    // MARK: - Platforms

    func testUnsupportedPlatformNeverStartsOrTags() {
        var made = 0
        let store = makeStore(tempURL(), source: FakeSource(.always), supported: false, sourceMade: { made += 1 })
        XCTAssertFalse(store.isSupported)
        XCTAssertEqual(store.authorization, .unsupported)
        store.setEnabled(true)
        store.startIfEnabled()
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(made, 0)
        store.ingestVisit(visit(45.5, -3, -1))
        XCTAssertTrue(store.engine.places.isEmpty)
        XCTAssertEqual(store.context(at: clock.now), .unavailable)
        XCTAssertNil(store.label(for: .place("plc_0000000000000001")))
    }

    func testPlatformDefaultSupport() {
        let store = ListeningLocationStore(fileURL: tempURL())
        XCTAssertEqual(store.isSupported, ListeningLocationStore.platformSupportsLocation)
        #if os(iOS)
        XCTAssertTrue(store.isSupported)
        #else
        XCTAssertFalse(store.isSupported)
        XCTAssertEqual(store.context(at: Date()), .unavailable)
        #endif
        XCTAssertFalse(store.isEnabled)
    }

    func testNoopProviderIsAlwaysUnavailable() {
        let p: any ListeningContextProviding = NoopListeningContextProvider()
        XCTAssertFalse(p.isSupported)
        XCTAssertFalse(p.isActive)
        XCTAssertEqual(p.revision, 0)
        XCTAssertEqual(p.context(at: Date()), .unavailable)
        XCTAssertTrue(p.placeLabels().isEmpty)
        XCTAssertTrue(p.tripLabels().isEmpty)
        XCTAssertNil(p.label(for: .place("plc_0000000000000001")))
    }

    // MARK: - Persistence + privacy

    func testLaunchURLFixtureSeamIsIsolated() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] == nil,
                      "the test scheme sets PDJ_USE_FIXTURE")
        let url = ListeningLocationStore.launchURL()
        XCTAssertNotEqual(url, ListeningLocationStore.defaultURL())
        XCTAssertEqual(url.lastPathComponent, "pdj-uitest-listening-places.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(ListeningLocationStore.defaultURL().lastPathComponent, "pocketdj-listening-places.json")
    }

    func testPersistsAcrossLaunchesAndIsExcludedFromBackup() throws {
        let url = tempURL()
        let store = makeStore(url, source: FakeSource(.always))
        store.setEnabled(true)
        clock.now = clock.now.addingTimeInterval(5 * 3600)
        store.ingestVisit(visit(45.5, -4, -1))
        let ids = store.engine.places.map(\.id)

        let source2 = FakeSource(.always)
        let reloaded = makeStore(url, source: source2)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertEqual(reloaded.engine.places.map(\.id), ids)
        reloaded.startIfEnabled()
        XCTAssertEqual(source2.starts, 1, "a relaunch restarts the source when enabled")

        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testCorruptDocumentResetsToEmpty() throws {
        let url = tempURL()
        try Data("{not json".utf8).write(to: url)
        let store = makeStore(url, source: FakeSource(.always))
        XCTAssertFalse(store.isEnabled)
        XCTAssertTrue(store.engine.places.isEmpty)

        try Data(#"{"schemaVersion": 1, "isEnabled": true, "engine": "garbage"}"#.utf8).write(to: url)
        let partial = makeStore(url, source: FakeSource(.always))
        XCTAssertTrue(partial.isEnabled, "a damaged engine doesn't cost the opt-in")
        XCTAssertTrue(partial.engine.places.isEmpty)
    }

    /// After raw-sample retention, the ONLY coordinates in the file are place centroids, rounded
    /// to 4 decimals; the timeline (ids + times) survives.
    func testPersistedFileHoldsOnlyRoundedCentroidsAfterPrune() throws {
        let url = tempURL()
        let store = makeStore(url, source: FakeSource(.always))
        store.setEnabled(true)
        clock.now = clock.now.addingTimeInterval(20 * 3600)
        store.ingestVisit(visit(45.512_345_67, -19, -10))
        store.ingestVisit(visit(45.534_567_89, -9.5, -2))
        XCTAssertEqual(store.engine.rawVisits.count, 2)

        clock.now = clock.now.addingTimeInterval(31 * 86_400)
        store.startIfEnabled()   // prunes at launch

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let engine = try XCTUnwrap(root["engine"] as? [String: Any])
        XCTAssertEqual((engine["rawVisits"] as? [Any])?.count, 0)
        XCTAssertEqual((engine["timeline"] as? [Any])?.count, 2)

        var coordinatePaths: [String] = []
        func walk(_ v: Any, _ path: String) {
            if let d = v as? [String: Any] {
                for (k, x) in d {
                    if ["latitude", "longitude"].contains(k) { coordinatePaths.append(path) }
                    walk(x, path + "." + k)
                }
            } else if let a = v as? [Any] {
                a.forEach { walk($0, path + "[]") }
            }
        }
        walk(root, "")
        XCTAssertFalse(coordinatePaths.isEmpty)
        XCTAssertTrue(coordinatePaths.allSatisfy { $0 == ".engine.places[]" }, "\(coordinatePaths)")

        let places = try XCTUnwrap(engine["places"] as? [[String: Any]])
        XCTAssertEqual(places.count, 2)
        for p in places {
            for key in ["latitude", "longitude"] {
                let x = try XCTUnwrap(p[key] as? Double)
                XCTAssertEqual(x, (x * 10_000).rounded() / 10_000, accuracy: 1e-9, "\(key) \(x) not 4 dp")
            }
        }
    }
}
