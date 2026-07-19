import XCTest
@testable import PocketDJ

/// The two non-sync onboarding guards: MixSessionStore's virgin-flush guard (R2 — a
/// backgrounding mid-onboarding must not materialize the synced doc) and the
/// IntentServices mutating-intent veto (R4 — Siri/CarPlay cold launches bypass the
/// RootView gate).
@MainActor
final class OnboardingGuardsTests: XCTestCase {

    // MARK: - MixSessionStore virgin-flush guard (R2)

    private func mixStoreURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixflush-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testVirginFlushNeverMaterializesTheFile() {
        let url = mixStoreURL()
        let store = MixSessionStore(fileURL: url)   // init mints an empty Session 1
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "an all-empty document must not be written by a background flush")
    }

    func testFlushWritesOnceThereIsActivity() {
        let url = mixStoreURL()
        let store = MixSessionStore(fileURL: url)
        store.notePlayed(songId: "sng_1")
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // And once the file exists, even a later virgin-looking state keeps flushing
        // (reset mints a fresh session but the doc carries the old one — not virgin).
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testFlushStillWritesWhenFileAlreadyExists() throws {
        let url = mixStoreURL()
        try Data("{}".utf8).write(to: url)   // pre-existing doc (e.g. a restored pull)
        let store = MixSessionStore(fileURL: url)
        store.flush()
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 2, "existing file ⇒ flush proceeds as before")
    }

    // MARK: - IntentServices veto (R4)

    func testMutatingIntentsThrowSetupIncompleteDuringOnboarding() async throws {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-veto-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let collections = CollectionsStore(fileURL: url)
        collections.app = app
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID())")!)
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let player = PlayerEngine()
        let burnsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-veto-burns-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: burnsURL) }
        let burns = BurnStore(rips: rips, fileURL: burnsURL)
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let sequencer = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
        let mix = MixEngine(burns: burns)
        let studioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-veto-studio-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: studioURL) }
        let studio = StudioStore(fileURL: studioURL)
        let services = IntentServices(app: app, settings: settings, collections: collections,
                                      setlistPlayer: sequencer, mix: mix, burns: burns,
                                      studio: studio, rips: rips)

        let pl = collections.createPlaylist("Set")
        collections.addSong("sng_1", toPlaylist: pl.id)

        var incomplete = true
        services.onboardingIncomplete = { incomplete }

        do {
            _ = try await services.playPlaylist(id: pl.id, shuffle: false)
            XCTFail("expected setupIncomplete")
        } catch let e as PocketDJIntentError {
            guard case .setupIncomplete = e else { return XCTFail("wrong error: \(e)") }
        }
        XCTAssertTrue(collections.setlists.isEmpty,
                      "the veto fires BEFORE playNow writes the collections doc")

        // Gate opens ⇒ the same intent goes through.
        incomplete = false
        let name = try await services.playPlaylist(id: pl.id, shuffle: false)
        XCTAssertEqual(name, "Set")
    }
}
