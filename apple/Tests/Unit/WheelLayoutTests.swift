import XCTest
@testable import PocketDJ

/// Pocket Wheel Phase 3 — the pure wheel geometry: ring radii (fisheye + weekend gap), polar
/// hit-testing at ring and hour boundaries, sliver widths and their 20 % floor.
final class WheelLayoutTests: XCTestCase {

    private let c = CGPoint(x: 200, y: 200)

    private func moment(_ dow: Int, _ hour: Int, _ mode: PocketMode, plays: Double) -> PocketMoment {
        var m = PocketMoment(key: .init(hour: hour, dow: dow, mode: mode))
        m.plays = plays
        return m
    }

    func testRingsMondayInnermostFocusedThickerWeekendGap() {
        let l = WheelLayout(radius: 175, focusedDow: 2, modeFilter: nil, moments: [])
        XCTAssertEqual(l.rings.map(\.dow), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(l.rings[0].inner, 175 * WheelLayout.holeFraction, accuracy: 0.001, "Monday starts at the hole")
        XCTAssertEqual(l.rings[6].outer, 175, accuracy: 0.001, "Sunday ends at the rim")
        let unfocused = l.rings[0].thickness
        XCTAssertEqual(l.rings[1].thickness / unfocused, WheelLayout.focusScale, accuracy: 0.0001, "Tuesday is the fisheye")
        XCTAssertTrue(l.rings[1].focused)
        for i in 0..<6 { XCTAssertLessThan(l.rings[i].outer, l.rings[i + 1].inner, "rings never overlap") }
        let weekdayGap = l.rings[4].inner - l.rings[3].outer
        let weekendGap = l.rings[5].inner - l.rings[4].outer
        XCTAssertGreaterThan(weekendGap, weekdayGap * 3, "Fri | Sat gap marks the weekend")
        // The design numbers on a 390 pt phone (R = 175): focused ≈ 26 pt, others ≈ 14 pt.
        XCTAssertEqual(l.rings[1].thickness, 26, accuracy: 3)
        XCTAssertEqual(unfocused, 14, accuracy: 2)
    }

    func testAnglesAndPointsRoundTrip() {
        XCTAssertEqual(WheelLayout.angle(forHour: 6), .pi / 2, accuracy: 1e-12)
        // 12 o'clock is midnight, 3 o'clock is 6 AM.
        let top = WheelLayout.point(radius: 100, angle: 0, center: c)
        XCTAssertEqual(top.x, 200, accuracy: 1e-9); XCTAssertEqual(top.y, 100, accuracy: 1e-9)
        let right = WheelLayout.point(radius: 100, angle: .pi / 2, center: c)
        XCTAssertEqual(right.x, 300, accuracy: 1e-9); XCTAssertEqual(right.y, 200, accuracy: 1e-9)
        for a in stride(from: 0.01, to: 2 * Double.pi, by: 0.37) {
            XCTAssertEqual(WheelLayout.angle(of: WheelLayout.point(radius: 80, angle: a, center: c), center: c), a, accuracy: 1e-9)
        }
    }

    func testHitTestRingsHoursAndBoundaries() {
        let ms = [moment(2, 8, .carPlay, plays: 5), moment(2, 9, .mix, plays: 2), moment(7, 23, .collection, plays: 1)]
        let l = WheelLayout(radius: 175, focusedDow: 2, modeFilter: nil, moments: ms)
        XCTAssertEqual(l.hit(c, center: c), .center)
        XCTAssertEqual(l.hit(CGPoint(x: 200, y: 200 - 176), center: c), .outside)
        let tue = l.rings[1]
        // Mid-hour 8.5 on Tuesday's ring.
        XCTAssertEqual(l.hit(WheelLayout.point(radius: tue.mid, angle: WheelLayout.angle(forHour: 8.5), center: c), center: c),
                       .cell(dow: 2, hour: 8, key: .init(hour: 8, dow: 2, mode: .carPlay)))
        // Just past the 9 o'clock boundary → hour 9 (its own mode).
        XCTAssertEqual(l.hit(WheelLayout.point(radius: tue.mid, angle: WheelLayout.angle(forHour: 9) + 1e-6, center: c), center: c),
                       .cell(dow: 2, hour: 9, key: .init(hour: 9, dow: 2, mode: .mix)))
        // Just before midnight on the outermost ring → Sunday 23.
        let sun = l.rings[6]
        XCTAssertEqual(l.hit(WheelLayout.point(radius: sun.mid, angle: 2 * .pi - 1e-6, center: c), center: c),
                       .cell(dow: 7, hour: 23, key: .init(hour: 23, dow: 7, mode: .collection)))
        // An empty cell hits with no key.
        XCTAssertEqual(l.hit(WheelLayout.point(radius: l.rings[3].mid, angle: WheelLayout.angle(forHour: 3.5), center: c), center: c),
                       .cell(dow: 4, hour: 3, key: nil))
        // A point in the gap between Mon and Tue snaps to the nearer ring.
        let gapMid = (l.rings[0].outer + l.rings[1].inner) / 2
        let nearTue = gapMid + 0.1
        if case .cell(let d, _, _) = l.hit(WheelLayout.point(radius: nearTue, angle: 1, center: c), center: c) {
            XCTAssertEqual(d, 2)
        } else { XCTFail("gap hit should resolve to a ring") }
    }

    func testSliverSharesAndFloor() {
        XCTAssertEqual(WheelLayout.sliverShares([3]), [1])
        XCTAssertEqual(WheelLayout.sliverShares([1, 1]), [0.5, 0.5])
        let s = WheelLayout.sliverShares([10, 1, 1])
        XCTAssertEqual(s[0], 0.6, accuracy: 1e-9)
        XCTAssertEqual(s[1], 0.2, accuracy: 1e-9)
        XCTAssertEqual(s[2], 0.2, accuracy: 1e-9)
        let t = WheelLayout.sliverShares([6, 3, 1])
        XCTAssertEqual(t.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(t[2], 0.2, accuracy: 1e-9, "floored")
        XCTAssertEqual(t[0] / t[1], 2, accuracy: 1e-9, "the rest stay proportional")
    }

    func testCellSplitsIntoTopThreeModesInPrecedenceOrder() {
        let ms = [moment(3, 21, .collection, plays: 1), moment(3, 21, .mix, plays: 8),
                  moment(3, 21, .carPlay, plays: 3), moment(3, 21, .browse, plays: 0.5)]
        let l = WheelLayout(radius: 175, focusedDow: 3, modeFilter: nil, moments: ms)
        let cell = try! XCTUnwrap(l.cell(dow: 3, hour: 21))
        XCTAssertEqual(cell.slivers.map(\.key.mode), [.carPlay, .mix, .collection], "top 3 by plays, drawn in §1.3 order")
        XCTAssertEqual(cell.slivers.first!.start, WheelLayout.angle(forHour: 21), accuracy: 1e-12)
        XCTAssertEqual(cell.slivers.last!.end, WheelLayout.angle(forHour: 22), accuracy: 1e-9, "slivers tile the hour")
        XCTAssertGreaterThanOrEqual(cell.slivers.map(\.share).min()!, 0.2 - 1e-9)
    }

    func testModeFilterShowsOnlyThatModeFullWidth() {
        let ms = [moment(6, 9, .running, plays: 4), moment(6, 9, .collection, plays: 9), moment(2, 8, .carPlay, plays: 3)]
        let l = WheelLayout(radius: 175, focusedDow: 6, modeFilter: .running, moments: ms)
        XCTAssertEqual(l.cells.count, 1)
        XCTAssertEqual(l.cells[0].slivers.map(\.key.mode), [.running])
        XCTAssertEqual(l.cells[0].slivers[0].share, 1)
    }

    func testAccessibilityValueNamesModesCollectionsAndCounts() {
        var a = moment(2, 8, .carPlay, plays: 10); a.dominantCollectionId = "pl_pot"; a.directPlays = 23
        var b = moment(2, 8, .mix, plays: 3); b.dominantCollectionId = "pkt_late"; b.directPlays = 6
        let l = WheelLayout(radius: 175, focusedDow: 2, modeFilter: nil, moments: [a, b])
        let v = PocketWheelAccessibility.value(dow: 2, hour: 8, layout: l, index: [a.key: a, b.key: b],
                                               names: ["pl_pot": "Potential", "pkt_late": "Late Night"])
        XCTAssertTrue(v.hasPrefix("8 AM, CarPlay: Potential, 23 plays"), v)
        XCTAssertTrue(v.contains("also Mix: Late Night, 6 plays"), v)
        XCTAssertEqual(PocketWheelAccessibility.value(dow: 1, hour: 3, layout: l, index: [:], names: [:]), "3 AM, nothing yet")
    }

    func testDemoSeedPaintsEveryMode() {
        let snap = PocketMomentEngine.build(PocketWheelDemo.input(nowMs: 1_793_215_800_000, tzOffsetMin: -420))
        let modes = Set(snap.moments.filter { $0.directPlays > 0 }.map(\.key.mode))
        XCTAssertTrue(modes.isSuperset(of: [.carPlay, .running, .walking, .trip, .mix, .browse, .collection]), "\(modes)")
        XCTAssertEqual(snap.dominanceOrder.first, "pl_potential")
    }
}
