import XCTest
@testable import PocketDJ

/// "Liked — not added": which 👍'd releases still need adding. Pure — no store, no MusicKit.
final class LikedReleaseSelectionTests: XCTestCase {

    private let now = 1_800_000_000_000.0
    private let day = 86_400_000.0
    private let hour = 3_600_000.0

    private func rel(_ id: String, title: String = "Rec", artistId: Int = 1,
                     releaseAt: Double? = nil, attempt: LikeAddAttempt? = nil,
                     tombstoned: Bool? = nil) -> LikedRelease {
        LikedRelease(storeId: id, artistId: artistId, artistName: "Artist", title: title,
                     releaseAtMs: releaseAt ?? (now - 3 * day), likedAtMs: now - day,
                     attempt: attempt, tombstoned: tombstoned)
    }

    private func select(accepted: [String: Double], meta: [LikedRelease],
                        owned: Set<String> = [], versionOwned: Set<String> = [],
                        needsRetry: [String: String] = [:],
                        inFlight: Set<String> = []) -> LikedReleaseSelection.Result {
        LikedReleaseSelection.likedNotAdded(
            accepted: accepted,
            meta: Dictionary(uniqueKeysWithValues: meta.map { ($0.storeId, $0) }),
            owns: { owned.contains($0.storeId) },
            ownsVersion: { _, _, t in versionOwned.contains(t) },
            writeNeedsRetry: { needsRetry[$0] },
            inFlight: inFlight, nowMs: now)
    }

    func testAcceptedReleaseWithMetaAndNotOwnedIsARow() {
        let r = select(accepted: ["rel:1": now - hour], meta: [rel("1")])
        XCTAssertEqual(r.rows.map(\.id), ["1"])
        XCTAssertTrue(r.needsHydration.isEmpty)
    }

    func testRelartistLikesAreSkippedAndNeverHydrated() {
        let r = select(accepted: ["relartist:5": now], meta: [])
        XCTAssertTrue(r.rows.isEmpty)
        XCTAssertTrue(r.needsHydration.isEmpty)
    }

    func testMissingMetaGoesToHydrationNotRows() {
        let r = select(accepted: ["rel:7": now, "rel:8": now], meta: [rel("8")])
        XCTAssertEqual(r.needsHydration, ["7"])
        XCTAssertEqual(r.rows.map(\.id), ["8"])
    }

    func testTombstonedIdIsNeitherRowNorHydrated() {
        let r = select(accepted: ["rel:9": now], meta: [rel("9", tombstoned: true)])
        XCTAssertTrue(r.rows.isEmpty)
        XCTAssertTrue(r.needsHydration.isEmpty)
    }

    func testOwnedByProbeIsDropped() {
        XCTAssertTrue(select(accepted: ["rel:1": now], meta: [rel("1")], owned: ["1"]).rows.isEmpty)
    }

    func testOwnedAsAnotherVersionIsDropped() {
        XCTAssertTrue(select(accepted: ["rel:1": now], meta: [rel("1", title: "Deluxe")],
                             versionOwned: ["Deluxe"]).rows.isEmpty)
    }

    func testOwnedButAppleMusicWriteUnprovenIsKeptAsRetryRow() {
        let r = select(accepted: ["rel:1": now], meta: [rel("1")], owned: ["1"],
                       needsRetry: ["1": "Apple Music write failed: x"])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertTrue(r.rows[0].retryWriteOnly)
        XCTAssertEqual(r.rows[0].message, "Apple Music write failed: x")
    }

    func testNoAgeLimit() {
        let old = rel("1", releaseAt: now - 200 * day)
        XCTAssertEqual(select(accepted: ["rel:1": now - 200 * day], meta: [old]).rows.count, 1)
    }

    func testAddedWithin24hIsHiddenThenShownAgainIfStillNotOwned() {
        func attempt(ageHours: Double) -> LikeAddAttempt {
            LikeAddAttempt(atMs: now - ageHours * hour, state: .added, message: nil,
                           writeToken: "confirmed", recorded: true)
        }
        XCTAssertTrue(select(accepted: ["rel:1": now], meta: [rel("1", attempt: attempt(ageHours: 23))]).rows.isEmpty)
        XCTAssertEqual(select(accepted: ["rel:1": now], meta: [rel("1", attempt: attempt(ageHours: 25))]).rows.count, 1)
    }

    func testProvenPreAddIsHiddenFromLikedOnlyUntilReleaseDay() {
        let a = LikeAddAttempt(atMs: now - 10 * day, state: .awaitingRelease, message: nil,
                               writeToken: "confirmed (web)", recorded: false)
        // Before release.
        XCTAssertTrue(select(accepted: ["rel:1": now],
                             meta: [rel("1", releaseAt: now + 5 * day, attempt: a)]).rows.isEmpty)
        // Released, still not owned: he gets an Add button (review #8) instead of a hidden row.
        XCTAssertEqual(select(accepted: ["rel:1": now],
                              meta: [rel("1", releaseAt: now - 2 * day, attempt: a)]).rows.count, 1)
    }

