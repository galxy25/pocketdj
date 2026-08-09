import XCTest
@testable import PocketDJ

#if canImport(MusicKit)
import MusicKit
#endif

/// GATE PROBE — does MusicKit actually hand back `Song.playCount` on this machine?
///
/// The header promises `public var playCount: Swift.Int?` on `MusicKit.Song` (iOS 16+/macOS 14+/
/// visionOS 1+), and `playCount` is even a first-class `LibrarySongSortProperties` key. But Apple
/// Developer Forums thread 739587 reports it reading correctly on macOS while coming back nil on
/// iOS, unanswered by Apple. Everything downstream of a play-count feature — importing a baseline,
/// the "#NN" badge, sort-by-plays, rec-engine weighting — is worthless if the property is nil in
/// practice, so this settles it EMPIRICALLY against the signed-in library instead of against the
/// header.
///
/// Safe to keep in the always-on unit bundle: it is a NO-OP unless MusicKit is authorized for this
/// host. The Simulator and CI can never authorize (and the probe never calls
/// `MusicAuthorization.request()`, so it can never raise a consent sheet mid-suite) — there it just
/// records the status and passes. On a Mac holding the Media Library grant it issues two BOUNDED
/// requests (no full-library walk) and prints `PDJ_PLAYCOUNT_PROBE:` lines.
final class PlayCountProbeTests: XCTestCase {

    private func log(_ line: String) {
        print("PDJ_PLAYCOUNT_PROBE: \(line)")
    }

    func testMusicKitReportsPlayCounts() async throws {
        #if canImport(MusicKit)
        let status = MusicAuthorization.currentStatus
        log("platform=\(platformName) authorization=\(status) appleMusicEnabled=\(AppleMusicCredentials.isEnabled)")

        guard status == .authorized else {
            log("RESULT=UNAUTHORIZED — no library access in this host; nothing observed.")
            return
        }

        // ---- Probe A: an unsorted bounded page (is playCount populated AT ALL?) ---------------
        var page = MusicLibraryRequest<MusicKit.Song>()
        page.limit = 200
        let pageItems = try await page.response().items
        var nonNil = 0
        var nonZero = 0
        var total = 0
        for song in pageItems {
            guard let count = song.playCount else { continue }
            nonNil += 1
            total += count
            if count > 0 { nonZero += 1 }
        }
        log("probeA songs=\(pageItems.count) nonNilPlayCount=\(nonNil) nonZeroPlayCount=\(nonZero) sumOfPlays=\(total)")

        // ---- Probe B: sorted by playCount desc (does the LIBRARY-SIDE sort key work?) ---------
        // If sorting works, the top rows are the most-played songs and their counts must be
        // monotonically non-increasing — that is what a "sort by play count" feature would ride.
        var top = MusicLibraryRequest<MusicKit.Song>()
        top.sort(by: \.playCount, ascending: false)
        top.limit = 25
        let topItems = try await top.response().items
        var previous = Int.max
        var monotonic = true
        var topNonNil = 0
        for song in topItems {
            guard let count = song.playCount else { continue }
            topNonNil += 1
            if count > previous { monotonic = false }
            previous = count
        }
        log("probeB songs=\(topItems.count) nonNilPlayCount=\(topNonNil) descendingOrderHeld=\(monotonic)")
        for song in topItems.prefix(10) {
            let count = song.playCount.map(String.init) ?? "nil"
            let last = song.lastPlayedDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
            log("  top | plays=\(count) lastPlayed=\(last) | \(song.title) — \(song.artistName)")
        }

        log("RESULT=OBSERVED nonNilA=\(nonNil)/\(pageItems.count) nonZeroA=\(nonZero) nonNilB=\(topNonNil)/\(topItems.count)")
        #else
        log("RESULT=NO-MUSICKIT — framework not importable in this build.")
        #endif
    }

    private var platformName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(visionOS)
        return "visionOS"
        #elseif targetEnvironment(simulator)
        return "iOS-simulator"
        #else
        return "iOS-device"
        #endif
    }
}
