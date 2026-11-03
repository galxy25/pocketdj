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

    /// Bytes of file per second of audio for a growing mp3 — or nil: don't play until the
    /// download completes (its frame→byte map is unknowable mid-flight).
    ///
    /// An `AVAudioFile` opened on a partial mp3 reports the FULL length only when the file
    /// DECLARES it (an Xing/Info/VBRI frame count in its first frame — `lengthClaim(of:)`). A
    /// headerless file's open reports an ESTIMATE from the bytes present; adopted as the song's
    /// window, the completed song would "end" where the partial did. So the open's length is
    /// trusted only on the sniffed claim:
    ///  • `.frameCount` — an Xing / Info / VBRI header: trusted;
    ///  • `.tlen(ms)` — only an ID3 TLEN: NOT trusted. Core Audio ignores TLEN (measured: a
    ///    128 kbps headerless partial with TLEN=12000 opens at 5.0 s at 40 %, 11.2 s at 95 %,
    ///    12.04 s complete), so the open's length is still an estimate — and "agrees with TLEN
    ///    within a tolerance" is exactly true near completion, where it would end the song early;
    ///  • `.absent` / `.undetermined` — nil (the caller holds; `.undetermined` sniffs again);
    ///  • `.container` — not an mp3: the container's length.
    /// A trusted length must ALSO be plausible: one that couldn't cover even `expectedBytes` at
    /// the max mp3 bitrate (320 kbps ≈ 41 KB/s with framing) is not the song's — nil. (That
    /// bitrate test alone was the old detector: a 128 kbps headerless file past ~40 % downloaded
    /// slipped through it and ended early.) No Content-Length: the 256 kbps house rate.
    static func bytesPerSecond(totalFrames: AVAudioFramePosition, sampleRate: Double,
                               expectedBytes: Int64?, claim: LengthClaim) -> Double? {
        guard sampleRate > 0, totalFrames > 0 else { return nil }
        let seconds = Double(totalFrames) / sampleRate
        switch claim {
        case .absent, .undetermined, .tlen:
            return nil
        case .frameCount, .container:
            break
        }
        guard let expected = expectedBytes, expected > 0 else {
            return CollectionMixDownloader.bytesPerPlaybackSecond
        }
        guard seconds >= Double(expected) / 41_000 else { return nil }
        return Double(expected) / seconds
    }

    // MARK: Length claim — does the growing file DECLARE its full length?

    /// What a growing file's leading bytes say about its length.
    enum LengthClaim: Equatable {
        /// An Xing / Info / VBRI frame (non-zero frame count) in the first MPEG frame.
        case frameCount
        /// No frame-count header, but an ID3v2 TLEN (milliseconds).
        case tlen(Int)
        /// The first MPEG frame is here (and verified) and declares nothing: HEADERLESS.
        case absent
        /// Not enough bytes yet to reach and verify the first MPEG frame — sniff again later
        /// (never a verdict: neither attach nor mark headerless).
        case undetermined
        /// Not an mp3 (by extension — AVAudioFile decodes by extension): the container decides.
        case container
    }

    /// Bytes scanned past the ID3 tag(s) for the first MPEG frame (padding / junk tolerated).
    static let sniffScan = 16 * 1024

    /// Sniff `url`'s length claim: reads only the ID3v2 tag(s) and the first frames.
    static func lengthClaim(of url: URL) -> LengthClaim {
        guard url.pathExtension.lowercased() == "mp3" else { return .container }
        guard let h = try? FileHandle(forReadingFrom: url) else { return .undetermined }
        defer { try? h.close() }
        let first = 64 * 1024
        var data = (try? h.read(upToCount: first)) ?? Data()
        // A big tag (cover art) pushes the first frame past the first read: read on to it.
        let tag = id3Span([UInt8](data))
        if data.count == first, tag.end + sniffScan > first {
            data.append((try? h.read(upToCount: min(tag.end + sniffScan - first, 32 * 1024 * 1024))) ?? Data())
        }
        return lengthClaim(in: data)
    }

    /// Pure: the length claim of a (possibly partial) mp3 whose leading bytes are `data`.
    static func lengthClaim(in data: Data) -> LengthClaim {
        let b = [UInt8](data)
        let tag = id3Span(b)
        guard tag.complete else { return .undetermined }
        let limit = min(b.count, tag.end + sniffScan)
        var i = tag.end
        while i + 4 <= limit {
            guard let f = MPEGFrame(b, at: i) else { i += 1; continue }
            // A stray 0xFFE bit pattern isn't a frame: the NEXT frame must follow exactly.
            let next = i + f.length
            guard next + 4 <= b.count else { return .undetermined }
            guard let g = MPEGFrame(b, at: next), g.version == f.version, g.sampleRate == f.sampleRate else {
                i += 1; continue
            }
            if xingFrames(b, frameStart: i, frame: f) > 0 || vbriFrames(b, frameStart: i) > 0 { return .frameCount }
            if let ms = tag.tlenMs, ms > 0 { return .tlen(ms) }
            return .absent
        }
        // No verified frame in what's here: undetermined while the scan window is still filling.
        return b.count < tag.end + sniffScan ? .undetermined : .absent
    }

    /// The leading ID3v2 tag(s): where audio may start, whether the whole tag is present yet,
    /// and its TLEN (ms) when it carries one.
    static func id3Span(_ b: [UInt8]) -> (end: Int, complete: Bool, tlenMs: Int?) {
        let magic: [UInt8] = [0x49, 0x44, 0x33]                                    // "ID3"
        var at = 0
        var tlen: Int?
        for _ in 0..<4 {                                                           // tags can be stacked
            let avail = b.count - at
            if avail < 10 {
                // Too short to read a tag header: undecided only while what's here could still be one.
                let couldBeTag = Array(b[at..<b.count].prefix(3)) == Array(magic.prefix(min(3, avail)))
                return (at, !couldBeTag, tlen)
            }
            guard Array(b[at..<(at + 3)]) == magic else { break }
            let major = b[at + 3], flags = b[at + 5]
            let sizeBytes = Array(b[(at + 6)...(at + 9)])
            guard major >= 2, major <= 4, sizeBytes.allSatisfy({ $0 < 0x80 }) else { break }   // not a tag
            let size = sizeBytes.reduce(0) { ($0 << 7) | Int($1) }
            let end = at + 10 + size + ((major == 4 && flags & 0x10 != 0) ? 10 : 0)
            guard end <= b.count else { return (end, false, tlen) }
            if tlen == nil, flags & 0x80 == 0 {                                    // not unsynchronised
                let ext = extendedHeaderSize(b, at: at, major: major, flags: flags)
                tlen = id3TLEN(b, from: at + 10 + ext, to: at + 10 + size, major: major)
            }
            at = end
        }
        return (at, true, tlen)
    }

    private static func extendedHeaderSize(_ b: [UInt8], at: Int, major: UInt8, flags: UInt8) -> Int {
        guard major >= 3, flags & 0x40 != 0, at + 14 <= b.count else { return 0 }
        let raw = Array(b[(at + 10)...(at + 13)])
        return major == 4 ? raw.reduce(0) { ($0 << 7) | Int($1 & 0x7F) }          // v2.4: includes itself
                          : raw.reduce(0) { ($0 << 8) | Int($1) } + 4             // v2.3: excludes its size field
    }

    private static func id3TLEN(_ b: [UInt8], from: Int, to: Int, major: UInt8) -> Int? {
        let idLen = major == 2 ? 3 : 4, sizeLen = major == 2 ? 3 : 4, hdr = major == 2 ? 6 : 10
        let want = Array((major == 2 ? "TLE" : "TLEN").utf8)
        let end = min(to, b.count)
        var i = max(0, from)
        while i + hdr <= end {
            guard b[i] != 0 else { return nil }                                    // padding
            let size = b[(i + idLen)..<(i + idLen + sizeLen)].reduce(0) { ($0 << (major == 4 ? 7 : 8)) | Int($1) }
            guard size > 0, i + hdr + size <= end else { return nil }
            if Array(b[i..<(i + idLen)]) == want, size > 1 {
                let body = b[(i + hdr + 1)..<(i + hdr + size)]                    // skip the encoding byte
                let digits = body.filter { $0 >= 0x30 && $0 <= 0x39 }
                guard !digits.isEmpty, digits.count <= 10 else { return nil }
                return Int(String(decoding: digits, as: UTF8.self))
            }
            i += hdr + size
        }
        return nil
    }

    /// A Layer III MPEG audio frame header at `i`, or nil.
    struct MPEGFrame {
        let version: Int          // 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5
        let mono: Bool
        let sampleRate: Int
        let length: Int

        init?(_ b: [UInt8], at i: Int) {
            guard i >= 0, i + 4 <= b.count, b[i] == 0xFF, b[i + 1] & 0xE0 == 0xE0 else { return nil }
            let version = Int((b[i + 1] >> 3) & 3), layer = (b[i + 1] >> 1) & 3
            let brIdx = Int(b[i + 2] >> 4), srIdx = Int((b[i + 2] >> 2) & 3), pad = Int((b[i + 2] >> 1) & 1)
            guard version != 1, layer == 1, brIdx != 0, brIdx != 15, srIdx != 3 else { return nil }
            let mpeg1: [Int] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            let mpeg2: [Int] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
            let sr = [44_100, 48_000, 32_000][srIdx] >> (version == 3 ? 0 : version == 2 ? 1 : 2)
            let kbps = (version == 3 ? mpeg1 : mpeg2)[brIdx]
            self.version = version
            self.mono = (b[i + 3] >> 6) == 3
            self.sampleRate = sr
            self.length = (version == 3 ? 144 : 72) * kbps * 1000 / sr + pad
        }
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        guard i >= 0, i + 4 <= b.count else { return 0 }
        return (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])
    }

    /// The Xing/Info frame count declared in the first frame (0 = none / not declared). The tag
    /// sits right after the side info (its size by version × channel mode).
    private static func xingFrames(_ b: [UInt8], frameStart i: Int, frame f: MPEGFrame) -> Int {
        let side = f.version == 3 ? (f.mono ? 17 : 32) : (f.mono ? 9 : 17)
        let o = i + 4 + side
        guard o + 12 <= b.count else { return 0 }
        let tag = Array(b[o..<(o + 4)])
        guard tag == Array("Xing".utf8) || tag == Array("Info".utf8) else { return 0 }
        guard u32(b, o + 4) & 0x1 != 0 else { return 0 }                           // frames field present
        return u32(b, o + 8)
    }

    /// The VBRI (Fraunhofer) frame count — its tag always sits 32 bytes past the frame header.
    private static func vbriFrames(_ b: [UInt8], frameStart i: Int) -> Int {
        let o = i + 36
        guard o + 18 <= b.count, Array(b[o..<(o + 4)]) == Array("VBRI".utf8) else { return 0 }
        return u32(b, o + 14)
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
