import XCTest
@testable import PocketDJ

/// ListeningPlaceEngine — the pure place/trip engine behind listening-pocket location context.
/// Everything here is synthetic visits on a fixed clock: clustering, % time ranks → letters with
/// stable ids, direction-aware trip ids, the lookup rules (incl. the never-pending-past-the-
/// horizon invariant), merge aliases and retention.
final class ListeningPlaceEngineTests: XCTestCase {

    // MARK: - Fixtures

    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private func at(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }

    /// Metres → degrees of latitude (good enough at these distances).
    private func north(_ m: Double) -> Double { m / 111_320 }

    private let homeLat = 45.5, homeLon = -122.6
    private var A: (Double, Double) { (homeLat, homeLon) }
    private var B: (Double, Double) { (homeLat + north(2_200), homeLon) }
    private var C: (Double, Double) { (homeLat + north(6_000), homeLon) }

    /// Deterministic 16-hex ids: 0000000000000001, 0000000000000002, …
    private final class IdGen {
        var n = 0
        func next() -> String { n += 1; return String(format: "%016x", n) }
    }

    private func engine(startedAt hours: Double = -1) -> ListeningPlaceEngine {
        var e = ListeningPlaceEngine()
        e.trackingStartedAt = at(hours)
        return e
    }

    /// One full CLVisit (arrival + departure, or still there when `to` is nil).
    private func stay(_ e: inout ListeningPlaceEngine, _ p: (Double, Double), _ from: Double, _ to: Double?,
                      accuracy: Double = 30, ids: IdGen, now: Double? = nil) {
        let v = LocationVisitSample(latitude: p.0, longitude: p.1, horizontalAccuracy: accuracy,
                                    arrival: at(from), departure: to.map(at))
        e.ingest(v, now: at(now ?? (to ?? from)), newId: ids.next)
    }

    private func placeId(_ e: ListeningPlaceEngine, at hours: Double, now: Double) -> String? {
        if case .settled(let tag) = e.lookup(at: at(hours), now: at(now)), tag.isPlace { return tag.placeId }
        return nil
    }

    private func tripTag(_ e: ListeningPlaceEngine, at hours: Double, now: Double) -> ListeningContextTag? {
        if case .settled(let tag) = e.lookup(at: at(hours), now: at(now)), tag.isTrip { return tag }
        return nil
    }

    // MARK: - Clustering

