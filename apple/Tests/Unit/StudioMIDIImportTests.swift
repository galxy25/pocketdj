import XCTest
import AudioToolbox
@testable import PocketDJ

/// StudioMIDIImport — synthesize a Standard MIDI File with known notes at a known tempo, write it to
/// a temp file, parse it back, and check the note stream + tempo survive. Hermetic (AudioToolbox +
/// a temp file, no engine).
final class StudioMIDIImportTests: XCTestCase {

    /// Build a one-track MIDI file at `bpm` with the given (note, startBeat, durationBeats) notes.
    private func writeMIDI(bpm: Double, notes: [(UInt8, MusicTimeStamp, Float32)]) throws -> URL {
        var seq: MusicSequence?
        XCTAssertEqual(NewMusicSequence(&seq), noErr)
        let sequence = seq!
        defer { DisposeMusicSequence(sequence) }

        var tempoTrack: MusicTrack?
        MusicSequenceGetTempoTrack(sequence, &tempoTrack)
        MusicTrackNewExtendedTempoEvent(tempoTrack!, 0, bpm)

        var track: MusicTrack?
        MusicSequenceNewTrack(sequence, &track)
        for (note, start, dur) in notes {
            var msg = MIDINoteMessage(channel: 0, note: note, velocity: 100, releaseVelocity: 0, duration: dur)
            MusicTrackNewMIDINoteEvent(track!, start, &msg)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-midi-\(UUID().uuidString).mid")
        XCTAssertEqual(MusicSequenceFileCreate(sequence, url as CFURL, .midiType, .eraseFile, 0), noErr)
        return url
    }

    func testParsesNotesAndTempo() throws {
        // 120 bpm ⇒ 1 beat = 500 ms. Three notes: C4 @0 for 1 beat, E4 @1 for 1 beat, G4 @2 for 2 beats.
        let url = try writeMIDI(bpm: 120, notes: [(60, 0, 1), (64, 1, 1), (67, 2, 2)])
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try StudioMIDIImport.parse(url: url)

        XCTAssertEqual(r.bpm, 120, accuracy: 0.5)
        XCTAssertEqual(r.events.count, 3)
        XCTAssertEqual(r.events.map(\.note), [60, 64, 67])           // sorted by onset
        XCTAssertEqual(r.events[0].onMs, 0)
        XCTAssertEqual(r.events[0].offMs, 500, accuracy: 8)          // 1 beat @120
        XCTAssertEqual(r.events[1].onMs, 500, accuracy: 8)
        XCTAssertEqual(r.events[2].onMs, 1000, accuracy: 8)
        XCTAssertEqual(r.events[2].offMs, 2000, accuracy: 12)        // 2 beats
        XCTAssertEqual(r.durationMs, 2000, accuracy: 12)
    }

    func testTempoAffectsTiming() throws {
        // Same note pattern at 60 bpm ⇒ 1 beat = 1000 ms, so everything is twice as long.
        let url = try writeMIDI(bpm: 60, notes: [(60, 0, 1), (62, 1, 1)])
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try StudioMIDIImport.parse(url: url)
        XCTAssertEqual(r.bpm, 60, accuracy: 0.5)
        XCTAssertEqual(r.events[0].offMs, 1000, accuracy: 12)        // 1 beat @60 = 1 s
        XCTAssertEqual(r.events[1].onMs, 1000, accuracy: 12)
    }

    func testEmptyFileThrowsNoNotes() throws {
        let url = try writeMIDI(bpm: 120, notes: [])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try StudioMIDIImport.parse(url: url)) { error in
            XCTAssertEqual(error as? StudioMIDIImport.ImportError, .noNotes)
        }
    }
}
