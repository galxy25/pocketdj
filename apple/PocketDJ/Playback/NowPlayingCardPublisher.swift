import Foundation
import MediaPlayer

/// The ONE funnel every system Now Playing card write goes through (`PlayerEngine` — local
/// AVPlayer, Apple Music impersonation, Now Playing DSP — and `MixEngine`). The card is what the
/// lock screen, Control Center, the watch and CarPlay's `CPNowPlayingTemplate` render; the
/// system extrapolates the progress cursor from elapsed + rate + the write's timestamp, so the
/// funnel enforces the invariants a moving cursor needs on EVERY write:
///
///  - `PlaybackRate` is > 0 exactly when the writer says audio is advancing, 0 otherwise (a
///    playing card with rate 0 — or a stalled one with rate 1 — is a frozen / runaway cursor);
///  - `DefaultPlaybackRate` is always 1 (head units read it to scale the bar);
///  - elapsed is clamped into `0…duration` (a card at 302 s of a 301 s track pins the bar);
///  - `PlaybackProgress` rides along for head units that draw from it;
///  - `playbackState` agrees with the rate (CarPlay + watchOS read it, not just the dict).
///
/// It also emits a RATE-LIMITED `NPLog` line (`card PUB …`) whenever what the cursor shows
/// would change — writer, title, rate, duration, state, or an elapsed jump the extrapolation
/// didn't predict — plus a ~15 s heartbeat, so a "cursor isn't moving" field report is
/// diagnosable from the uploaded trace. And it reads the card back before each write: a value
/// that differs from our own last write means ANOTHER writer touched it (e.g. MusicKit's
/// player) — traced as `card OVERWRITTEN`.
///
/// Tests install `sink` to capture publications instead of touching the real info center.
@MainActor
final class NowPlayingCardPublisher {
    static let shared = NowPlayingCardPublisher()
    init() {}

    /// One card write as published (nil `info` ⇒ the card was cleared).
    struct Publication {
        let writer: String
        let info: [String: Any]?
        let playbackState: MPNowPlayingPlaybackState
        let at: Date

