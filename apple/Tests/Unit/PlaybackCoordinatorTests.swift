import XCTest
@testable import PocketDJ

/// The matching engine's SOURCE-AWARE provider ordering. The Apple Music streaming
/// provider can only be `isReady` (and thus placed first) with a signed build + MusicKit
/// authorization, which a unit test can't supply — so here we verify the parts that ARE
/// testable without it:
///   • the rip server is ALWAYS the terminal fallback (present, and last),
///   • Apple Music is NEVER placed first when it isn't ready, regardless of source,
///   • the engine consults the injected `sourceOfSong` map to decide ordering.
/// The "Apple Music first when ready" branch is exercised by the manual device test (it
/// needs the entitlement + a subscription); see the PR's manual-test steps.
@MainActor
final class PlaybackCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> PlaybackCoordinator {
        let rips = RipsStore()
        let player = PlayerEngine()
        let am = AppleMusicPlaybackProvider(provider: AppleMusicProvider())
        return PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: am)
    }

    func testRipServerIsAlwaysTheTerminalFallback() {
        let c = makeCoordinator()
        c.sourceOfSong = { _ in "My Vinyl" }
        let song = IndexSong.minimal(id: "sng_1", name: "Neon", artist: "Test")
        let providers = c.providers(for: song)
        XCTAssertEqual(providers.last?.backend, .ripServer, "rip server must be the last fallback")
        XCTAssertTrue(providers.contains { $0.backend == .ripServer })
    }

    func testNonAppleMusicSourceUsesOnlyRipServer() {
        let c = makeCoordinator()
        c.sourceOfSong = { _ in "My Vinyl" }
        let song = IndexSong.minimal(id: "sng_1", name: "Neon", artist: "Test")
        // A vinyl song → just the rip server (Apple Music isn't even a candidate).
        XCTAssertEqual(c.providers(for: song).map(\.backend), [.ripServer])
    }

    func testAppleMusicSourceStillFallsBackToRipWhenNotReady() {
        let c = makeCoordinator()
        c.sourceOfSong = { _ in Config.appleMusicSourceName }
        let song = IndexSong.minimal(id: "am:123", name: "Outta My System", artist: "Test")
        // The source matches; whether Apple Music is placed FIRST hinges on `isReady`, which
        // depends on the live MusicAuthorization state a unit test can't control (the
        // simulator may already be authorized from manual testing). Assert the ordering
        // MATCHES readiness either way — and that the rip server is always the terminal
        // fallback. (The "ready ⇒ Apple Music first" path is also covered on a real device.)
        if c.appleMusic.isReady {
            XCTAssertEqual(c.providers(for: song).map(\.backend), [.appleMusic, .ripServer])
        } else {
            XCTAssertEqual(c.providers(for: song).map(\.backend), [.ripServer])
        }
    }

    func testMinimalSongCarriesIdTitleArtist() {
        let s = IndexSong.minimal(id: "x", name: "Title", artist: "Artist")
        XCTAssertEqual(s.id, "x")
        XCTAssertEqual(s.name, "Title")
        XCTAssertEqual(s.artist, "Artist")
        XCTAssertNil(s.length)
        XCTAssertNil(s.albumId)
    }

    func testBackendViaLabels() {
        XCTAssertEqual(PlaybackBackend.appleMusic.viaLabel, "via Apple Music")
        XCTAssertEqual(PlaybackBackend.ripServer.viaLabel, "via rip")
    }
}