    func testTwoVisitsEightyMetresApartAreOnePlace() {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, 2, ids: ids)
        stay(&e, (homeLat + north(80), homeLon), 5, 8, ids: ids)
        XCTAssertEqual(e.places.count, 1)
        XCTAssertEqual(e.timeline.count, 2)
        XCTAssertEqual(Set(e.timeline.map(\.placeId)).count, 1)
    }

    func testVisitsTwoKilometresApartAreTwoPlaces() {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, 2, ids: ids)
        stay(&e, (homeLat + north(2_000), homeLon), 3, 5, ids: ids)
        XCTAssertEqual(e.places.count, 2)
        XCTAssertNotEqual(e.places[0].id, e.places[1].id)
    }

    func testLowAccuracyVisitIsDropped() {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, 2, accuracy: 500, ids: ids)
        XCTAssertTrue(e.places.isEmpty)
        XCTAssertTrue(e.timeline.isEmpty)
        XCTAssertTrue(e.rawVisits.isEmpty)
    }

    func testTwoMinuteVisitIsDropped() {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, 2.0 / 60, ids: ids)
        XCTAssertTrue(e.places.isEmpty)
    }

    func testArrivalThenDepartureRedeliveryIsOneStay() {
        // CoreLocation reports the arrival first (departure = distantFuture), then the full visit.
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, nil, ids: ids, now: 0.5)
        XCTAssertEqual(e.timeline.count, 1)
        XCTAssertNil(e.timeline[0].end)
        stay(&e, (homeLat + north(20), homeLon), 0, 3, ids: ids)
        // …and an identical redelivery after a relaunch changes nothing.
        let before = e.places
        stay(&e, (homeLat + north(20), homeLon), 0, 3, ids: ids)
        XCTAssertEqual(e.timeline.count, 1)
        XCTAssertEqual(e.timeline[0].end, at(3))
        XCTAssertEqual(e.places, before)
    }

    // MARK: - Ids

    func testRealIdsAreOpaqueHex() {
        var e = engine()
        e.ingest(LocationVisitSample(latitude: A.0, longitude: A.1, horizontalAccuracy: 20,
                                     arrival: at(0), departure: at(2)), now: at(2))
        e.ingest(LocationVisitSample(latitude: B.0, longitude: B.1, horizontalAccuracy: 20,
                                     arrival: at(2.5), departure: at(4)), now: at(4))
        let placeRe = try! NSRegularExpression(pattern: "^plc_[0-9a-f]{16}$")
        let tripRe = try! NSRegularExpression(pattern: "^trp_[0-9a-f]{16}$")
        for p in e.places {
            XCTAssertNotNil(placeRe.firstMatch(in: p.id, range: NSRange(p.id.startIndex..., in: p.id)), p.id)
        }
        XCTAssertFalse(e.tripIds.isEmpty)
        for t in e.tripIds.values {
            XCTAssertNotNil(tripRe.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), t)
        }
    }

    func testIdsStableAcrossRoundTripAndMoreVisits() throws {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, 8, ids: ids)
        stay(&e, B, 8.5, 17, ids: ids)
        let before = Set(e.places.map(\.id))
        let tripsBefore = e.tripIds

        var decoded = try JSONDecoder().decode(ListeningPlaceEngine.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(Set(decoded.places.map(\.id)), before)
        XCTAssertEqual(decoded.tripIds, tripsBefore)
        XCTAssertEqual(decoded.trackingStartedAt, e.trackingStartedAt)

        stay(&decoded, (A.0 + north(30), A.1), 17.5, 30, ids: ids)
        stay(&decoded, (B.0 - north(30), B.1), 30.5, 40, ids: ids)
        XCTAssertEqual(Set(decoded.places.map(\.id)), before, "more visits at the same places mint nothing")
        for (key, id) in tripsBefore {
            XCTAssertEqual(decoded.tripIds[key], id, "a recurring pair keeps its trip id")
        }
    }

    func testDecodingGarbageFieldsResetsThemInsteadOfThrowing() throws {
        let json = #"{"places": 7, "timeline": [], "tripIds": {"a>b": "trp_1"}, "trackingStartedAt": "nope"}"#
        let e = try JSONDecoder().decode(ListeningPlaceEngine.self, from: Data(json.utf8))
        XCTAssertTrue(e.places.isEmpty)
        XCTAssertEqual(e.tripIds, ["a>b": "trp_1"])
        XCTAssertNil(e.trackingStartedAt)
    }

    // MARK: - Ranks

    func testRanksByShareOfTimeWithThreshold() {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, 10, ids: ids)       // 10 h
        stay(&e, B, 10.5, 13.5, ids: ids)  // 3 h
        stay(&e, C, 14, 14.5, ids: ids)    // 30 min — below minDwellForLabel
        let ranked = e.rankedPlaces(now: at(20))
        XCTAssertEqual(ranked.map(\.label), ["Location A", "Location B"])
        XCTAssertEqual(ranked.map(\.rank), [1, 2])
        XCTAssertEqual(ranked[0].id, placeId(e, at: 1, now: 20))
        XCTAssertEqual(ranked[1].id, placeId(e, at: 11, now: 20))
        XCTAssertEqual(ranked[0].shareOfTime, 10 / 13.5, accuracy: 1e-9)
        XCTAssertEqual(ranked[1].shareOfTime, 3 / 13.5, accuracy: 1e-9)
        XCTAssertFalse(ranked.contains { $0.id == placeId(e, at: 14.2, now: 20) })
    }

    func testRankReshuffleChangesLabelsNotIds() {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, 10, ids: ids)
        stay(&e, B, 10.5, 13.5, ids: ids)
        let a = placeId(e, at: 1, now: 14)!, b = placeId(e, at: 11, now: 14)!
        XCTAssertEqual(e.label(for: .place(a), now: at(14)), "Location A")
        XCTAssertEqual(e.label(for: .place(b), now: at(14)), "Location B")

        stay(&e, B, 14, 40, ids: ids)      // B overtakes A in dwell
        XCTAssertEqual(placeId(e, at: 1, now: 41), a)
        XCTAssertEqual(placeId(e, at: 20, now: 41), b)
        XCTAssertEqual(e.rankedPlaces(now: at(41)).map(\.id), [b, a])
        XCTAssertEqual(e.label(for: .place(b), now: at(41)), "Location A")
        XCTAssertEqual(e.label(for: .place(a), now: at(41)), "Location B")
    }

    func testRankTieBreaksOnOlderPlace() {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, 2, ids: ids)
        stay(&e, B, 3, 5, ids: ids)
        let ranked = e.rankedPlaces(now: at(6))
        XCTAssertEqual(ranked.map(\.id), [placeId(e, at: 1, now: 6)!, placeId(e, at: 4, now: 6)!])
    }

    func testLetterRollover() {
        XCTAssertEqual(ListeningPlaceEngine.letters(1), "A")
        XCTAssertEqual(ListeningPlaceEngine.letters(2), "B")
        XCTAssertEqual(ListeningPlaceEngine.letters(26), "Z")
        XCTAssertEqual(ListeningPlaceEngine.letters(27), "AA")
        XCTAssertEqual(ListeningPlaceEngine.letters(28), "AB")
        XCTAssertEqual(ListeningPlaceEngine.letters(52), "AZ")
        XCTAssertEqual(ListeningPlaceEngine.letters(53), "BA")
        XCTAssertEqual(ListeningPlaceEngine.letters(702), "ZZ")
        XCTAssertEqual(ListeningPlaceEngine.letters(703), "AAA")
    }

    func testTwentySeventhPlaceIsLabelledAA() {
        var e = engine(); let ids = IdGen()
        // 27 places 2 km apart, each with a longer stay than the next.
        var h = 0.0
        for i in 0..<27 {
            let dwell = Double(40 - i)
            stay(&e, (homeLat + north(2_000 * Double(i)), homeLon), h, h + dwell, ids: ids)
            h += dwell + 0.5
        }
        let ranked = e.rankedPlaces(now: at(h))
        XCTAssertEqual(ranked.count, 27)
        XCTAssertEqual(ranked[25].label, "Location Z")
        XCTAssertEqual(ranked[26].label, "Location AA")
    }

    // MARK: - Trips

    /// Two commute days: A −2–8, B 8.5–17, (evening gap > 4 h), A 24–32, B 32.5–41.
    /// A holds the most dwell (18 h vs 17 h), so it ranks "A".
    private func commute(_ e: inout ListeningPlaceEngine, _ ids: IdGen) {
        stay(&e, A, -2, 8, ids: ids)
        stay(&e, B, 8.5, 17, ids: ids)
        stay(&e, A, 24, 32, ids: ids)
        stay(&e, B, 32.5, 41, ids: ids)
    }

    func testRecurringSameDirectionTripReusesOneId() {
        var e = engine(); let ids = IdGen()
        commute(&e, ids)
        let day1 = tripTag(e, at: 8.2, now: 60)!, day2 = tripTag(e, at: 32.2, now: 60)!
        XCTAssertEqual(day1.tripId, day2.tripId)
        XCTAssertEqual(day1.origin, placeId(e, at: 1, now: 60))
        XCTAssertEqual(day1.destination, placeId(e, at: 9, now: 60))

        let trips = e.trips(now: at(60))
        let ab = trips.first { $0.id == day1.tripId }
        XCTAssertEqual(ab?.occurrences, 2)
        XCTAssertEqual(ab?.label, "A → B")
        XCTAssertEqual(e.label(for: day1, now: at(60)), "A → B")
    }

    func testOppositeDirectionIsADifferentTrip() {
        var e = engine(); let ids = IdGen()
        commute(&e, ids)
        stay(&e, A, 41.5, 50, ids: ids)                  // B → A, 30 min
        let ab = tripTag(e, at: 8.2, now: 60)!, ba = tripTag(e, at: 41.2, now: 60)!
        XCTAssertNotEqual(ab.tripId, ba.tripId)
        XCTAssertEqual(ba.origin, ab.destination)
        XCTAssertEqual(ba.destination, ab.origin)
        XCTAssertEqual(e.label(for: ba, now: at(60)), "B → A")
    }

    func testRoundTripToSamePlaceIsLabelledLoop() {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, 8, ids: ids)
        stay(&e, A, 9, 17, ids: ids)                     // left for an hour and came back
        let loop = tripTag(e, at: 8.5, now: 30)!
        XCTAssertEqual(loop.origin, loop.destination)
        XCTAssertEqual(e.label(for: loop, now: at(30)), "A ↺")
    }

    func testGapOverFourHoursIsNotATrip() {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, 8, ids: ids)
        stay(&e, B, 13, 20, ids: ids)                    // 5 h gap
        let a = placeId(e, at: 1, now: 40)!, b = placeId(e, at: 14, now: 40)!
        XCTAssertNil(e.tripIds[ListeningPlaceEngine.tripKey(a, b)])
        // The first 4 h after leaving read as "Leaving A"; the rest of the gap is nowhere.
        let leaving = tripTag(e, at: 9, now: 40)!
        XCTAssertNil(leaving.destination)
        XCTAssertEqual(e.label(for: leaving, now: at(40)), "Leaving A")
        XCTAssertEqual(e.lookup(at: at(12.5), now: at(40)), .settled(.none))
    }

    func testDepartureWithNoArrivalBecomesLeavingAfterTheHorizon() {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, 8, ids: ids)
        XCTAssertEqual(e.lookup(at: at(8.5), now: at(9)), .pending, "mid-trip, destination unknown")
        // Past maxTripDuration with no arrival → settled as Leaving A.
        guard case .settled(let tag) = e.lookup(at: at(8.5), now: at(12.1)) else {
            return XCTFail("expected settled")
        }
        XCTAssertTrue(tag.isTrip)
        XCTAssertNil(tag.destination)
        XCTAssertEqual(tag.origin, placeId(e, at: 1, now: 12.1))
        XCTAssertEqual(e.label(for: tag, now: at(12.1)), "Leaving A")
    }

    // MARK: - Lookup

    func testLookupRules() {
        var e = engine(startedAt: -1); let ids = IdGen()
        stay(&e, A, 0, 8, ids: ids)
        stay(&e, B, 8.5, 17, ids: ids)

        XCTAssertEqual(e.lookup(at: at(4), now: at(30)), .settled(.place(placeId(e, at: 4, now: 30)!)))
        let trip = tripTag(e, at: 8.25, now: 30)
        XCTAssertNotNil(trip)
        XCTAssertEqual(trip?.origin, placeId(e, at: 4, now: 30))
        XCTAssertEqual(trip?.destination, placeId(e, at: 10, now: 30))

        // Recent, after the last departure → pending; the SAME T once time has moved on → settled.
        XCTAssertEqual(e.lookup(at: at(18), now: at(19)), .pending)
        if case .settled = e.lookup(at: at(18), now: at(30)) {} else { XCTFail("should settle past the horizon") }

        // Before tracking started → unavailable.
        XCTAssertEqual(e.lookup(at: at(-2), now: at(30)), .unavailable)
        var off = ListeningPlaceEngine()
        XCTAssertEqual(off.lookup(at: at(4), now: at(30)), .unavailable)
        off.trackingStartedAt = nil
        XCTAssertEqual(off.lookup(at: at(4), now: at(30)), .unavailable)

        // Inside an open stay (still there) → that place, up to now.
        stay(&e, A, 17.5, nil, ids: ids, now: 20)
        XCTAssertEqual(e.lookup(at: at(19.5), now: at(20)), .settled(.place(placeId(e, at: 4, now: 30)!)))
    }

    func testRecentUnclaimedTimeIsPendingThenNone() {
        let e = engine(startedAt: 0)
        XCTAssertEqual(e.lookup(at: at(1), now: at(2)), .pending, "a back-dated visit could still claim it")
        XCTAssertEqual(e.lookup(at: at(1), now: at(7.1)), .settled(.none))
    }

    func testMovementHintClosesTheOpenStayEarly() {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, nil, ids: ids, now: 1)
        // A fix 50 m away doesn't count as leaving; 1 km does.
        e.noteMovement(LocationFixSample(latitude: A.0 + north(50), longitude: A.1, horizontalAccuracy: 20, at: at(2)),
                       now: at(2), newId: ids.next)
        XCTAssertNil(e.timeline.last?.end)
        e.noteMovement(LocationFixSample(latitude: A.0 + north(1_000), longitude: A.1, horizontalAccuracy: 20, at: at(3)),
                       now: at(3), newId: ids.next)
        XCTAssertEqual(e.timeline.last?.end, at(3))
        XCTAssertEqual(e.lookup(at: at(3.2), now: at(3.5)), .pending)
        // The (back-dated) CLVisit departure then lands and wins.
        stay(&e, A, 0, 2.5, ids: ids, now: 4)
        XCTAssertEqual(e.timeline.count, 1)
        XCTAssertEqual(e.timeline.last?.end, at(2.5))
    }

    /// INVARIANT: T older than pendingHorizon before now is NEVER `.pending`, whatever the timeline.
    func testNothingOlderThanTheHorizonIsEverPending() {
        var rng = PlaceEngineRNG(seed: 42)
        for round in 0..<20 {
            var e = engine(startedAt: 0); let ids = IdGen()
            var h = 0.5
            let spots = [A, B, C]
            for _ in 0..<12 {
                let dwell = 0.2 + rng.unit() * 10
                let gap = rng.unit() * 7
                let p = spots[Int(rng.next() % 3)]
                // Some stays are left open (no departure yet) to exercise the in-flight rules.
                let open = rng.unit() < 0.1
                stay(&e, p, h, open ? nil : h + dwell, ids: ids, now: h + dwell)
                h += dwell + gap
            }
            if round % 2 == 0 {
                e.noteMovement(LocationFixSample(latitude: C.0 + north(5_000), longitude: C.1,
                                                 horizontalAccuracy: 10, at: at(h)), now: at(h), newId: ids.next)
            }
            let now = h + rng.unit() * 12
            let horizonH = ListeningContextConstants.pendingHorizon / 3600
            for _ in 0..<300 {
                let t = rng.unit() * max(0, now - horizonH - 0.001)
                XCTAssertNotEqual(e.lookup(at: at(t), now: at(now)), .pending,
                                  "round \(round): t=\(t)h now=\(now)h")
            }
        }
    }

    // MARK: - Merge

    func testDriftingPlacesMergeOlderIdSurvivesAndAliasResolves() {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, 1, ids: ids)                                   // P1
        stay(&e, (A.0 + north(170), A.1), 2, 3, ids: ids)              // P2 (> 150 m → its own place)
        XCTAssertEqual(e.places.count, 2)
        let p1 = placeId(e, at: 0.5, now: 10)!, p2 = placeId(e, at: 2.5, now: 10)!
        let oldTag = ListeningContextTag.place(p2)

        // A long stay between them, nearer P2, drags P2's centroid within 100 m of P1.
        stay(&e, (A.0 + north(85), A.1), 4, 24, ids: ids)
        XCTAssertEqual(e.places.count, 1)
        XCTAssertEqual(e.places[0].id, p1, "the older id survives")
        XCTAssertEqual(e.aliases[p2], p1)
        XCTAssertEqual(e.label(for: oldTag, now: at(30)), "Location A")
        XCTAssertEqual(e.timeline.map(\.placeId), Array(repeating: p1, count: e.timeline.count))
    }

    // MARK: - Prune

    func testPruneDropsOldRawSamplesButKeepsTheTimeline() {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, 8, ids: ids)
        stay(&e, B, 8.5, 17, ids: ids)
        XCTAssertEqual(e.rawVisits.count, 2)
        e.prune(now: at(31 * 24))
        XCTAssertTrue(e.rawVisits.isEmpty)
        XCTAssertEqual(e.timeline.count, 2)
        XCTAssertEqual(e.places.count, 2)
        XCTAssertNotNil(tripTag(e, at: 8.2, now: 31 * 24))
    }

    func testPruneDropsLongUnseenPlacesWithTheirTripsAndAliases() {
        var e = engine(); let ids = IdGen()
        stay(&e, A, 0, 8, ids: ids)
        stay(&e, B, 8.5, 17, ids: ids)
        let b = placeId(e, at: 9, now: 20)!
        stay(&e, A, 181 * 24, 181 * 24 + 5, ids: ids)                 // A seen again; B not for 180 d
        XCTAssertEqual(e.places.map(\.id), [placeId(e, at: 181 * 24 + 1, now: 181 * 24 + 6)!])
        XCTAssertFalse(e.tripIds.keys.contains { $0.contains(b) })
        XCTAssertNil(e.label(for: .place(b), now: at(181 * 24 + 6)), "a pruned id reads as unknown")
    }
}

/// Tiny deterministic RNG for the property test.
private struct PlaceEngineRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
