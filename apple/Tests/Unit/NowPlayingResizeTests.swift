import XCTest
@testable import PocketDJ

/// The resizable Now Playing surface's pure geometry (`NowPlayingResize`):
/// drag clamping, dock/expand commitment, portrait snap points + fling bias,
/// and the platter-centering arithmetic. All value-in/value-out — no views.
final class NowPlayingResizeTests: XCTestCase {

    // MARK: clampedSize

    func testClampedSizeBoundsToDockAndWindow() {
        XCTAssertEqual(NowPlayingResize.clampedSize(100, window: 1000, dock: 220), 220)
        XCTAssertEqual(NowPlayingResize.clampedSize(1400, window: 1000, dock: 220), 1000)
        XCTAssertEqual(NowPlayingResize.clampedSize(600, window: 1000, dock: 220), 600)
        // Degenerate window (narrower than the dock) never inverts the range.
        XCTAssertEqual(NowPlayingResize.clampedSize(500, window: 100, dock: 220), 220)
    }

    // MARK: isExpanded

    func testIsExpandedThresholdBoundary() {
        let dock: CGFloat = 220
        let t = NowPlayingResize.dockThreshold
        XCTAssertFalse(NowPlayingResize.isExpanded(size: dock, dock: dock))
        XCTAssertFalse(NowPlayingResize.isExpanded(size: dock + t, dock: dock),
                       "exactly at the threshold springs back")
        XCTAssertTrue(NowPlayingResize.isExpanded(size: dock + t + 1, dock: dock))
    }

    // MARK: snappedPortraitFraction

    func testPortraitSnapNearestWithoutFling() {
        XCTAssertEqual(NowPlayingResize.snappedPortraitFraction(0.24, velocity: 0), 0)
        XCTAssertEqual(NowPlayingResize.snappedPortraitFraction(0.26, velocity: 0), 0.5)
        XCTAssertEqual(NowPlayingResize.snappedPortraitFraction(0.74, velocity: 0), 0.5)
        XCTAssertEqual(NowPlayingResize.snappedPortraitFraction(0.76, velocity: 0), 1)
    }

    func testPortraitSnapFlingBiasesOneStepInFlingDirection() {
        // 0.4 is nearest to 0.5 — a downward fling still lands on 0, an upward one on 0.5.
        XCTAssertEqual(NowPlayingResize.snappedPortraitFraction(0.4, velocity: 500), 0.5)
        XCTAssertEqual(NowPlayingResize.snappedPortraitFraction(0.4, velocity: -500), 0)
        // 0.6 is nearest to 0.5 — an upward fling reaches full.
        XCTAssertEqual(NowPlayingResize.snappedPortraitFraction(0.6, velocity: 500), 1)
        XCTAssertEqual(NowPlayingResize.snappedPortraitFraction(0.6, velocity: -500), 0.5)
        // A slow release (under the fling velocity) is nearest-neighbor.
        XCTAssertEqual(NowPlayingResize.snappedPortraitFraction(0.4, velocity: 100), 0.5)
    }

    func testPortraitSnapAlwaysReturnsASnapPoint() {
        for f in stride(from: -0.2, through: 1.2, by: 0.05) {
            for v: CGFloat in [-900, 0, 900] {
                let snapped = NowPlayingResize.snappedPortraitFraction(CGFloat(f), velocity: v)
                XCTAssertTrue(NowPlayingResize.portraitSnaps.contains(snapped),
                              "f=\(f) v=\(v) → \(snapped) is not a snap point")
            }
        }
    }

    // MARK: platterSide

    func testPlatterSideClampsAndTracksShortEdge() {
        // Floor: a slim overlay keeps the docked size class.
        XCTAssertEqual(NowPlayingResize.platterSide(in: CGSize(width: 200, height: 800)), 150)
        // Ceiling: a wall-size window can't inflate the record past legibility.
        XCTAssertEqual(NowPlayingResize.platterSide(in: CGSize(width: 3000, height: 2000)), 440)
        // In range: 0.42 × the short edge, whichever axis is shorter.
        XCTAssertEqual(NowPlayingResize.platterSide(in: CGSize(width: 1000, height: 800)),
                       800 * 0.42, accuracy: 0.001)
        XCTAssertEqual(NowPlayingResize.platterSide(in: CGSize(width: 800, height: 1000)),
                       800 * 0.42, accuracy: 0.001)
        // Monotonic in the short edge.
        let a = NowPlayingResize.platterSide(in: CGSize(width: 700, height: 700))
        let b = NowPlayingResize.platterSide(in: CGSize(width: 900, height: 900))
        XCTAssertLessThan(a, b)
    }

    // MARK: flankLength

    func testFlankLengthSymmetryCentersTheDeck() {
        // 2·flank + deck == panel whenever the deck fits — geometric centering.
        for (panel, deck): (CGFloat, CGFloat) in [(1000, 400), (640, 300), (500, 500)] {
            let flank = NowPlayingResize.flankLength(panel: panel, deck: deck)
            XCTAssertEqual(flank * 2 + deck, panel, accuracy: 0.001)
        }
        // Never negative when the deck overflows the panel.
        XCTAssertEqual(NowPlayingResize.flankLength(panel: 300, deck: 400), 0)
    }

    // MARK: isWideShape

    func testWideShapeBoundaries() {
        XCTAssertTrue(NowPlayingResize.isWideShape(CGSize(width: 640, height: 900)))
        XCTAssertTrue(NowPlayingResize.isWideShape(CGSize(width: 600, height: 400)))
        XCTAssertFalse(NowPlayingResize.isWideShape(CGSize(width: 400, height: 800)))
    }
}
