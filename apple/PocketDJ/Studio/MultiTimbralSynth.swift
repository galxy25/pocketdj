import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Multitimbral replay synth (polyphonic multi-staff playback)

/// ONE Apple `kAudioUnitSubType_MIDISynth` AU voicing up to four staffs at once: the ONE shared
/// SoundFont is loaded ONCE (`kMusicDeviceProperty_SoundBankURL`), then addressed per MIDI
/// channel with per-staff GM programs — the 32 MB font is never duplicated for polyphony
/// (the `AVAudioUnitSampler` can hold only one program at a time; this AU is the standard
/// multitimbral sibling). Owned by `InstrumentEngine`, attached lazily on the first polyphonic
/// replay as `synth → instrumentMix` (inside the permanent take tap, upstream of the click).
///
/// `@unchecked Sendable` for the SAME reason `InstrumentRealtimeBridge` is: the 32 MB bank
/// parse runs off the main actor while the engine's `synthReady` gate is closed — nothing else
/// talks to the AU for the parse's duration, and the AU itself enqueues MIDI safely from any
/// thread.
final class MultiTimbralSynth: @unchecked Sendable {

    /// The AVAudioEngine node (attach + connect on the main actor; MIDI from any thread).
    let node: AVAudioUnitMIDIInstrument

    /// The bank the AU currently holds (nil until the first successful load) — the idempotence
    /// key for `loadBank` (same URL ⇒ no reparse).
    private(set) var loadedBankURL: URL?

    init() {
        let desc = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice,
                                             componentSubType: kAudioUnitSubType_MIDISynth,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        node = AVAudioUnitMIDIInstrument(audioComponentDescription: desc)
    }

    /// Point the AU at the shared SoundFont (the actual sample parse happens per-program in
    /// `setPrograms`' preload dance). Idempotent per URL. Returns success.
    @discardableResult
    func loadBank(_ url: URL) -> Bool {
        if loadedBankURL == url { return true }
        var bankURL = url as CFURL
        let status = AudioUnitSetProperty(node.audioUnit,
                                          AudioUnitPropertyID(kMusicDeviceProperty_SoundBankURL),
                                          AudioUnitScope(kAudioUnitScope_Global), 0,
                                          &bankURL, UInt32(MemoryLayout<CFURL>.size))
        if status == noErr { loadedBankURL = url }
        return status == noErr
    }

    /// Assign per-channel GM programs, PRELOADING their samples (Apple's documented
    /// `kAUMIDISynthProperty_EnablePreload` dance: enable → program changes load samples →
    /// disable → real program changes select them). Safe to call repeatedly — reassignments
    /// load only what's missing.
    func setPrograms(_ assignments: [(channel: Int, program: UInt8)]) {
        var enabled: UInt32 = 1
        AudioUnitSetProperty(node.audioUnit,
                             AudioUnitPropertyID(kAUMIDISynthProperty_EnablePreload),
                             AudioUnitScope(kAudioUnitScope_Global), 0,
                             &enabled, UInt32(MemoryLayout<UInt32>.size))
        for a in assignments {
            node.sendProgramChange(a.program, onChannel: UInt8(clamping: max(0, min(15, a.channel))))
        }
        enabled = 0
        AudioUnitSetProperty(node.audioUnit,
                             AudioUnitPropertyID(kAUMIDISynthProperty_EnablePreload),
                             AudioUnitScope(kAudioUnitScope_Global), 0,
                             &enabled, UInt32(MemoryLayout<UInt32>.size))
        for a in assignments {
            node.sendProgramChange(a.program, onChannel: UInt8(clamping: max(0, min(15, a.channel))))
        }
    }

    func startNote(_ note: UInt8, velocity: UInt8, channel: UInt8) {
        node.startNote(note, withVelocity: velocity, onChannel: channel)
    }

    func stopNote(_ note: UInt8, channel: UInt8) {
        node.stopNote(note, onChannel: channel)
    }

    /// CC 123 all-notes-off on the four staff channels (belt-and-braces silence on stop).
    func allNotesOff() {
        for ch: UInt8 in 0...3 { node.sendController(123, withValue: 0, onChannel: ch) }
    }
}
