import XCTest
@testable import PocketDJ

/// Pocket Wheel Phase 5a — `SetlistPlayer.replaceUpcoming` protection invariants (§4.4), as a
/// property test over random index / queue states, plus canonicalOrder under shuffle, stale uids,
/// pinning on user moves, forced repeat-off and session persistence of `Item.plan`.
@MainActor
final class SetlistPlayerReplaceUpcomingTests: XCTestCase {

    private func makePlayer() -> SetlistPlayer {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        let player = PlayerEngine()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-replace-burns-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = BurnStore(rips: rips, fileURL: url)
        let coordinator = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                              appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        return SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
    }

    private let run = UUID()

    /// Rows: plan per row (nil = manual), pinned flags. Restored HELD at `index` with `positionMs`.
    private func restore(_ p: SetlistPlayer, rows: [(id: String, plan: Bool, pinned: Bool)], index: Int,
                         positionMs: Int, lengthMs: Int = 200_000, shuffle: Bool = false) {
        let snap = PlaybackSessionStore.Snapshot(
            sessionId: "pses_t", source: .init(kind: "pocket", id: PocketWheelIds.runTag(run), name: "Pocket"),
            queue: rows.enumerated().map { i, r in
                PlaybackSessionStore.Row(songId: r.id, title: r.id, artist: "A\(i)", lengthMs: lengthMs, repeatCount: nil,
                                         plan: r.plan ? .init(runId: run, slot: i + 1, collectionId: "c", score: 1, pinned: r.pinned) : nil)
            },
            index: index, positionMs: positionMs, isPlaying: false, shuffleEnabled: shuffle, updatedAt: 0)
        p.restore(from: snap)
    }

    private func replacement(_ id: String) -> SetlistPlayer.Item {
        SetlistPlayer.Item(id: id, title: id, artist: "R", lengthMs: 180_000,
                           plan: .init(runId: run, slot: 0, collectionId: "c", score: 1, pinned: false))
    }

    func testPropertyProtectionInvariants() {
        var rng = SplitMix64(seed: 2026)
        for trial in 0..<200 {
            let p = makePlayer()
            let n = 4 + Int(rng.next() % 12)
            let rows = (0..<n).map { i -> (id: String, plan: Bool, pinned: Bool) in
                let r = rng.next() % 10
                return ("s\(trial)_\(i)", r != 0, r == 1)
            }
            let index = Int(rng.next() % UInt64(n - 1))
            let positionMs = Int(rng.next() % 200_000)
            restore(p, rows: rows, index: index, positionMs: positionMs)
            let before = p.queue
            // Random replacements + removals over ALL rows (incl. played + current).
            var reps: [UUID: SetlistPlayer.Item] = [:]
            var removes: Set<UUID> = []
            for (i, row) in before.enumerated() {
                switch rng.next() % 3 {
                case 0: reps[row.uid] = replacement("r\(trial)_\(i)")
                case 1: removes.insert(row.uid)
                default: break
                }
            }
            p.replaceUpcoming(reps, removing: removes)
            let after = p.queue
            // ≤ index never mutates.
            XCTAssertEqual(after.prefix(index + 1).map(\.uid), before.prefix(index + 1).map(\.uid), "trial \(trial): played/current untouched")
            XCTAssertEqual(p.index, index)
            // Manual + pinned rows survive, unchanged.
            for row in before.dropFirst(index + 1) where row.plan == nil || row.plan?.pinned == true {
                XCTAssertTrue(after.contains { $0.uid == row.uid }, "trial \(trial): protected row kept")
            }
            // The next row only with ≥ 30 s of runway.
            if index + 1 < before.count, 200_000 - positionMs < 30_000 {
                XCTAssertEqual(after[index + 1].uid, before[index + 1].uid, "trial \(trial): next row needs runway")
            }
            // Nothing else appeared out of nowhere.
            let allowed = Set(before.map(\.uid)).union(reps.values.map(\.uid))
            XCTAssertTrue(after.allSatisfy { allowed.contains($0.uid) })
        }
    }

    func testReplacesAndRemovesFreeRowsAndKeepsSlotPosition() {
        let p = makePlayer()
        restore(p, rows: [("a", true, false), ("b", true, false), ("c", true, false), ("d", true, false), ("e", false, false)],
                index: 0, positionMs: 10_000)
        let q = p.queue
        let n = p.replaceUpcoming([q[2].uid: replacement("x")], removing: [q[3].uid, q[4].uid])
        XCTAssertEqual(n, 2, "c replaced, d removed; e is manual")
        XCTAssertEqual(p.queue.map(\.id), ["a", "b", "x", "e"])
        // Stale uid ⇒ no-op.
        XCTAssertEqual(p.replaceUpcoming([UUID(): replacement("y")], removing: [UUID()]), 0)
        XCTAssertEqual(p.queue.map(\.id), ["a", "b", "x", "e"])
    }

