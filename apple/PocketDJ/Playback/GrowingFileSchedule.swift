import AVFoundation
import Foundation

/// GROWING-FILE SCHEDULING — the decisions every engine that plays a file WHILE IT DOWNLOADS
/// needs, factored out of the Mix deck's streaming mode (`MixEngine.loadStreaming` /
/// `pumpStream`) so the Mix decks and the Now Playing DSP (`NowPlayingDSP.engageStreaming`,
/// np-mix-mode phase 3) attach, hold, resume, append and detect an underrun the SAME way.
/// Shared, not copied — like `StemSync`. Pure functions; no engine state.
///
/// The model (a LAME mp3 written progressively by `MixStreamLoader`'s sink):
///  • an `AVAudioFile` opened on the partial file reports the FULL length from its Xing header
///    and decodes exactly the frames whose bytes are present; an open sees only the bytes present
///    AT OPEN TIME, so every schedule step re-opens the file;
///  • segments chained from successive opens render bit-identical to one segment;
///  • the schedulable FRONTIER is bytes → seconds at the file's byte rate (learned at attach)
///    minus a torn-frame margin, never past the song window's end;
///  • the playhead is never scheduled past the frontier: at the frontier it HOLDS (stall → wait,
///    not silence / crash / skip) and resumes once there is runway again.
enum GrowingFileSchedule {

    // MARK: Tunables (the Mix branch's measured values — `MixEngine` forwards its names here)

    /// Seconds of runway past the playhead needed to START a held playhead (first audio)…
    static let startRunway: Double = 2
    /// …and to RESUME after an underrun / a seek past the frontier (a bigger cushion, so a
    /// marginal network doesn't flap hold ⇄ play every second).
    static let resumeRunway: Double = 4
    /// Bytes counted as present can include a torn trailing mp3 frame; the last stretch before
    /// the byte frontier is never scheduled.
    static let frontierMargin: Double = 1.5
    /// An on-air voice holds this close to the end of what it has scheduled.
    static let underrunLead: Double = 0.05

    // MARK: Byte rate + frontier

    /// Bytes of file per second of audio for a growing LAME mp3. Its header claims the FULL
    /// length up front; a file whose claim couldn't cover even `expectedBytes` at the max mp3
    /// bitrate (320 kbps ≈ 41 KB/s with framing) has no such header — nil ⇒ don't play until the
    /// download completes (its frame→byte map is unknowable mid-flight). No length: the 256 kbps
    /// house rate.
    static func bytesPerSecond(totalFrames: AVAudioFramePosition, sampleRate: Double,
                               expectedBytes: Int64?) -> Double? {
        guard sampleRate > 0, totalFrames > 0 else { return nil }
        let seconds = Double(totalFrames) / sampleRate
        guard let expected = expectedBytes, expected > 0 else {
            return CollectionMixDownloader.bytesPerPlaybackSecond
        }
        guard seconds >= Double(expected) / 41_000 else { return nil }
        return Double(expected) / seconds
    }

    /// The last FILE frame safe to schedule given `bytes` downloaded: bytes → seconds at the
    /// file's byte rate, minus the torn-frame margin, never before the window start. nil rate
    /// (headerless) ⇒ nothing until complete.
    static func playableFrames(bytes: Int64, bytesPerSecond: Double?, sampleRate: Double,
                               startFrame: AVAudioFramePosition) -> AVAudioFramePosition {
        guard let bps = bytesPerSecond, bps > 0 else { return startFrame }
        let seconds = Double(bytes) / bps - frontierMargin
        return max(startFrame, AVAudioFramePosition(max(0, seconds) * sampleRate))
    }

    /// The song's window inside the file: `startMs` into it (an analog album side; nil for a
    /// per-song file / cut), `windowMs` long (nil ⇒ to the file's end). `count` ≤ 0 ⇒ nothing
    /// in the window (a complete file like that can never play).
    static func window(fileLength total: AVAudioFramePosition, sampleRate sr: Double,
                       startMs: Int?, windowMs: Int?) -> (start: AVAudioFramePosition, count: AVAudioFramePosition) {
        let start = min(max(0, AVAudioFramePosition((Double(startMs ?? 0) / 1000.0) * sr)), total)
        let windowed = windowMs.map { AVAudioFramePosition((Double($0) / 1000.0) * sr) }
        let count = windowed.map { min(total - start, max(0, $0)) } ?? (total - start)
        return (start, count)
    }

