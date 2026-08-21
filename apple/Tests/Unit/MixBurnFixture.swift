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

    static func burnStore(ids: [String] = standardIds, rips: RipsStore? = nil,
                          transfers: TransferCoordinator? = nil) throws -> BurnStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixburns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let indexURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixburns-index-\(UUID().uuidString).json")
        var items: [BurnStore.BurnItem] = []
        for id in ids {
            // `.wav`, NOT `.mp3` — AVAudioFile picks its decoder from the EXTENSION.
            let name = "burn-\(id).wav"
            try writeSineWAV(to: dir.appendingPathComponent(name), seconds: 2)
            let bytes = (try? FileManager.default
                .attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            items.append(BurnStore.BurnItem(
                songId: id, title: "T-\(id)", artist: "A",
                audioFileName: name, sidecarFileName: "", source: "digital",
                bpm: 120, musicalKey: nil, camelot: "8A", durationMs: 2_000, startMs: nil,
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

    /// A short stereo sine WAV at `url` (the burned "audio body" the decks actually open).
    static func writeSineWAV(to url: URL, seconds: Double, sr: Double = 44_100) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData!
        for c in 0..<2 {
            for i in 0..<Int(frames) {
                ch[c][i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / sr)) * 0.2
            }
        }
        try file.write(from: buf)
    }
}