        var title: String? { info?[MPMediaItemPropertyTitle] as? String }
        var rate: Double { (info?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue ?? 0 }
        var defaultRate: Double? { (info?[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? NSNumber)?.doubleValue }
        var elapsed: Double? { (info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue }
        var duration: Double? { (info?[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue }
        var isLive: Bool { (info?[MPNowPlayingInfoPropertyIsLiveStream] as? NSNumber)?.boolValue ?? false }
        /// Where the system cursor would sit at `date` (elapsed extrapolated at rate).
        func extrapolated(to date: Date) -> Double? {
            elapsed.map { $0 + rate * max(0, date.timeIntervalSince(at)) }
        }
    }

    /// TEST SEAM: when set, publications are delivered here INSTEAD of the real
    /// `MPNowPlayingInfoCenter` (headless tests capture the exact dicts).
    var sink: ((Publication) -> Void)?
    /// The most recent publication (either path).
    private(set) var last: Publication?

    /// Publish a card. `advancing` = audio is actually moving right now (playing AND not
    /// stalled/held); `rate` is the speed it moves at (a DJ tempo), forced to 0 when not
    /// advancing and to ≥ a sane floor when it is. `updatesPlaybackState: false` leaves the
    /// explicit `playbackState` alone (the "cueing up" announce card between tracks).
    /// `intentPlaying` (the HONEST card): the writer WANTS to play but audio isn't moving yet
    /// (buffering / waiting to play) — the cursor stays frozen (rate 0) but the state reads
    /// `.playing`, so the head unit shows ⏸ instead of a ▶ whose press would PAUSE the start.
    func publish(writer: String, title: String, artist: String, elapsed: Double,
                 duration: Double?, advancing: Bool, rate: Double = 1, isLive: Bool = false,
                 artwork: MPMediaItemArtwork? = nil, updatesPlaybackState: Bool = true,
                 intentPlaying: Bool = false,
                 detail: @autoclosure () -> String = "") {
        let dur = (duration ?? 0) > 0 && !isLive ? duration : nil
        var el = max(0, elapsed.isFinite ? elapsed : 0)
        if let dur { el = min(el, dur) }
        let cardRate = advancing ? (rate.isFinite && rate > 0.01 ? rate : 1) : 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: el,
            MPNowPlayingInfoPropertyPlaybackRate: cardRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
        ]
        if let dur {
            info[MPMediaItemPropertyPlaybackDuration] = dur
            info[MPNowPlayingInfoPropertyPlaybackProgress] = min(1, max(0, el / dur))
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        let state: MPNowPlayingPlaybackState = updatesPlaybackState
            ? ((advancing || intentPlaying) ? .playing : .paused)
            : (last?.playbackState ?? .unknown)
        deliver(Publication(writer: writer, info: info, playbackState: state, at: Date()),
                setsState: updatesPlaybackState, detail: detail())
    }

    /// Clear the card (the writer stopped / resigned).
    func clear(writer: String) {
        deliver(Publication(writer: writer, info: nil, playbackState: .stopped, at: Date()),
                setsState: true, detail: "")
    }

    // MARK: - Delivery + trace

    private var lastTraced: Publication?

    private func deliver(_ p: Publication, setsState: Bool, detail: String) {
        if let sink {
            sink(p)
        } else {
            detectForeignOverwrite()
            let center = MPNowPlayingInfoCenter.default()
            center.nowPlayingInfo = p.info
            if setsState { center.playbackState = p.playbackState }
        }
        trace(p, detail: detail)
        last = p
    }

    /// Read the live card back: if it no longer holds what WE last wrote, someone else wrote it.
    private func detectForeignOverwrite() {
        guard let mine = last, let mineInfo = mine.info else { return }
        let live = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let liveTitle = live?[MPMediaItemPropertyTitle] as? String
        let liveElapsed = (live?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue
        let liveRate = (live?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue
        let sameTitle = liveTitle == (mineInfo[MPMediaItemPropertyTitle] as? String)
        let sameElapsed = abs((liveElapsed ?? -1) - (mine.elapsed ?? -2)) < 0.01
        let sameRate = abs((liveRate ?? -1) - mine.rate) < 0.001
        guard !(sameTitle && sameElapsed && sameRate) else { return }
        NPLog.trace("card OVERWRITTEN since our last write (by \(mine.writer)): live title=\(liveTitle ?? "nil") "
                    + "rate=\(liveRate.map { String(format: "%.2f", $0) } ?? "nil") "
                    + "el=\(liveElapsed.map { String(format: "%.1f", $0) } ?? "nil")")
    }

    /// Rate-limited: trace when the visible cursor would CHANGE (writer / title / rate /
    /// duration / state / an elapsed jump vs the extrapolation), else a ~15 s heartbeat.
    private func trace(_ p: Publication, detail: String) {
        func fmt(_ d: Double?) -> String { d.map { String(format: "%.1f", $0) } ?? "-" }
        let line = "card PUB w=\(p.writer) title=\(p.title ?? "∅") rate=\(String(format: "%.2f", p.rate)) "
            + "el=\(fmt(p.elapsed)) dur=\(fmt(p.duration)) st=\(Self.name(p.playbackState)) "
            + "owner=\(NowPlayingArbiter.name(NowPlayingArbiter.shared.owner))"
            + (p.isLive ? " live" : "") + (detail.isEmpty ? "" : " \(detail)")
        guard let prev = lastTraced else { lastTraced = p; NPLog.trace(line); return }
        var why: String?
        if p.info == nil || prev.info == nil { why = "clear" }
        else if p.writer != prev.writer { why = "writer" }
        else if p.title != prev.title { why = "track" }
        else if abs(p.rate - prev.rate) > 0.001 { why = "rate" }
        else if p.playbackState != prev.playbackState { why = "state" }
        else if abs((p.duration ?? -1) - (prev.duration ?? -1)) > 0.5 { why = "dur" }
        else if let e = p.elapsed, let x = prev.extrapolated(to: p.at), abs(e - x) > 2 {
            why = "jump(expected \(fmt(x)))"
        } else if p.at.timeIntervalSince(prev.at) >= 15 { why = "hb" }
        guard let why else { return }
        lastTraced = p
        NPLog.trace(line + " [\(why)]")
    }

    private static func name(_ s: MPNowPlayingPlaybackState) -> String {
        switch s {
        case .playing: return "playing"
        case .paused: return "paused"
        case .stopped: return "stopped"
        case .interrupted: return "interrupted"
        case .unknown: return "unknown"
        @unknown default: return "?"
        }
    }

    #if DEBUG
    /// Tests: forget trace + last-write state between cases.
    func resetForTesting() { last = nil; lastTraced = nil }
    #endif
}
