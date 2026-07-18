import XCTest
@testable import PocketDJ

/// The pride jukebox mark's behavior contract: mode resolution (static / color-cycle /
/// pulse), the deterministic "random for now" palette shuffle, and the pulse math —
/// all pure functions in JukeboxIconClock so the eventual music-sync swap keeps these
/// as the spec.
final class JukeboxIconTests: XCTestCase {

    // MARK: Mode resolution (the Levi truth table)

    func testModeResolution() {
        XCTAssertEqual(JukeboxIconMode.resolve(sessionActive: false, isPlaying: false), .staticIcon)
        // No session ⇒ static even if something is playing (the music isn't the jukebox's).
        XCTAssertEqual(JukeboxIconMode.resolve(sessionActive: false, isPlaying: true), .staticIcon)
        XCTAssertEqual(JukeboxIconMode.resolve(sessionActive: true, isPlaying: false), .colorCycle)
        XCTAssertEqual(JukeboxIconMode.resolve(sessionActive: true, isPlaying: true), .pulse)
    }

    func testModeFlags() {
        XCTAssertFalse(JukeboxIconMode.staticIcon.animatesColors)
        XCTAssertFalse(JukeboxIconMode.staticIcon.pulses)
        XCTAssertTrue(JukeboxIconMode.colorCycle.animatesColors)
        XCTAssertFalse(JukeboxIconMode.colorCycle.pulses)
        XCTAssertTrue(JukeboxIconMode.pulse.animatesColors)
        XCTAssertTrue(JukeboxIconMode.pulse.pulses)
    }

    // MARK: Color stepping

    func testColorStepCadence() {
        let step = JukeboxIconClock.colorStepSeconds
        XCTAssertEqual(JukeboxIconClock.colorStep(at: 0), 0)
        XCTAssertEqual(JukeboxIconClock.colorStep(at: step - 0.01), 0)
        XCTAssertEqual(JukeboxIconClock.colorStep(at: step + 0.01), 1)
        XCTAssertEqual(JukeboxIconClock.colorStep(at: step * 10), 10)
    }

    func testRotationIsDeterministicBoundedAndVaries() {
        let count = JukeboxIconClock.pride.count
        var seen = Set<Int>()
        for s in 0..<50 {
            let r = JukeboxIconClock.rotation(step: s)
            XCTAssertEqual(r, JukeboxIconClock.rotation(step: s), "same step ⇒ same shuffle")
            XCTAssertTrue((0..<count).contains(r))
            seen.insert(r)
        }
        // "Random for now": across 50 steps the shuffle must actually move.
        XCTAssertGreaterThan(seen.count, 1)
    }

    func testEveryStepShowsTheWholeFlag() {
        // The rotation is a bijection: at any step the six regions wear six DISTINCT
        // stripes (the whole flag is always on screen).
        for s in [0, 1, 7, 123, 99_991] {
            let colors = (0..<6).map { JukeboxIconClock.color(region: $0, step: s) }
            XCTAssertEqual(Set(colors.map(String.init(describing:))).count, 6, "step \(s)")
        }
    }

    // MARK: Pulse math

    func testPulseScaleBoundsAndPeriod() {
        let period = JukeboxIconClock.pulsePeriodSeconds
        let amp = JukeboxIconClock.pulseAmplitude
        XCTAssertEqual(JukeboxIconClock.pulseScale(at: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(JukeboxIconClock.pulseScale(at: period / 2), 1.0 + amp, accuracy: 1e-9)
        for i in 0..<200 {
            let t = Double(i) * 0.013
            let scale = JukeboxIconClock.pulseScale(at: t)
            XCTAssertGreaterThanOrEqual(scale, 1.0 - 1e-9)
            XCTAssertLessThanOrEqual(scale, 1.0 + amp + 1e-9)
            XCTAssertEqual(scale, JukeboxIconClock.pulseScale(at: t + period), accuracy: 1e-9,
                           "breathing repeats every period")
        }
    }
}
