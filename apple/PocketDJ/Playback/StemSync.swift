import AVFoundation
import Foundation

/// Shared stem / voice-group alignment and handover math — the pieces every engine that plays a
/// GROUP of `AVAudioPlayerNode`s meant to sound as one needs, factored out of `MixEngine` so the
/// Mix decks, the Now Playing DSP (`NowPlayingDSP`), the SongDetail stem audition
/// (`StemPlayer`) and the Studio pattern rows (`StudioEngine`) all start, align and hand over
/// the same way. Pure functions over AVFoundation types; no engine state.
///
/// 1. ONE SAMPLE FRAME, NOT ONE HOST TIME (`startTogether`). Handing several nodes the same
///    host-time `AVAudioTime` does NOT start them together: each node converts the host time on
///    its own and they land a few — in the simulator sometimes hundreds of — samples apart
///    (measured on the Mix branch: pairs of stems correlated at 0.80–0.96 instead of 1.0). Four
///    stems summed a few samples apart comb-filter: a "flam" for the rest of the song. A SAMPLE
///    time on the nodes' shared render timeline is one frame for all of them.
/// 2. MP3 PRIMING (`mp3PrimingFrames`). Headerless (untagged) LAME mp3s — every Demucs stem
///    part — decode one 576-sample granule LATE against the tagged full mix; `frame(...)` maps a
///    song second past it so stems and the full mix line up.
/// 3. HANDOVER readiness (`handoverReady`) and partial-stream reach (`playableSeconds`) — the
///    zero-dead-air rule's decisions, shared so Mix and Now Playing agree on "enough runway".
enum StemSync {

    /// A start moment for a voice group: the SAMPLE time every node starts on, plus the host time
    /// of that same instant (an outgoing voice is positioned by it, and a group that couldn't get
    /// a sample time falls back to it).
    typealias Start = (when: AVAudioTime, hostTime: UInt64)

    // MARK: Tunables (the Mix branch's measured values — `MixEngine` forwards its names here)

    /// Seconds of runway a STILL-ARRIVING source needs past the playhead before a handover onto
    /// it (a complete source needs only to cover the playhead).
    static let handoverRunway: Double = 4
    /// The handover crossfade. LINEAR, not equal-power: stems sum back to the full mix, so the two
    /// voices are coherent — linear gains keep the sum constant (equal-power would bump it +3 dB).
    static let handoverFade: Double = 0.06
    /// Partial stems hand back to the full mix this far before their frontier.
    static let underrunLead: Double = 1.0
    /// How far out a group start (or a handover's incoming voice) is placed — scheduled and primed
    /// before its first sample is due.
    static let startLead: Double = 0.06
    /// Torn-frame margin off a partial file's byte frontier (`MixEngine.streamFrontierMargin`).
    static let frontierMargin: Double = 1.5

    // MARK: 1 — one sample frame