    func testNextRowNeedsRunway() {
        let p = makePlayer()
        restore(p, rows: [("a", true, false), ("b", true, false), ("c", true, false)], index: 0, positionMs: 185_000)
        let q = p.queue
        XCTAssertEqual(p.replaceUpcoming([q[1].uid: replacement("x"), q[2].uid: replacement("y")], removing: []), 1)
        XCTAssertEqual(p.queue.map(\.id), ["a", "b", "y"], "15 s left: the next row is protected")
        let rows = p.replaceableUpcomingRows(runId: run)
        XCTAssertEqual(rows.map(\.songId), ["y"])
        XCTAssertEqual(rows.first?.prevSongId, "b")
    }

    func testInFlightRipRowsOnlyTakeInstantReplacements() {
        let p = makePlayer()
        restore(p, rows: [("a", true, false), ("b", true, false), ("c", true, false)], index: 0, positionMs: 10_000)
        p.notePlaybackRipQueued("c")   // a rip for c is now in flight (inside the window)
        XCTAssertTrue(p.ripWindow.requested.contains("c"))
        let q = p.queue
        XCTAssertEqual(p.replaceUpcoming([q[2].uid: replacement("slow")], removing: []), 0, "never trade a capture for a capture")
        p.startsInstantlyOverrideForTesting = { $0 == "fast" ? true : nil }
        XCTAssertEqual(p.replaceUpcoming([q[2].uid: replacement("fast")], removing: []), 1)
        XCTAssertEqual(p.queue.last?.id, "fast")
        XCTAssertTrue(p.replaceableUpcomingRows(runId: run).isEmpty == false)
    }

    func testCanonicalOrderSwapsInPlaceUnderShuffle() {
        let p = makePlayer()
        restore(p, rows: [("a", true, false), ("b", true, false), ("c", true, false), ("d", true, false)],
                index: 0, positionMs: 0, shuffle: true)
        let q = p.queue
        let rep = replacement("x")
        p.replaceUpcoming([q[2].uid: rep], removing: [])
        p.setShuffle(false)   // restore the canonical order: x sits where c was
        XCTAssertEqual(p.queue.map(\.id), ["a", "b", "x", "d"])
    }

    func testUserMovesPinRows() {
        let p = makePlayer()
        restore(p, rows: [("a", true, false), ("b", true, false), ("c", true, false), ("d", true, false)], index: 0, positionMs: 0)
        let c = p.queue[2].uid
        p.moveUpcomingNext(uid: c)
        XCTAssertEqual(p.queue[1].plan?.pinned, true)
        XCTAssertEqual(p.replaceUpcoming([c: replacement("x")], removing: []), 0, "a moved row is the listener's")
        p.moveUpcoming(fromOffsets: [2], toOffset: 0)   // d to the front of Up Next
        XCTAssertEqual(p.queue[1].id, "d")
        XCTAssertEqual(p.queue[1].plan?.pinned, true)
    }

    func testPlanSurvivesTheSessionRoundTripAndRunTagRestores() throws {
        let row = PlaybackSessionStore.Row(songId: "a", title: "a", artist: "A", lengthMs: 1, repeatCount: nil,
                                           plan: .init(runId: run, slot: 7, collectionId: "c", score: 0.5, pinned: true))
        let back = try JSONDecoder().decode(PlaybackSessionStore.Row.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(back.plan, row.plan)
        let legacy = #"{"songId":"a","title":"a","artist":"A"}"#
        XCTAssertNil(try JSONDecoder().decode(PlaybackSessionStore.Row.self, from: Data(legacy.utf8)).plan)
        let p = makePlayer()
        restore(p, rows: [("a", true, false), ("b", true, false)], index: 0, positionMs: 0)
        XCTAssertEqual(p.sourceSetlistId, PocketWheelIds.runTag(run), "the pwr_ tag survives a restore (only puzzle_ tags are dropped)")
        XCTAssertEqual(p.queue[0].plan?.slot, 1)
    }

    func testRunTreatsRepeatAsOffWithoutClobberingTheSticky() {
        let p = makePlayer()
        p.setRepeatMode(.all)
        p.play([replacement("a"), replacement("b")], sourceSetlistId: PocketWheelIds.runTag(run))
        XCTAssertEqual(p.effectiveRepeatMode, .off, "W2: a run is exactly 100 played-through songs")
        XCTAssertEqual(p.repeatMode, .all, "…but the listener's sticky repeat setting is untouched")
        p.play([replacement("c")], sourceSetlistId: "set_ordinary")
        XCTAssertEqual(p.effectiveRepeatMode, .all, "the next ordinary set repeats again")
        p.stop()
    }
}
