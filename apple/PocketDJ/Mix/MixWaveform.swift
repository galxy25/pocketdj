import SwiftUI
import AVFoundation

/// Computes a compact waveform (≈200 normalized peaks) from a burned audio file, OFF the main
/// thread. PRIMARY path of the spec's two-tier waveform: local + deterministic — read the burned
/// file with AVAudioFile; for an ANALOG shared-album file window `[startMs, startMs+lengthMs]` so
/// the deck shows THIS song's slice (not the rest of the side); downsample to `targetCount`
/// absolute-peak buckets; normalize 0...1. Pure given `(url, window)` — trivially testable.
enum WaveformExtractor {
    static let defaultPeakCount = 200

    /// Extract `targetCount` normalized peaks from `url`. Pass an analog file's `startMs` +
    /// `lengthMs` to window to its slice; nil for a digital per-song file (whole file). Returns
    /// [] on any failure (unreadable / empty / zero frames) so the caller falls back to a flat
    /// placeholder. Decodes on a background task — not instant; await it.
    static func peaks(url: URL, startMs: Int? = nil, lengthMs: Int? = nil,
                      targetCount: Int = defaultPeakCount) async -> [Float] {
        await Task.detached(priority: .utility) {
            extractSync(url: url, startMs: startMs, lengthMs: lengthMs, targetCount: targetCount)
        }.value
    }

    /// Synchronous core (background executor). Streams the windowed frames in capped chunks (so a
    /// long album file never allocates a giant buffer), folding each bucket's ABSOLUTE PEAK
    /// (max |sample| across channels), then normalizes the buckets to 0...1.
    private static func extractSync(url: URL, startMs: Int?, lengthMs: Int?, targetCount: Int) -> [Float] {
        guard targetCount > 0, let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = file.length
        guard sampleRate > 0, totalFrames > 0 else { return [] }

        // WINDOW: clamp [startMs, startMs+lengthMs] to the file (analog slice). Digital files
        // (startMs == nil) read whole; a missing lengthMs reads to EOF.
        let startFrame = startMs.map { AVAudioFramePosition(Double($0) / 1000.0 * sampleRate) } ?? 0
        let clampedStart = max(0, min(startFrame, totalFrames))
        let windowFrames: AVAudioFramePosition
        if let lengthMs {
            let len = AVAudioFramePosition(Double(lengthMs) / 1000.0 * sampleRate)
            windowFrames = max(0, min(len, totalFrames - clampedStart))
        } else {
            windowFrames = totalFrames - clampedStart
        }
        guard windowFrames > 0 else { return [] }
        file.framePosition = clampedStart

        let framesPerBucket = max(1, Int(windowFrames) / targetCount)
        let chunkCapacity: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else { return [] }

        var peaks = [Float](repeating: 0, count: targetCount)
        var remaining = Int(windowFrames)
        var consumed = 0    // frames consumed within the window (for bucket indexing)

        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(remaining, Int(chunkCapacity)))
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: toRead) } catch { break }
            let read = Int(buffer.frameLength)
            if read == 0 { break }                          // EOF
            guard let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)
            for i in 0..<read {
                var amp: Float = 0
                for c in 0..<channelCount { amp = max(amp, abs(channels[c][i])) }
                let bucket = min(targetCount - 1, (consumed + i) / framesPerBucket)
                if amp > peaks[bucket] { peaks[bucket] = amp }
            }
            consumed += read
            remaining -= read
        }

        // Normalize against the loudest bucket so quiet rips still fill the view.
        let maxPeak = peaks.max() ?? 0
        guard maxPeak > 0 else { return [] }
        return peaks.map { $0 / maxPeak }
    }
}

/// BurnStore-aware waveform helper the deck view calls. Resolves the song's burned file (HOLDING
/// its security scope across the read, then releasing), windows an analog file from its startMs,
/// and returns the normalized peaks. [] when the song isn't locally burned.
enum MixWaveform {
    /// `lengthMs` is the song's duration (`IndexSong.length`); pass it so an ANALOG shared-album
    /// file windows to `[startMs, startMs+length]` rather than running to EOF (the rest of the
    /// side). A digital per-song file (startMs == nil) ignores it and reads the whole file.
    @MainActor
    static func peaks(forSong songId: String, lengthMs: Int? = nil, burns: BurnStore) async -> [Float] {
        guard let handle = burns.localURLForPlaybackPreferringCut(forSong: songId) else { return [] }
        defer { handle.release?() }   // hold the scope across the read, then release it
        // PREFER the per-song cut (same file the deck plays). A cut already IS the song (read the
        // whole file); only the shared-album fallback needs the [startMs, startMs+length] window —
        // so the waveform always matches what's actually playing on the deck.
        let startMs = handle.isCut ? nil : burns.startMs(forSong: songId)
        return await WaveformExtractor.peaks(url: handle.url, startMs: startMs,
                                             lengthMs: startMs != nil ? lengthMs : nil)
    }
}

/// StudioStore-aware waveform helper — the studio analog of `MixWaveform`. Resolves a performance
/// item's local file (`localURLForPlayback`, holding its scope across the read) and extracts the
/// same normalized peaks. [] when the item can't resolve (a placeholder instrumental that hasn't
/// rendered yet, a deleted item). Used for the item's waveform in collection rows + Now Playing.
enum StudioWaveform {
    @MainActor
    static func peaks(forStudioId id: String, studio: StudioStore) async -> [Float] {
        guard let handle = studio.localURLForPlayback(id: id) else { return [] }
        defer { handle.release?() }
        return await WaveformExtractor.peaks(url: handle.url)
    }
}

/// A compact deck waveform — `peaks` are ≈200 values in 0...1 (WaveformExtractor output). Draws a
/// center-mirrored bar per peak via Canvas (cheap; redraws only when `peaks` changes). EMPTY
/// `peaks` renders a flat baseline placeholder. (Named `MixWaveformView` to avoid colliding with
/// the file-private `WaveformView(url:)` in CollectionSongRow.swift.)
struct MixWaveformView: View {
    var peaks: [Float]
    var color: Color = Theme.accent
    var background: Color = Theme.bgOverlay

    var body: some View {
        Group {
            if peaks.isEmpty {
                Rectangle()                       // flat baseline placeholder
                    .fill(color.opacity(0.25))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)
            } else {
                Canvas { ctx, size in
                    let count = peaks.count
                    let barW = size.width / CGFloat(count)
                    let mid = size.height / 2
                    var bars = Path()
                    for (i, p) in peaks.enumerated() {
                        let amp = CGFloat(max(0, min(1, p)))
                        let barH = max(1, amp * size.height)
                        bars.addRect(CGRect(x: CGFloat(i) * barW, y: mid - barH / 2,
                                            width: max(0.5, barW - 0.5), height: barH))
                    }
                    ctx.fill(bars, with: .color(color))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }
}