    /// A start `lead` seconds from now as a SAMPLE time on the render timeline of `clocks` (the
    /// first one with a valid render time), plus that moment's host time. `rate` is the
    /// timeline's speed against the wall clock: voices upstream of a time-stretch render at the
    /// stretch's rate. nil when no clock has rendered yet (an engine that just started).
    static func sampleStart(clocks: [AVAudioNode?], lead: Double, rate: Double = 1) -> Start? {
        guard let rt = clocks.lazy.compactMap({ $0?.lastRenderTime })
                .first(where: { $0.isSampleTimeValid && $0.isHostTimeValid && $0.sampleRate > 0 }) else { return nil }
        // `lead` from NOW (the last render cycle may be a little behind the wall clock).
        let sinceRender = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: rt.hostTime)
        let ahead = max(0, sinceRender) + lead
        let frames = AVAudioFramePosition(ahead * rt.sampleRate * max(0.05, rate))
        return (AVAudioTime(sampleTime: rt.sampleTime + frames, atRate: rt.sampleRate),
                rt.hostTime + AVAudioTime.hostTime(forSeconds: ahead))
    }

    /// A plain host-time start `lead` seconds out (the no-render-time fallback).
    static func hostStart(lead: Double) -> Start {
        let h = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)
        return (AVAudioTime(hostTime: h), h)
    }

    /// Start every node in `nodes` on ONE sample frame `lead` seconds out. The clock is the
    /// group's own render timeline: `clocks` first (e.g. the mixer the group feeds, when it runs
    /// at the group's rate), then the nodes themselves. A node whose output rate differs from the
    /// clock's can't share its sample timeline, so such a group falls back to one host time (the
    /// old behaviour). An engine that has only just started has no render time yet: wait up to
    /// `renderWait` seconds (a render cycle is ~10 ms) for one rather than start out of step.
    /// The caller must ensure the engine is RUNNING (`play(at:)` on a dead engine traps).
    @discardableResult
    static func startTogether(_ nodes: [AVAudioPlayerNode], clocks: [AVAudioNode?] = [], lead: Double = startLead,
                              rate: Double = 1, renderWait: Double = 0.1) -> Start {
        guard !nodes.isEmpty else { return hostStart(lead: lead) }
        let all: [AVAudioNode?] = nodes.map { $0 as AVAudioNode? } + clocks
        var start = sampleStart(clocks: all, lead: lead, rate: rate)
        if start == nil, renderWait > 0 {
            let deadline = Date().addingTimeInterval(renderWait)
            while start == nil, Date() < deadline {
                usleep(1_000)
                start = sampleStart(clocks: all, lead: lead, rate: rate)
            }
        }
        if let s = start, nodes.allSatisfy({ sharesTimeline($0, s.when) }) {
            for n in nodes { n.play(at: s.when) }
            return s
        }
        let s = start.map { (AVAudioTime(hostTime: $0.hostTime), $0.hostTime) } ?? hostStart(lead: lead)
        for n in nodes { n.play(at: s.0) }
        return s
    }

    /// Can `node` start on sample time `t` — does its output run at `t`'s rate (so the sample
    /// counts mean the same frames)? A node that hasn't rendered yet is judged by its format.
    static func sharesTimeline(_ node: AVAudioNode, _ t: AVAudioTime) -> Bool {
        guard t.isSampleTimeValid else { return false }
        if let nt = node.lastRenderTime, nt.isSampleTimeValid { return nt.sampleRate == t.sampleRate }
        return node.outputFormat(forBus: 0).sampleRate == t.sampleRate
    }

    /// Does `node` render on the clock `t` is expressed in (it has rendered, at the same rate)?
    static func onClock(_ node: AVAudioNode, _ t: AVAudioTime) -> Bool {
        guard t.isSampleTimeValid, let nt = node.lastRenderTime, nt.isSampleTimeValid else { return false }
        return nt.sampleRate == t.sampleRate
    }

    /// The SOURCE position (seconds, from `segmentStart`) a rendering voice will be at host time
    /// `t`: its player clock (`playerTime.sampleTime` counts the file's frames and already advances
    /// at any time-stretch rate) projected forward at `rate`. nil when it isn't rendering.
    static func voicePlayhead(_ node: AVAudioPlayerNode, sampleRate sr: Double, segmentStart: Double,
                              rate: Double, atHostTime t: UInt64) -> Double? {
        guard sr > 0, let nt = node.lastRenderTime, nt.isHostTimeValid,
              let pt = node.playerTime(forNodeTime: nt) else { return nil }
        let ahead = AVAudioTime.seconds(forHostTime: t) - AVAudioTime.seconds(forHostTime: nt.hostTime)
        return segmentStart + Double(pt.sampleTime) / sr + max(0, ahead) * rate
    }

    /// …at a handover moment `start`: read off the voice's own player clock at that very SAMPLE
    /// time when it renders on the same clock — exact — else projected by host time.
    static func voicePlayhead(_ node: AVAudioPlayerNode, sampleRate sr: Double, segmentStart: Double,
                              rate: Double, at start: Start) -> Double? {
        if sr > 0, onClock(node, start.when), let pt = node.playerTime(forNodeTime: start.when), pt.isSampleTimeValid {
            return segmentStart + Double(pt.sampleTime) / sr
        }
        return voicePlayhead(node, sampleRate: sr, segmentStart: segmentStart, rate: rate, atHostTime: start.hostTime)
    }

    /// TEST PROBE: the render-timeline frame at which `node`'s player time 0 fell — i.e. the
    /// frame it STARTED on. Nodes started together report the same frame; nil before it renders.
    static func startFrame(of node: AVAudioPlayerNode) -> AVAudioFramePosition? {
        guard let rt = node.lastRenderTime, rt.isSampleTimeValid, rt.sampleRate > 0,
              let nt = node.nodeTime(forPlayerTime: AVAudioTime(sampleTime: 0, atRate: rt.sampleRate)),
              nt.isSampleTimeValid else { return nil }
        return nt.sampleTime
    }

    // MARK: 2 — mp3 priming

    /// Encoder priming a decoder can't see: frames to skip at the head of an mp3 so its frame
    /// `t·sr` lines up with second `t` of the music. A LAME-family encoder pads one 576-sample
    /// granule ahead of the audio; a TAGGED file (Xing/Info gapless header — every rip and burn)
    /// says so and Core Audio trims it, but the Demucs stems (lameenc, no tag) carry it unseen —
    /// measured on real stem sets against their tagged full mix: the summed stems decode exactly
    /// 576 samples (13 ms) LATE, correlation 0.9998 — a flam on every handover crossfade and a
    /// replayed/skipped sliver at each switch, uncorrected. (Core Audio trims the decoder's own
    /// delay either way.) `header` is the file's first few KB; non-mp3 data ⇒ 0.
    static func mp3PrimingFrames(header: Data) -> AVAudioFramePosition {
        let b = [UInt8](header.prefix(8192))
        var i = 0
        if b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 {          // "ID3" v2 tag
            let size = (Int(b[6] & 0x7F) << 21) | (Int(b[7] & 0x7F) << 14) | (Int(b[8] & 0x7F) << 7) | Int(b[9] & 0x7F)
            i = 10 + size + ((b[5] & 0x10) != 0 ? 10 : 0)
        }
        // The first MPEG audio frame header: 11 sync bits, a real version, Layer III.
        while i + 4 <= b.count {
            if b[i] == 0xFF, b[i + 1] & 0xE0 == 0xE0, (b[i + 1] >> 3) & 0x3 != 1, (b[i + 1] >> 1) & 0x3 == 1 { break }
            i += 1
        }
        guard i + 4 <= b.count else { return 0 }
        let mpeg1 = (b[i + 1] >> 3) & 0x3 == 3
        let mono = (b[i + 3] >> 6) & 0x3 == 3
        let sideInfo = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
        func tag(at o: Int, _ s: String) -> Bool {
            let t = Array(s.utf8)
            return o + t.count <= b.count && Array(b[o..<(o + t.count)]) == t
        }
        let x = i + 4 + sideInfo
        if tag(at: x, "Xing") || tag(at: x, "Info") || tag(at: i + 36, "VBRI") { return 0 }
        return 576
    }

    /// `mp3PrimingFrames` of the file at `url` (0 for non-mp3 / unreadable).
    static func mp3PrimingFrames(ofFileAt url: URL) -> AVAudioFramePosition {
        guard url.pathExtension.lowercased() == "mp3", let h = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? h.close() }
        return mp3PrimingFrames(header: (try? h.read(upToCount: 8192)) ?? Data())
    }

    /// The priming of a stem SET: all four parts come out of one encoder run — one part's header
    /// speaks for the set (the first of `order` present).
    static func setPrimingFrames(_ files: [String: AVAudioFile], order: [String]) -> AVAudioFramePosition {
        guard let f = order.lazy.compactMap({ files[$0] }).first ?? files.values.first else { return 0 }
        return mp3PrimingFrames(ofFileAt: f.url)
    }

    /// The FILE frame that plays song second `sec` of a part with `prime` priming frames, clamped
    /// to `[prime, min(limit, length)]`.
    static func frame(_ file: AVAudioFile, prime: AVAudioFramePosition, atSeconds sec: Double,
                      limit: AVAudioFramePosition? = nil) -> AVAudioFramePosition {
        let f = prime + AVAudioFramePosition(max(0, sec) * file.processingFormat.sampleRate)
        return min(max(prime, f), min(limit ?? file.length, file.length))
    }

    /// Song seconds a part covers: its frames past the priming.
    static func songSeconds(_ file: AVAudioFile, prime: AVAudioFramePosition) -> Double {
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return 0 }
        return Double(max(0, file.length - prime)) / sr
    }

    // MARK: 3 — handover decisions

    /// Does a source with `runway` seconds of audio past the playhead qualify for a handover? A
    /// complete source needs only to cover the playhead; a still-arriving one needs
    /// `handoverRunway` — or whatever is left of the song, near its end.
    static func handoverReady(runway: Double, complete: Bool, songLeft: Double) -> Bool {
        guard runway > 0.05 else { return false }
        if complete { return true }
        return runway >= min(handoverRunway, max(0.05, songLeft - 0.05))
    }

    /// Seconds of stem audio a fresh open of a part can play from 0:00. A complete part: its
    /// length. A partial one (headerless CBR ⇒ an open reports the bytes present): that length,
    /// capped by bytes ÷ its byte rate (`expectedBytes` over the song's seconds, else
    /// `fallbackBytesPerSecond`), minus the torn-frame margin.
    static func playableSeconds(lengthSeconds: Double, bytes: Int64, expectedBytes: Int64?,
                                songSeconds: Double, complete: Bool,
                                fallbackBytesPerSecond: Double) -> Double {
        if complete { return max(0, lengthSeconds) }
        var bps = fallbackBytesPerSecond
        if let e = expectedBytes, e > 0, songSeconds > 0 { bps = Double(e) / songSeconds }
        let byBytes = bps > 0 ? Double(bytes) / bps : 0
        return max(0, min(lengthSeconds, byBytes) - frontierMargin)
    }

    /// Fresh opens of a STREAMING stem set's four parts and the seconds ALL of them can play
    /// from 0:00 (the frontier). nil when a part isn't resolved yet / won't open. An open sees only
    /// the bytes present at open time, so a growing set is re-opened as it grows.
    @MainActor
    static func openStreamingParts(_ set: MixStreamLoader.StemSet, urls: [String: URL], prime: AVAudioFramePosition,
                                   songSeconds: Double, fallbackBytesPerSecond: Double)
        -> (files: [String: AVAudioFile], frontier: Double)? {
        var fresh: [String: AVAudioFile] = [:]
        var frontier = Double.infinity
        for (name, url) in urls {
            guard let part = set.parts[name], let f = try? AVAudioFile(forReading: url),
                  f.processingFormat.sampleRate > 0 else { return nil }
            fresh[name] = f
            frontier = min(frontier, playableSeconds(
                lengthSeconds: songSecondsOf(f, prime: prime), bytes: part.bytesReceived,
                expectedBytes: part.expectedBytes, songSeconds: songSeconds, complete: part.isComplete,
                fallbackBytesPerSecond: fallbackBytesPerSecond))
        }
        guard !fresh.isEmpty, frontier.isFinite else { return nil }
        return (fresh, frontier)
    }
    private static func songSecondsOf(_ f: AVAudioFile, prime: AVAudioFramePosition) -> Double {
        songSeconds(f, prime: prime)
    }

    /// The slowest part's playable seconds by BYTES alone (no open) — a pump's re-open throttle.
    @MainActor
    static func bytesSeconds(_ set: MixStreamLoader.StemSet, songSeconds: Double, fallbackBytesPerSecond: Double) -> Double {
        set.parts.values.map {
            playableSeconds(lengthSeconds: .infinity, bytes: $0.bytesReceived, expectedBytes: $0.expectedBytes,
                            songSeconds: songSeconds, complete: false, fallbackBytesPerSecond: fallbackBytesPerSecond)
        }.min() ?? 0
    }

    /// The URLs to open a stem set's parts from: an ADOPTED (complete) set lives in the burn folder
    /// now — `adopted` returns it there under the folder's scope (a user-picked folder is
    /// security-scoped; a bare open of the moved file fails) — else each part's own file. nil
    /// while a part is still unresolved.
    @MainActor
    static func partURLs(_ set: MixStreamLoader.StemSet,
                         adopted: (String) -> (urls: [String: URL], release: (() -> Void)?)?)
        -> (urls: [String: URL], scope: (() -> Void)?)? {
        if set.isComplete, set.adopted, let r = adopted(set.songId) { return (r.urls, r.release) }
        var urls: [String: URL] = [:]
        for (name, part) in set.parts {
            guard part.resolved || part.isComplete else { return nil }
            urls[name] = part.finalURL ?? part.fileURL
        }
        return (urls, nil)
    }

    // MARK: Crossfade

    /// Step a LINEAR crossfade over `handoverFade` from host time `t`: `apply(g)` with g 1/steps…1
    /// (the incoming voice's gain; the outgoing one's is 1−g), then `done()`. Each step re-checks
    /// `alive()` (a generation guard), so a superseding transport action ends it cleanly.
    @MainActor
    static func crossfade(atHostTime t: UInt64, steps: Int = 6, alive: @escaping @MainActor () -> Bool,
                          apply: @escaping @MainActor (Float) -> Void,
                          done: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            let lead = AVAudioTime.seconds(forHostTime: t) - AVAudioTime.seconds(forHostTime: mach_absolute_time())
            if lead > 0 { try? await Task.sleep(nanoseconds: UInt64(lead * 1_000_000_000)) }
            for i in 1...steps {
                guard !Task.isCancelled, alive() else { return }
                apply(Float(i) / Float(steps))
                try? await Task.sleep(nanoseconds: UInt64(handoverFade / Double(steps) * 1_000_000_000))
            }
            guard !Task.isCancelled, alive() else { return }
            done()
        }
    }
}
