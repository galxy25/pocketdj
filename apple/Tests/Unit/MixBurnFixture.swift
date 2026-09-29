import Foundation
import AVFoundation
@testable import PocketDJ

/// Burned-song fixture for auto-mix tests. `startAutoMix` now takes OVER both decks — it ejects
/// them and re-loads from its queue, dropping items whose burned file doesn't resolve — so a
/// test's queue items must point at REAL on-disk burns for the mix to start at all (the machine
/// no longer trusts a queue of unresolvable ids). Seeds a BurnStore ledger (the storage-tests
/// Document idiom) with a short sine WAV per song id, rooted in a hermetic temp dir
/// (`appBurnsDirOverride`) so no test can touch this machine's real burned files.
@MainActor
enum MixBurnFixture {
    /// The standard id set the MixEngine suites' auto items draw from.
    static let standardIds = ["x", "y", "z", "a", "b", "c", "q", "only", "s1", "s2", "s3"]

    /// `lengths` overrides the body length (seconds) per song id — needed by the App Store
    /// screenshot renderer, because a deck takes its DURATION from the audio file: with the
    /// default 2 s body a deck renders "0:00 / 0:02" under a title claiming 2:44, and a seeded
    /// mid-track playhead clamps to the end. `shaped` additionally gives the body a song-shaped
    /// amplitude envelope — `WaveformExtractor` normalizes against the loudest bucket, so a
    /// constant-amplitude tone draws a solid block instead of a waveform.
    static func burnStore(ids: [String] = standardIds, rips: RipsStore? = nil,
                          transfers: TransferCoordinator? = nil,
                          lengths: [String: Double] = [:], shaped: Bool = false) throws -> BurnStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixburns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let indexURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixburns-index-\(UUID().uuidString).json")
        var items: [BurnStore.BurnItem] = []
        for id in ids {
            // `.wav`, NOT `.mp3` — AVAudioFile picks its decoder from the EXTENSION.
            let name = "burn-\(id).wav"
            let seconds = lengths[id] ?? 2
            try writeSineWAV(to: dir.appendingPathComponent(name), seconds: seconds,
                             sr: seconds > 60 ? 22_050 : 44_100, shaped: shaped)
            let bytes = (try? FileManager.default
                .attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            items.append(BurnStore.BurnItem(
                songId: id, title: "T-\(id)", artist: "A",
                audioFileName: name, sidecarFileName: "", source: "digital",
                bpm: 120, musicalKey: nil, camelot: "8A",
                durationMs: Int((lengths[id] ?? 2) * 1000), startMs: nil,
                bytes: bytes, rippedAt: nil, downloadedAt: 0, state: .ready,
                error: nil, wasAppStorage: true))
        }
        try JSONEncoder().encode(BurnStore.Document(items: items)).write(to: indexURL)
        let store = BurnStore(
            rips: rips ?? RipsStore(ripsBase: URL(string: "https://rips.test")!,
                                    session: URLSession(configuration: .ephemeral)),
            transfers: transfers, fileURL: indexURL)
        store.appBurnsDirOverride = dir
        return store
    }

    /// A stereo sine WAV at `url` (the burned "audio body" the decks actually open). When
    /// `shaped`, the amplitude follows a song-shaped envelope so the extracted waveform reads as
    /// a track rather than a rectangle (see `burnStore(lengths:shaped:)`).
    static func writeSineWAV(to url: URL, seconds: Double, sr: Double = 44_100,
                             shaped: Bool = false) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData!
        let n = Int(frames)
        for c in 0..<2 {
            for i in 0..<n {
                let base = Float(sin(2.0 * .pi * 440.0 * Double(i) / sr)) * 0.2
                ch[c][i] = shaped ? base * envelope(at: Double(i) / Double(max(n, 1))) : base
            }
        }
        try file.write(from: buf)
    }

    /// Mirrors `BurnStore.showcaseEnvelope` (the in-app screenshot seed): quiet intro, build, two
    /// drops split by a breakdown, fade-out, with a 16th-note pulse so neighbouring waveform
    /// buckets differ. Kept as a copy rather than exposing the private original — this is a test
    /// fixture, and the two are free to drift.
    private static func envelope(at t: Double) -> Float {
        let section: Double
        switch t {
        case ..<0.06:  section = 0.22 + t / 0.06 * 0.18
        case ..<0.20:  section = 0.40 + (t - 0.06) / 0.14 * 0.55
        case ..<0.46:  section = 1.00
        case ..<0.58:  section = 0.42
        case ..<0.62:  section = 0.42 + (t - 0.58) / 0.04 * 0.58
        case ..<0.90:  section = 1.00
        default:       section = max(0.18, 1.0 - (t - 0.90) / 0.10 * 0.82)
        }
        return Float(min(1.0, section * (0.72 + 0.28 * abs(sin(t * .pi * 2 * 360)))))
    }
}
