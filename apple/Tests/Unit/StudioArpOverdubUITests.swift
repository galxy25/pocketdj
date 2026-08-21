import XCTest
@testable import PocketDJ

// MARK: - Arp knob persistence + the live score's overdub staffs (the UI layer's controllers)
//
// The Studio UI round for the arpeggiator + overdub feature: the knob panel persists through
// `SettingsStore.studioArp*` and mirrors into the engine via `ArpSettings.fromPersisted`
// (read-site coalescing — unknown/wild persisted values must degrade, never crash), and the
// LIVE score's overdub staffs live on the engine (`liveExtraStaffs`, in-memory like the live
// staff itself) under the same 4-staff cap as a saved take.

final class ArpKnobPersistenceTests: XCTestCase {

    // MARK: ArpSettings.fromPersisted (the panel → engine mapping)

    func testFromPersistedMapsValidValues() {
        let s = ArpSettings.fromPersisted(order: "exclusive", length: 8, octaves: 3,
                                          swing: 62, latch: false)
        XCTAssertEqual(s.order, .exclusive)
        XCTAssertEqual(s.length, .eighth)
        XCTAssertEqual(s.octaves, 3)
        XCTAssertEqual(s.swingPct, 62)
        XCTAssertFalse(s.latch)
    }

    func testFromPersistedDegradesUnknownAndWildValues() {
        // Unknown order string / length denominator → the defaults (a renamed case or a
        // hand-edited blob re-times, never crashes, the arp).
        let bad = ArpSettings.fromPersisted(order: "zigzag", length: 7, octaves: 9,
                                            swing: 999, latch: true)
        XCTAssertEqual(bad.order, .up)
        XCTAssertEqual(bad.length, .sixteenth)
        XCTAssertEqual(bad.octaves, 4, "octaves clamp to 1…4")
        XCTAssertEqual(bad.swingPct, 75, "swing clamps to 50…75")

        let low = ArpSettings.fromPersisted(order: "down", length: 32, octaves: 0,
                                            swing: 10, latch: true)
        XCTAssertEqual(low.order, .down)
        XCTAssertEqual(low.length, .thirtysecond)
        XCTAssertEqual(low.octaves, 1)
        XCTAssertEqual(low.swingPct, 50)

        let nan = ArpSettings.fromPersisted(order: "order", length: 16, octaves: 2,
                                            swing: .nan, latch: false)
        XCTAssertEqual(nan.swingPct, 50, "non-finite swing degrades to straight")
    }

    // MARK: SettingsStore round-trip (every knob write persists — the click/count-in doctrine)

    @MainActor
    func testArpKnobDefaultsAndRoundTrip() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let s = SettingsStore(defaults: defaults)
        // Fresh install: the panel's documented defaults (up · 1/16 · 1 octave · straight · latch).
        XCTAssertEqual(s.studioArpOrder, "up")
        XCTAssertEqual(s.studioArpLength, 16)
        XCTAssertEqual(s.studioArpOctaves, 1)
        XCTAssertEqual(s.studioArpSwing, 50)
        XCTAssertTrue(s.studioArpLatch)

        s.studioArpOrder = ArpOrder.inclusive.rawValue
        s.studioArpLength = ArpStepLength.quarter.rawValue
        s.studioArpOctaves = 2
        s.studioArpSwing = 66
        s.studioArpLatch = false
        s.persist()

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.studioArpOrder, "inclusive")
        XCTAssertEqual(reloaded.studioArpLength, 4)
        XCTAssertEqual(reloaded.studioArpOctaves, 2)
        XCTAssertEqual(reloaded.studioArpSwing, 66)
        XCTAssertFalse(reloaded.studioArpLatch)
    }
}

// MARK: - Live score overdub staffs (the engine-held, in-memory staffs 2…4)

@MainActor
final class LiveOverdubStaffTests: XCTestCase {

    private func events(_ notes: [Int], startMs: Int = 0) -> [StudioNoteEvent] {
        notes.enumerated().map { i, n in
            StudioNoteEvent(onMs: startMs + i * 250, offMs: startMs + i * 250 + 200,
                            note: n, velocity: 96)
        }
    }

