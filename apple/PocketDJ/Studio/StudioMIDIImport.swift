import Foundation
import AudioToolbox

/// Parses a Standard MIDI File into the arranger/instruments note model — `StudioNoteEvent`s in ms
/// (tempo-mapped through the file's tempo track) plus an initial bpm. The caller pairs the result
/// with a chosen `InstrumentKey` to build a `StudioTake`, which then renders through the shared
/// SoundFont exactly like a recorded instrumental (`StudioRender.renderTake`). All note tracks are
/// merged into one event stream (v1: one instrument plays the whole file); channel-10 percussion is
/// dropped since the melodic instruments can't voice it usefully.
enum StudioMIDIImport {
    struct Result: Sendable { var events: [StudioNoteEvent]; var bpm: Double; var durationMs: Int }
    enum ImportError: LocalizedError {
        case cannotOpen, noNotes
        var errorDescription: String? {
            switch self {
            case .cannotOpen: return "That file isn’t a MIDI file we can read."
            case .noNotes: return "No playable notes were found in that MIDI file."
            }
        }
    }

    /// Load + convert. Throws `ImportError` on an unreadable file or one with no melodic notes.
    static func parse(url: URL) throws -> Result {
        var seq: MusicSequence?
        guard NewMusicSequence(&seq) == noErr, let sequence = seq else { throw ImportError.cannotOpen }
        defer { DisposeMusicSequence(sequence) }

        // Some sources need a security scope; harmless when it isn't scoped.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard MusicSequenceFileLoad(sequence, url as CFURL, .midiType, MusicSequenceLoadFlags()) == noErr else {
            throw ImportError.cannotOpen
        }

        // Beat → wall-clock seconds through the file's tempo map (honors tempo changes).
        func seconds(_ beats: MusicTimeStamp) -> Double {
            var s: Float64 = 0
            MusicSequenceGetSecondsForBeats(sequence, beats, &s)
            return Double(s)
        }
        func ms(_ beats: MusicTimeStamp) -> Int { Int((seconds(beats) * 1000).rounded()) }

        // Initial tempo from the first beat's duration (fallback 120 if degenerate).
        let secPerBeat = seconds(1) - seconds(0)
        let bpm = secPerBeat > 1e-6 ? min(max(60.0 / secPerBeat, 20), 300) : 120

        var events: [StudioNoteEvent] = []
        var trackCount: UInt32 = 0
        MusicSequenceGetTrackCount(sequence, &trackCount)
        for i in 0..<trackCount {
            var track: MusicTrack?
            guard MusicSequenceGetIndTrack(sequence, i, &track) == noErr, let t = track else { continue }
            var it: MusicEventIterator?
            guard NewMusicEventIterator(t, &it) == noErr, let iter = it else { continue }
            defer { DisposeMusicEventIterator(iter) }

            var has: DarwinBoolean = false
            MusicEventIteratorHasCurrentEvent(iter, &has)
            while has.boolValue {
                var ts: MusicTimeStamp = 0
                var type: MusicEventType = 0
                var data: UnsafeRawPointer?
                var size: UInt32 = 0
                MusicEventIteratorGetEventInfo(iter, &ts, &type, &data, &size)
                if type == kMusicEventType_MIDINoteMessage, let d = data {
                    let m = d.assumingMemoryBound(to: MIDINoteMessage.self).pointee
                    // Drop channel 10 (0-based 9) percussion — the melodic bank can't voice a kit.
                    if m.channel != 9, m.velocity > 0, m.duration > 0 {
                        let onMs = ms(ts)
                        let offMs = ms(ts + MusicTimeStamp(m.duration))
                        if offMs > onMs {
                            events.append(StudioNoteEvent(onMs: onMs, offMs: offMs,
                                                          note: Int(m.note), velocity: Int(m.velocity)))
                        }
                    }
                }
                MusicEventIteratorNextEvent(iter)
                MusicEventIteratorHasCurrentEvent(iter, &has)
            }
        }
        guard !events.isEmpty else { throw ImportError.noNotes }
        events.sort { $0.onMs == $1.onMs ? $0.note < $1.note : $0.onMs < $1.onMs }
        let roundedBpm = (bpm * 100).rounded() / 100
        let durationMs = events.map { $0.offMs }.max() ?? 0
        return Result(events: events, bpm: roundedBpm, durationMs: durationMs)
    }
}