    /// Review #3: recorded + write failed on a device that can't write now → owned, no retry note,
    /// but the error must still surface.
    func testOwnedWithFailedWriteAndNoRetryNoteKeepsTheRowWithItsMessage() {
        let a = LikeAddAttempt(atMs: now - hour, state: .failed, message: "Connect Apple Music",
                               writeToken: "Apple Music write skipped: not authorized", recorded: true)
        let r = select(accepted: ["rel:1": now], meta: [rel("1", attempt: a)], owned: ["1"])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertEqual(r.rows.first?.message, "Connect Apple Music")
        XCTAssertTrue(r.rows.first?.retryWriteOnly ?? false)
    }

    func testUnprovenPreOrderShowsInLikedAsAwaitingRelease() {
        let a = LikeAddAttempt(atMs: now - hour, state: .awaitingRelease, message: nil,
                               writeToken: "Apple Music write failed: x", recorded: false)
        let r = select(accepted: ["rel:1": now], meta: [rel("1", releaseAt: now + 5 * day, attempt: a)])
        XCTAssertEqual(r.rows.first?.state, .awaitingRelease)
    }

    func testPreAddedSetIsOnlyProvenAwaitingRelease() {
        let proven = LikeAddAttempt(atMs: now, state: .awaitingRelease, message: nil,
                                    writeToken: "confirmed", recorded: false)
        let unproven = LikeAddAttempt(atMs: now, state: .awaitingRelease, message: nil,
                                      writeToken: "Apple Music write failed: x", recorded: false)
        let set = LikedReleaseSelection.preAdded(
            meta: ["1": rel("1", releaseAt: now + day, attempt: proven),
                   "2": rel("2", releaseAt: now + day, attempt: unproven), "3": rel("3"),
                   "4": rel("4", releaseAt: now - day, attempt: proven),
                   "5": rel("5", releaseAt: now + day, attempt: proven)],
            nowMs: now, accepted: ["rel:1": now, "rel:2": now, "rel:3": now, "rel:4": now])
        // 4 is released (Out now); 5 is no longer accepted (review #8).
        XCTAssertEqual(set, ["1"])
    }

    func testOrderingInFlightAndErrorsFirstThenNewestLikeFirst() {
        let failed = LikeAddAttempt(atMs: now - hour, state: .failed, message: "no", writeToken: nil, recorded: false)
        let r = select(
            accepted: ["rel:old": now - 5 * day, "rel:new": now - hour, "rel:err": now - 9 * day,
                       "rel:busy": now - 20 * day],
            meta: [rel("old"), rel("new"), rel("err", attempt: failed), rel("busy")],
            inFlight: ["busy"])
        XCTAssertEqual(r.rows.map(\.id), ["busy", "err", "new", "old"])
        XCTAssertTrue(r.rows[0].inFlight)
    }

    func testStoreIdParsing() {
        XCTAssertEqual(LikedReleaseSelection.storeId(fromFeedbackId: "rel:123"), "123")
        XCTAssertNil(LikedReleaseSelection.storeId(fromFeedbackId: "relartist:123"))
        XCTAssertNil(LikedReleaseSelection.storeId(fromFeedbackId: "rel:"))
    }

    // MARK: row copy (pure)

    @MainActor func testActionTitlesAndStatusLines() {
        let base = LikedRow(release: rel("1"), acceptedAtMs: now, inFlight: false,
                            retryWriteOnly: false, message: nil)
        XCTAssertEqual(NewReleasesView.likedActionTitle(base), "Add")
        var retry = base; retry.retryWriteOnly = true
        XCTAssertEqual(NewReleasesView.likedActionTitle(retry), "Retry Apple Music")
        var failed = base
        failed.release.attempt = LikeAddAttempt(atMs: now, state: .failed, message: "boom", writeToken: nil, recorded: false)
        XCTAssertEqual(NewReleasesView.likedActionTitle(failed), "Retry")
        XCTAssertEqual(NewReleasesView.likedStatusLine(failed, nowMs: now), "boom")
        var busy = base; busy.inFlight = true
        XCTAssertEqual(NewReleasesView.likedStatusLine(busy, nowMs: now), "Adding…")
        var offline = base
        offline.release.attempt = LikeAddAttempt(atMs: now, state: .offline, message: nil, writeToken: nil, recorded: false)
        XCTAssertEqual(NewReleasesView.likedStatusLine(offline, nowMs: now), NewReleaseLikeAdder.offlineMessage)
        XCTAssertNil(NewReleasesView.likedStatusLine(base, nowMs: now))
    }
}
