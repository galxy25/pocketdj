import XCTest
@testable import PocketDJ

/// SMFWriter (Studio/SMFWriter.swift) — hand-decoded fixtures against the SMF spec (§7): VLQ
/// vectors, header/track chunk bytes, the 120 BPM tempo meta (500 000 µs/quarter), and delta
/// times for a known two-note sequence. Byte-literal on purpose: any drift in the writer is a
/// format bug, not a style choice.
final class SMFWriterTests: XCTestCase {

    private func ev(_ on: Int, _ off: Int, _ note: Int, vel: Int = 100) -> StudioNoteEvent {
        StudioNoteEvent(onMs: on, offMs: off, note: note, velocity: vel)
    }

    // MARK: VLQ (the SMF spec's own reference vectors)

    func testVLQReferenceVectors() {
        XCTAssertEqual(SMFWriter.vlq(0x0000_0000), [0x00])
        XCTAssertEqual(SMFWriter.vlq(0x0000_0040), [0x40])
        XCTAssertEqual(SMFWriter.vlq(0x0000_007F), [0x7F])
        XCTAssertEqual(SMFWriter.vlq(0x0000_0080), [0x81, 0x00])
        XCTAssertEqual(SMFWriter.vlq(0x0000_2000), [0xC0, 0x00])
        XCTAssertEqual(SMFWriter.vlq(0x0000_3FFF), [0xFF, 0x7F])
        XCTAssertEqual(SMFWriter.vlq(0x0000_4000), [0x81, 0x80, 0x00])
        XCTAssertEqual(SMFWriter.vlq(0x001F_FFFF), [0xFF, 0xFF, 0x7F])
        XCTAssertEqual(SMFWriter.vlq(0x0FFF_FFFF), [0xFF, 0xFF, 0xFF, 0x7F])
    }

    // MARK: Pure conversions

    func testTempoMetaValue() {
        XCTAssertEqual(SMFWriter.microsecondsPerQuarter(bpm: 120), 500_000)  // the spec'd fixture
        XCTAssertEqual(SMFWriter.microsecondsPerQuarter(bpm: 60), 1_000_000)
        XCTAssertEqual(SMFWriter.microsecondsPerQuarter(bpm: 0), 500_000)    // 0 guards to 120
    }

    func testMsToTicksAt480PPQ() {
        // One quarter at 120 BPM = 500 ms = 480 ticks.
        XCTAssertEqual(SMFWriter.ticks(fromMs: 500, bpm: 120), 480)
        XCTAssertEqual(SMFWriter.ticks(fromMs: 1000, bpm: 120), 960)
        XCTAssertEqual(SMFWriter.ticks(fromMs: 1, bpm: 120), 1)      // 0.96 rounds to 1
        XCTAssertEqual(SMFWriter.ticks(fromMs: -5, bpm: 120), 0)     // clocks don't run backwards
    }

    // MARK: The hand-decoded two-note fixture

    /// C4 quarter then E4 quarter at 120 BPM, piano: the FULL file byte-for-byte, decoded by
    /// hand from the SMF spec. Pins header layout, tempo meta, program change, delta encoding
    /// (480 → 83 60), the off-before-on ordering at a shared tick, and end-of-track.
    func testTwoNoteFileHandDecoded() {
        let data = SMFWriter.write(events: [ev(0, 500, 60), ev(500, 1000, 64, vel: 90)],
                                   bpm: 120, instrument: .piano)
        let expected: [UInt8] = [
            // MThd, length 6, format 0, 1 track, division 480 (0x01E0)
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
            0x00, 0x00, 0x00, 0x01, 0x01, 0xE0,
            // MTrk, length 32
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x20,
            // Δ0 tempo meta: 500000 µs/quarter = 0x07A120
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
            // Δ0 program change, channel 0, piano (GM program 0)
            0x00, 0xC0, 0x00,
            // Δ0 note-on C4 vel 100
            0x00, 0x90, 0x3C, 0x64,
            // Δ480 note-OFF C4 (off sorts BEFORE the next on at the same tick)
            0x83, 0x60, 0x80, 0x3C, 0x40,
            // Δ0 note-on E4 vel 90
            0x00, 0x90, 0x40, 0x5A,
            // Δ480 note-off E4
            0x83, 0x60, 0x80, 0x40, 0x40,
            // Δ0 end-of-track
            0x00, 0xFF, 0x2F, 0x00,
        ]
        XCTAssertEqual([UInt8](data), expected)
    }

    // MARK: Program change from InstrumentKey

    func testProgramChangeUsesGMProgram() {
        // Body layout is deterministic: header(14) + MTrk hdr(8) + tempo(7) puts the program
        // change at bytes 29–31.
        let data = SMFWriter.write(events: [ev(0, 500, 60)], bpm: 120, instrument: .trumpet)
        XCTAssertEqual(data[29], 0x00)               // Δ0
        XCTAssertEqual(data[30], 0xC0)               // program change, channel 0
        XCTAssertEqual(data[31], InstrumentKey.trumpet.gmProgram)  // 56
    }

    // MARK: Robustness clamps

    func testNoteOnVelocityClampsAwayFromZero() {
        // Velocity 0 IS a note-off in MIDI semantics — the writer must clamp to 1, and cap 127.
        let zero = SMFWriter.write(events: [ev(0, 500, 60, vel: 0)], bpm: 120, instrument: .piano)
        XCTAssertEqual(Array([UInt8](zero)[32...35]), [0x00, 0x90, 0x3C, 0x01])
        let loud = SMFWriter.write(events: [ev(0, 500, 60, vel: 400)], bpm: 120, instrument: .piano)
        XCTAssertEqual(Array([UInt8](loud)[32...35]), [0x00, 0x90, 0x3C, 0x7F])
    }

    func testZeroLengthNoteGetsOneTick() {
        // off == on pushes the off to on + 1 tick: Δ between on and off must be 1.
        let data = SMFWriter.write(events: [ev(100, 100, 60)], bpm: 120, instrument: .piano)
        let bytes = [UInt8](data)
        // ...on: Δ96 (0x60) 90 3C 64, then off: Δ1 80 3C 40
        XCTAssertEqual(Array(bytes[32...39]), [0x60, 0x90, 0x3C, 0x64, 0x01, 0x80, 0x3C, 0x40])
    }

    func testOutOfRangeNotesAreSkippedFileStaysValid() {
        // A corrupt event vanishes; the file still carries tempo + program + EOT (body = 14).
        let data = SMFWriter.write(events: [ev(0, 500, 128)], bpm: 120, instrument: .piano)
        let bytes = [UInt8](data)
        XCTAssertEqual(bytes.count, 14 + 8 + 14)
        XCTAssertEqual(Array(bytes[18...21]), [0x00, 0x00, 0x00, 0x0E])  // MTrk length 14
        XCTAssertEqual(Array(bytes.suffix(4)), [0x00, 0xFF, 0x2F, 0x00]) // end-of-track
    }
}
