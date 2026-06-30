import XCTest
@testable import PocketDJ

/// Registry + seam tests for the streaming providers, exercised through small
/// test-only stubs (no SDK, no network). Covers: stub providers report
/// `.unavailable`, `StreamingStore` routes `handleCallback` to the claiming
/// provider, kind lookup, and `SongRecognizer` extraction from a provider list.
@MainActor
final class StreamingProviderTests: XCTestCase {

    // MARK: Stubs

    /// A provider that records calls and optionally claims a callback URL scheme.
    private final class StubProvider: StreamingProvider {
        let kind: StreamingProviderKind
        var state: StreamingConnectionState
        let isAvailable: Bool
        /// Scheme this provider claims in `handleCallback`; nil → claims nothing.
        let claimsScheme: String?

        private(set) var reconnects = 0
        private(set) var disconnects = 0
        private(set) var loggedIn = false

        init(kind: StreamingProviderKind, available: Bool = false, claims: String? = nil,
             state: StreamingConnectionState = .unavailable(reason: "stub")) {
            self.kind = kind
            self.isAvailable = available
            self.claimsScheme = claims
            self.state = state
        }

        func login() { loggedIn = true; state = .authorizing }
        func logout() { loggedIn = false; state = .loggedOut }
        func handleCallback(url: URL) -> Bool {
            guard let claimsScheme, url.scheme == claimsScheme else { return false }
            state = .connected(account: nil)
            return true
        }
        func reconnectIfNeeded() { reconnects += 1 }
        func disconnect() { disconnects += 1 }
        func play(uri: String?) {}
        func pause() {}
        func resume() {}
    }

    /// A provider that ALSO recognizes — used to prove `SongRecognizer` extraction.
    private final class StubRecognizerProvider: StreamingProvider, SongRecognizer {
        let kind: StreamingProviderKind
        var state: StreamingConnectionState = .connected(account: nil)
        let isAvailable = true
        let canResolve = true
        let resolvesID: String

        init(kind: StreamingProviderKind, resolvesID: String) {
            self.kind = kind
            self.resolvesID = resolvesID
        }

        func login() {}
        func logout() {}
        func handleCallback(url: URL) -> Bool { false }
        func reconnectIfNeeded() {}
        func disconnect() {}
        func play(uri: String?) {}
        func pause() {}
        func resume() {}

        func resolve(_ song: IndexSong) async -> StreamingTrack? {
            guard song.id == resolvesID else { return nil }
            return StreamingTrack(id: "stub:\(song.id)", kind: kind,
                                  providerTrackID: song.id, title: song.name,
                                  artist: song.artist, artworkURL: nil, durationSeconds: nil)
        }
    }

    // MARK: Default registry

    func testProviderAvailabilityInDefaultBuild() {
        let store = StreamingStore()
        // Apple Music ships with MusicKit and is build-flag-enabled
        // (PocketDJAppleMusicEnabled), so it is AVAILABLE — state .loggedOut until the
        // user authorizes — NOT .unavailable.
        guard let am = store.provider(.appleMusic) else { return XCTFail("no Apple Music provider") }
        XCTAssertTrue(am.isAvailable, "Apple Music should be available with the build flag enabled")
        if case .unavailable = am.state {
            XCTFail("Apple Music must not be .unavailable when the build flag is enabled")
        }
        XCTAssertTrue(store.hasAnyAvailable, "Apple Music availability ⇒ hasAnyAvailable")
    }

    func testDefaultProvidersAreAppleMusicOnly() {
        let store = StreamingStore()
        // Spotify + YouTube were removed; Apple Music is the only built-in streaming provider.
        XCTAssertNotNil(store.provider(.appleMusic))
        XCTAssertEqual(store.providers.count, 1)
        XCTAssertTrue(store.providers.allSatisfy { $0.kind == .appleMusic })
    }

    // MARK: Routing

    func testProviderLookupByKind() {
        // `provider(_:)` returns the FIRST entry of a kind.
        let first = StubProvider(kind: .appleMusic)
        let second = StubProvider(kind: .appleMusic)
        let store = StreamingStore(providers: [first, second])
        XCTAssertTrue(store.provider(.appleMusic) === first)
    }

    func testHandleCallbackRoutesToClaimingProvider() {
        // handleCallback fans across the provider array (URL-scheme based, not kind-keyed).
        let other = StubProvider(kind: .appleMusic, claims: "elsewhere")
        let claimer = StubProvider(kind: .appleMusic, claims: "pocketdj")
        let store = StreamingStore(providers: [other, claimer])

        XCTAssertTrue(store.handleCallback(url: URL(string: "pocketdj://login-callback")!))
        if case .connected = claimer.state {} else { XCTFail("the claiming provider should have handled it") }
        if case .connected = other.state { XCTFail("the non-claiming provider must not handle it") }
    }

    func testHandleCallbackUnclaimedReturnsFalse() {
        let store = StreamingStore(providers: [StubProvider(kind: .appleMusic, claims: "pocketdj")])
        XCTAssertFalse(store.handleCallback(url: URL(string: "https://example.com/x")!))
    }

    func testScenePhaseFansOutToAllProviders() {
        let a = StubProvider(kind: .appleMusic)
        let b = StubProvider(kind: .appleMusic)
        let store = StreamingStore(providers: [a, b])
        store.onScenePhaseActive()
        store.onScenePhaseBackground()
        XCTAssertEqual(a.reconnects, 1); XCTAssertEqual(a.disconnects, 1)
        XCTAssertEqual(b.reconnects, 1); XCTAssertEqual(b.disconnects, 1)
    }

    func testHasAnyAvailableTrueWhenOneIsAvailable() {
        let store = StreamingStore(providers: [
            StubProvider(kind: .appleMusic, available: false),
            StubProvider(kind: .appleMusic, available: true),
        ])
        XCTAssertTrue(store.hasAnyAvailable)
    }

    // MARK: SongRecognizer extraction

    func testRecognizersExtractedFromProviderList() {
        let plain = StubProvider(kind: .appleMusic)
        let rec = StubRecognizerProvider(kind: .appleMusic, resolvesID: "sng_1")
        let providers: [any StreamingProvider] = [plain, rec]
        let recognizers = providers.recognizers
        XCTAssertEqual(recognizers.count, 1)
        XCTAssertEqual(recognizers.first?.kind, .appleMusic)
    }

    func testRecognizerResolvesKnownSong() async throws {
        let rec = StubRecognizerProvider(kind: .appleMusic, resolvesID: "sng_1")
        let songs = try TestData.index().songs
        let target = try XCTUnwrap(songs.first { $0.id == "sng_1" })
        let other = try XCTUnwrap(songs.first { $0.id == "sng_2" })
        let hit = await rec.resolve(target)
        XCTAssertEqual(hit?.providerTrackID, "sng_1")
        let miss = await rec.resolve(other)
        XCTAssertNil(miss)
    }
}