    func testAppendRespectsCapAndRefusesEmpty() {
        let engine = InstrumentEngine()
        defer { engine.teardown() }
        XCTAssertNil(engine.appendLiveExtraStaff(instrument: .harp, events: []),
                     "an empty capture files no staff (no junk)")
        XCTAssertNotNil(engine.appendLiveExtraStaff(instrument: .harp, events: events([60])))
        XCTAssertNotNil(engine.appendLiveExtraStaff(instrument: .violin, events: events([64])))
        XCTAssertNotNil(engine.appendLiveExtraStaff(instrument: .trumpet, events: events([67])))
        // 1 primary + 3 extras = the StudioTake.maxStaffs cap.
        XCTAssertNil(engine.appendLiveExtraStaff(instrument: .piano, events: events([72])),
                     "the 4th extra staff is refused (4 staffs total, primary included)")
        XCTAssertEqual(engine.liveExtraStaffs.count, 3)
        XCTAssertEqual(engine.liveExtraStaffs.map(\.instrument), [.harp, .violin, .trumpet])
    }

    func testEditInstrumentAndDeleteByStaffId() {
        let engine = InstrumentEngine()
        defer { engine.teardown() }
        let a = engine.appendLiveExtraStaff(instrument: .harp, events: events([60]))!
        let b = engine.appendLiveExtraStaff(instrument: .violin, events: events([64]))!

        // Per-staff edit commit (the live staff editor's onEdit).
        let edited = events([61, 62], startMs: 4000)
        engine.setLiveExtraStaffEvents(id: a, events: edited)
        XCTAssertEqual(engine.liveExtraStaffs.first?.events, edited)
        XCTAssertEqual(engine.liveExtraStaffs.last?.events, events([64]), "sibling untouched")

        // Per-staff voice switch.
        engine.setLiveExtraStaffInstrument(id: b, .clarinet)
        XCTAssertEqual(engine.liveExtraStaffs.last?.instrument, .clarinet)

        // Unknown ids are no-ops, never traps.
        engine.setLiveExtraStaffEvents(id: "stf_missing", events: edited)
        engine.setLiveExtraStaffInstrument(id: "stf_missing", .piano)
        XCTAssertEqual(engine.liveExtraStaffs.count, 2)

        engine.deleteLiveExtraStaff(id: a)
        XCTAssertEqual(engine.liveExtraStaffs.map(\.id), [b])
        engine.clearLiveExtraStaffs()
        XCTAssertTrue(engine.liveExtraStaffs.isEmpty)
    }

    /// The full live-overdub pass at the engine level: arm at a position, play, stop, file —
    /// captured events land ABSOLUTE on the score clock and the staff keeps them.
    func testOverdubPassFilesAbsoluteEventsAsLiveStaff() {
        let engine = InstrumentEngine()
        defer { engine.teardown() }
        XCTAssertEqual(engine.overdubCapturedCount, 0, "inactive ⇒ nothing captured")

        XCTAssertTrue(engine.startOverdub(fromMs: 4000))
        XCTAssertEqual(engine.overdubCapturedCount, 0)
        engine.noteOn(60)
        XCTAssertEqual(engine.overdubCapturedCount, 1, "a still-sounding note counts (re-anchor gate)")
        engine.noteOff(60)
        XCTAssertEqual(engine.overdubCapturedCount, 1)

        let captured = engine.stopOverdub()
        XCTAssertEqual(captured.count, 1)
        XCTAssertGreaterThanOrEqual(captured[0].onMs, 4000, "anchored at the chosen position")
        XCTAssertEqual(engine.overdubCapturedCount, 0, "disarmed ⇒ count resets")

        let staffId = engine.appendLiveExtraStaff(instrument: .piano, events: captured)
        XCTAssertNotNil(staffId)
        XCTAssertEqual(engine.liveExtraStaffs.first?.events, captured)
    }
}
