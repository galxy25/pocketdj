import XCTest
@testable import PocketDJ

/// Zero-to-hero onboarding state machine: the launch decision tree, marker
/// persistence across force-quits, the completion waiters, and the mushroom-cloud
/// reset's forced re-run.
@MainActor
final class OnboardingStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "pdj.test.onboarding"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// The unit-test scheme itself sets PDJ_USE_FIXTURE globally, so decision tests
    /// pass an explicit environment — decide() must stay a pure function of its inputs.
    private let cleanEnv: [String: String] = [:]

    // MARK: - Decision tree

    func testFreshInstallShows() {
        XCTAssertEqual(OnboardingStore.decide(marker: nil, hadPersistedSettings: false,
                                              environment: cleanEnv),
                       .show(.profile))
    }

    func testExistingUserUpgradeSkipsAndStamps() {
        XCTAssertEqual(OnboardingStore.decide(marker: nil, hadPersistedSettings: true,
                                              environment: cleanEnv),
                       .skipAndStamp)
    }

    func testCompletedMarkerSkips() {
        XCTAssertEqual(OnboardingStore.decide(marker: .completed, hadPersistedSettings: true,
                                              environment: cleanEnv),
                       .skip)
    }

    /// R6: a mid-flow force-quit resumes at the recorded stage even though stage 1
    /// already persisted a settings blob (blob-existence alone would strand the rest).
    func testStartedMarkerResumesAtStageDespiteSettingsBlob() {
        XCTAssertEqual(OnboardingStore.decide(marker: .started(.sources), hadPersistedSettings: true,
                                              environment: cleanEnv),
                       .show(.sources))
    }

    /// R6: the mushroom-cloud reset's pending marker outranks a re-persisted blob.
    func testPendingMarkerForcesShowDespiteSettingsBlob() {
        XCTAssertEqual(OnboardingStore.decide(marker: .pending, hadPersistedSettings: true,
                                              environment: cleanEnv),
                       .show(.profile))
    }

    func testFixtureAndPerfSmokeSuppress() {
        for env in [["PDJ_USE_FIXTURE": "1"], ["PDJ_INTEGRATION_PLAYBACK": "1"],
                    ["PDJ_PERF_SMOKE": "1"]] {
            XCTAssertEqual(OnboardingStore.decide(marker: nil, hadPersistedSettings: false,
                                                  environment: env),
                           .skip, "suppressed under \(env)")
        }
    }

    func testForceSeamOutranksSuppressionAndMarker() {
        let env = ["PDJ_SHOW_ONBOARDING": "1", "PDJ_USE_FIXTURE": "1"]
        XCTAssertEqual(OnboardingStore.decide(marker: .completed, hadPersistedSettings: true,
                                              environment: env),
                       .show(.profile))
    }

    // MARK: - Live store behavior

    func testFreshStoreShowsStampsStartedAndAdvancesThroughStages() {
        let s = OnboardingStore(defaults: defaults, hadPersistedSettings: false, environment: cleanEnv)
        XCTAssertFalse(s.isComplete)
        XCTAssertEqual(s.stage, .profile)
        XCTAssertEqual(OnboardingStore.readMarker(defaults), .started(.profile))

        s.advance()
        XCTAssertEqual(s.stage, .appleMusic)
        XCTAssertEqual(OnboardingStore.readMarker(defaults), .started(.appleMusic))
        s.back()
        XCTAssertEqual(s.stage, .profile)
        s.advance(); s.advance()
        XCTAssertEqual(s.stage, .sources)

        var completed = 0
        s.onComplete = { completed += 1 }
        s.advance()   // past the last stage ⇒ complete
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(OnboardingStore.readMarker(defaults), .completed)

        // A relaunch (same defaults) never shows again.
        let next = OnboardingStore(defaults: defaults, hadPersistedSettings: true, environment: cleanEnv)
        XCTAssertTrue(next.isComplete)
    }

    func testForceQuitMidFlowResumesAtRecordedStage() {
        let s = OnboardingStore(defaults: defaults, hadPersistedSettings: false, environment: cleanEnv)
        s.advance()   // → appleMusic; "force-quit" = just construct a new store
        let resumed = OnboardingStore(defaults: defaults, hadPersistedSettings: true, environment: cleanEnv)
        XCTAssertFalse(resumed.isComplete)
        XCTAssertEqual(resumed.stage, .appleMusic)
    }

    func testUpgradeStampHappensOnce() {
        let s = OnboardingStore(defaults: defaults, hadPersistedSettings: true, environment: cleanEnv)
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(OnboardingStore.readMarker(defaults), .completed)
    }

    func testWaitUntilCompleteReleasesWaitersOnComplete() async {
        let s = OnboardingStore(defaults: defaults, hadPersistedSettings: false, environment: cleanEnv)
        let released = expectation(description: "waiter released")
        Task { @MainActor in
            await s.waitUntilComplete()
            released.fulfill()
        }
        // Give the waiter a beat to park, then complete.
        try? await Task.sleep(for: .milliseconds(50))
        s.complete()
        await fulfillment(of: [released], timeout: 2)
        // A late waiter returns immediately.
        await s.waitUntilComplete()
    }

    func testMarkPendingAfterResetForcesNextLaunch() {
        let s = OnboardingStore(defaults: defaults, hadPersistedSettings: false, environment: cleanEnv)
        s.complete()
        OnboardingStore.markPendingAfterReset(in: defaults)
        let next = OnboardingStore(defaults: defaults, hadPersistedSettings: true, environment: cleanEnv)
        XCTAssertFalse(next.isComplete, "pending marker outranks blob + prior completion")
        XCTAssertEqual(next.stage, .profile)
    }

    func testSettingsResetEverythingWritesPendingMarker() {
        let settings = SettingsStore(defaults: defaults)
        settings.resetEverything()
        XCTAssertEqual(OnboardingStore.readMarker(defaults), .pending)
    }

    func testHadPersistedSettingsCapture() {
        let fresh = SettingsStore(defaults: defaults)
        XCTAssertFalse(fresh.hadPersistedSettings)
        fresh.persist()
        let second = SettingsStore(defaults: defaults)
        XCTAssertTrue(second.hadPersistedSettings)
    }

    // MARK: - Stage 3 source reconciliation

    func testApplyOnboardingSourcesReconcilesBuiltins() {
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.sources.map(\.name), ["My Vinyl"])   // the default blob

        settings.applyOnboardingSources(vinyl: false, digital: true, streaming: true)
        XCTAssertEqual(Set(settings.sources.map(\.name)),
                       [Config.digitalSourceName, Config.appleMusicSourceName],
                       "unticked Vinyl removed; chosen built-ins added")

        // Idempotent + re-addable.
        settings.applyOnboardingSources(vinyl: true, digital: true, streaming: false)
        XCTAssertEqual(Set(settings.sources.map(\.name)),
                       ["My Vinyl", Config.digitalSourceName])

        // Zero chosen is a LEGITIMATE public-user configuration since the zero-source catalog
        // boot fix: every shared catalog is removed and the catalog builds from injection
        // sources alone (the user's own on-device Apple Music library, adds, imports).
        settings.applyOnboardingSources(vinyl: false, digital: false, streaming: false)
        XCTAssertTrue(settings.sources.isEmpty, "zero picks removes every shared catalog")
    }
}