    /// The schedulable frontier (file frames): the whole window once complete, else the byte
    /// frontier capped at the window's end.
    static func frontier(bytes: Int64, complete: Bool, bytesPerSecond: Double?, sampleRate: Double,
                         start: AVAudioFramePosition, fullEnd: AVAudioFramePosition) -> AVAudioFramePosition {
        if complete { return fullEnd }
        return min(fullEnd, playableFrames(bytes: bytes, bytesPerSecond: bytesPerSecond,
                                           sampleRate: sampleRate, startFrame: start))
    }

    // MARK: Hold / resume / append / underrun

    /// May a HELD playhead at `position` (file frames) start now? A complete file: always (the
    /// window's tail is all there). Otherwise the frontier must be past the playhead by
    /// `runway` seconds — or reach the window's end, whichever comes first.
    static func canStart(position: AVAudioFramePosition, frontier: AVAudioFramePosition,
                         fullEnd: AVAudioFramePosition, complete: Bool, runway: Double,
                         sampleRate: Double) -> Bool {
        if complete { return true }
        let need = min(fullEnd, position + AVAudioFramePosition(max(0, runway) * sampleRate))
        return frontier > position && frontier >= need
    }

    /// Append granularity: small appends while the runway is short, big ones once it's
    /// comfortable — every pending segment pins an open file, so a fast download must not
    /// queue hundreds of them.
    static func appendChunkSeconds(runway: Double) -> Double { runway < 10 ? 1.0 : 15.0 }

    /// Should an on-air voice scheduled up to `scheduledEnd` get the next stretch (to
    /// `frontier`) now? `playFrame` = the playhead (file frames).
    static func shouldAppend(scheduledEnd: AVAudioFramePosition, frontier: AVAudioFramePosition,
                             playFrame: AVAudioFramePosition, sampleRate: Double, complete: Bool) -> Bool {
        guard frontier > scheduledEnd, sampleRate > 0 else { return false }
        if complete { return true }
        let runway = Double(scheduledEnd - playFrame) / sampleRate
        return Double(frontier - scheduledEnd) / sampleRate >= appendChunkSeconds(runway: runway)
    }

    /// An on-air voice reached the end of what it could schedule while more of the song is
    /// still to come (seconds, song-relative): hold there instead of running on over silence.
    static func underrun(position: Double, scheduledEnd: Double, duration: Double) -> Bool {
        scheduledEnd < duration - underrunLead && position >= scheduledEnd - underrunLead
    }

    // MARK: Reach estimate (no file open — cheap enough for a view's eligibility read)

    /// Seconds of the FILE (from its 0:00) a stream's bytes cover, estimated from the byte
    /// fraction × the file's duration, minus the torn-frame margin. nil when either is unknown.
    static func coveredFileSeconds(bytes: Int64, expectedBytes: Int64?, complete: Bool,
                                   fileDurationSeconds: Double?) -> Double? {
        guard let dur = fileDurationSeconds, dur > 0 else { return nil }
        if complete { return dur }
        guard let expected = expectedBytes, expected > 0 else { return nil }
        return max(0, Double(bytes) / Double(expected) * dur - frontierMargin)
    }

    // MARK: The AVAudioFile-decodes-by-EXTENSION trap

    /// `AVAudioFile` picks its decoder from the path EXTENSION, not the bytes: a growing mp3
    /// written under a neutral name (`.part`, `.tmp`, no extension) opens as garbage or not at
    /// all. Only these may be played while they grow.
    static let decodableExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf"]
    static func decodableByExtension(_ url: URL) -> Bool {
        decodableExtensions.contains(url.pathExtension.lowercased())
    }
}
