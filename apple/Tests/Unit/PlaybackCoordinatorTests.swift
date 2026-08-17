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

    // NOT a defaulted parameter: `RipsStore()` is @MainActor-isolated, and a default argument
    // expression is evaluated in a nonisolated context.
    private func makeCoordinator() -> PlaybackCoordinator { makeCoordinator(rips: RipsStore()) }

    private func makeCoordinator(rips: RipsStore) -> PlaybackCoordinator {
        let player = PlayerEngine()
        let am = AppleMusicPlaybackProvider(provider: AppleMusicProvider())
        return PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: am)
    }

    /// A streamable row whose rip is merely QUEUED must not sit behind that rip.
    /// `RipServerPlaybackProvider.tryPlay` does not FAIL on a queued rip — it PARKS inside
    /// `ensureURL(allowLive:)` waiting for the capture to go live, which is minutes while the
    /// rip server drains a backfill queue. The provider cycle is sequential, so a streaming
    /// provider placed behind it never gets its turn: the deck advances onto a row that never
    /// starts and the PREVIOUS track keeps sounding under the new title, and ▶ then resumes
    /// THAT (Levi, 2026-08-17 — "queued shouldn't block me from streaming via the cloud").
    func testQueuedRipDoesNotBlockTheStreamingFallback() {
        let c = makeCoordinator()                     // empty manifest ⇒ nothing durable
        c.appleMusicReadyOverrideForTests = true      // else this degrades to the [.ripServer] branch
        c.sourceOfSong = { _ in "My Vinyl" }
        let song = IndexSong.minimal(id: "sng_q", name: "Waiting", artist: "Test",
                                     appleMusicId: "1799999999")
        XCTAssertEqual(c.providers(for: song).map(\.backend), [.appleMusic, .ripServer],
                       "a rip that cannot start NOW must not be tried ahead of the stream")
    }

    /// Streaming rescues the row only when it actually CAN: with Apple Music unavailable the
    /// row still belongs to the rip server, queued or not (the public no-subscription case).
    func testQueuedRipStillUsesRipServerWhenAppleMusicIsNotReady() {
        let c = makeCoordinator()
        c.appleMusicReadyOverrideForTests = false
        c.sourceOfSong = { _ in "My Vinyl" }
        let song = IndexSong.minimal(id: "sng_q", name: "Waiting", artist: "Test",
                                     appleMusicId: "1799999999")
        XCTAssertEqual(c.providers(for: song).map(\.backend), [.ripServer])
    }

    /// The other half of the doctrine, and the guard against over-correcting: a DURABLE rip is
    /// the user's OWN cut and must still win outright over streaming. Only "can't deliver YET"
    /// reorders — "delivers instantly" keeps prefer-the-user's-cut exactly as it was.
    func testDurableRipStillBeatsStreaming() {
        let rips = RipsStore()
        rips.setManifest(["sng_q": RipsStore.ManifestEntry(key: "rips/sng_q.mp3")])
        let c = makeCoordinator(rips: rips)
        c.appleMusicReadyOverrideForTests = true   // AM available and STILL must not win
        c.sourceOfSong = { _ in "My Vinyl" }
        let song = IndexSong.minimal(id: "sng_q", name: "Waiting", artist: "Test",
                                     appleMusicId: "1799999999")
        XCTAssertEqual(c.providers(for: song).map(\.backend), [.ripServer, .appleMusic],
                       "a rip that already exists must still win — prefer-the-user's-cut")
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
