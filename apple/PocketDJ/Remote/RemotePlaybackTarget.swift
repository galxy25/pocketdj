import Foundation

/// The local player a Remote session drives on a SPEAKER — a protocol so the reconciler is
/// testable without audio. Production is `SetlistPlayerRemoteTarget` (the app-scoped
/// `SetlistPlayer` + its transport routing); tests and the showcase seed use
/// `InMemoryRemoteTarget`.
///
/// Reads are cheap by contract: `queueGeneration` changes on ANY queue mutation (so a 0.5 s
/// observation tick can skip the row walk when nothing moved), and rows are read one at a time.
@MainActor
protocol RemotePlaybackTarget: AnyObject {
    var queueGeneration: Int { get }
    var queueCount: Int { get }
    var currentIndex: Int { get }
    var isRunning: Bool { get }
    func item(at index: Int) -> SetlistPlayer.Item
    var isPlaying: Bool { get }
    /// Song-relative position of the current row.
    var positionMs: Int { get }
    var repeatMode: RepeatMode { get }
    var shuffleEnabled: Bool { get }
    /// A track start / stall is in flight — play-state reads are not user intent right now.
    var isTransitioning: Bool { get }

    /// Start a fresh run of `items` ON `startIndex`, `atMs` into that song.
    func play(_ items: [SetlistPlayer.Item], startIndex: Int, atMs: Int)
    func jumpToUpcoming(uid: UUID)
    /// Replace everything after the current row (the current row keeps sounding).
    func replaceUpcoming(with items: [SetlistPlayer.Item])
    func appendToQueue(_ items: [SetlistPlayer.Item])
    func setPlaying(_ on: Bool)
    func seek(toMs ms: Int)
    func setRepeatMode(_ mode: RepeatMode)
    func setShuffle(_ on: Bool)
}

extension RemotePlaybackTarget {
    var currentItem: SetlistPlayer.Item? {
        isRunning && currentIndex >= 0 && currentIndex < queueCount ? item(at: currentIndex) : nil
    }
    /// The upcoming rows, capped (the session window never needs more).
    func upcomingItems(limit: Int) -> [SetlistPlayer.Item] {
        guard isRunning else { return [] }
        let lo = currentIndex + 1
        let hi = min(queueCount, lo + limit)
        return lo < hi ? (lo..<hi).map { item(at: $0) } : []
    }
}

// MARK: - Production: the app-scoped SetlistPlayer

@MainActor
final class SetlistPlayerRemoteTarget: RemotePlaybackTarget {
    private let sequencer: SetlistPlayer
    private let coordinator: PlaybackCoordinator
    private let player: PlayerEngine

    init(sequencer: SetlistPlayer, coordinator: PlaybackCoordinator, player: PlayerEngine) {
        self.sequencer = sequencer
        self.coordinator = coordinator
        self.player = player
    }

    var queueGeneration: Int { sequencer.queueGeneration }
    var queueCount: Int { sequencer.queue.count }
    var currentIndex: Int { sequencer.index }
    var isRunning: Bool { sequencer.isRunning }
    func item(at index: Int) -> SetlistPlayer.Item { sequencer.queue[index] }
    var isPlaying: Bool { sequencer.isRunning && sequencer.isAudiblyPlaying }
    var positionMs: Int { sequencer.songPositionMs }
    var repeatMode: RepeatMode { sequencer.repeatMode }
    var shuffleEnabled: Bool { sequencer.shuffleEnabled }
    var isTransitioning: Bool { sequencer.isStartPending || player.reasonForWaitingToPlay != "-" }

    func play(_ items: [SetlistPlayer.Item], startIndex: Int, atMs: Int) {
        guard !items.isEmpty else { return }
        let i = max(0, min(startIndex, items.count - 1))
        if atMs > 1_000 { sequencer.cueNextStart(songId: items[i].id, atMs: atMs) }
        sequencer.play(items, startIndex: i)
    }

    func jumpToUpcoming(uid: UUID) { sequencer.jumpToUpcoming(uid: uid) }

    func replaceUpcoming(with items: [SetlistPlayer.Item]) {
        let existing = Set(sequencer.upcoming.map(\.uid))
        if !existing.isEmpty { sequencer.removeUpcoming(uids: existing) }
        if !items.isEmpty { sequencer.appendToQueue(items) }
    }

    func appendToQueue(_ items: [SetlistPlayer.Item]) { sequencer.appendToQueue(items) }

    /// ▶/⏸ through the SAME routing the Now Playing panel uses (held deck → resume, Apple Music
    /// → the coordinator, local → the engine), only when the state actually differs.
    func setPlaying(_ on: Bool) {
        guard sequencer.isRunning, on != isPlaying else { return }
        NowPlayingPanel.togglePlayPause(sequencer: sequencer, coordinator: coordinator, player: player)
    }

    func seek(toMs ms: Int) {
        let s = Double(max(0, ms)) / 1000
        if coordinator.activeBackend == .appleMusic {
            coordinator.seekAppleMusic(to: s)
        } else {
            // The card timeline is song-relative (the shared-album-file offset is added inside).
            player.seekFromCard(toCardSeconds: s)
        }
    }

    func setRepeatMode(_ mode: RepeatMode) { sequencer.setRepeatMode(mode) }
    func setShuffle(_ on: Bool) { sequencer.setShuffle(on) }
}

// MARK: - In-memory (tests + the showcase seed's fake "Car" speaker)

/// A player with no audio: the queue/index/play-state/position bookkeeping of a SetlistPlayer
/// and nothing else. Position advances on an injectable clock while playing.
@MainActor
final class InMemoryRemoteTarget: RemotePlaybackTarget {
    private(set) var queue: [SetlistPlayer.Item] = [] { didSet { queueGeneration &+= 1 } }
    private(set) var queueGeneration = 0
    private(set) var currentIndex = 0
    private(set) var isRunning = false
    private(set) var isPlaying = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var shuffleEnabled = false
    var isTransitioning = false
    private var basePositionMs = 0
    private var baseAt: Double = 0
    let now: () -> Double
    /// Every mutating call, in order (tests assert what the reconciler did).
    private(set) var log: [String] = []

    init(now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) { self.now = now }

    var queueCount: Int { queue.count }
    func item(at index: Int) -> SetlistPlayer.Item { queue[index] }
    var positionMs: Int {
        isPlaying ? basePositionMs + Int((now() - baseAt).rounded()) : basePositionMs
    }

    private func setPosition(_ ms: Int) { basePositionMs = max(0, ms); baseAt = now() }

    func play(_ items: [SetlistPlayer.Item], startIndex: Int, atMs: Int) {
        guard !items.isEmpty else { return }
        log.append("play")
        queue = items
        currentIndex = max(0, min(startIndex, items.count - 1))
        isRunning = true
        shuffleEnabled = false
        isPlaying = true
        setPosition(atMs)
    }

    func jumpToUpcoming(uid: UUID) {
        guard let i = queue.firstIndex(where: { $0.uid == uid }), i > currentIndex else { return }
        log.append("jump")
        currentIndex = i
        setPosition(0)
    }

    func replaceUpcoming(with items: [SetlistPlayer.Item]) {
        guard isRunning else { return }
        log.append("replaceUpcoming")
        queue = Array(queue[...currentIndex]) + items
    }

    func appendToQueue(_ items: [SetlistPlayer.Item]) {
        guard isRunning, !items.isEmpty else { return }
        log.append("append")
        queue += items
    }

    func setPlaying(_ on: Bool) {
        guard isRunning, on != isPlaying else { return }
        log.append(on ? "resume" : "pause")
        setPosition(positionMs)
        isPlaying = on
    }

    func seek(toMs ms: Int) {
        log.append("seek")
        setPosition(ms)
    }

    func setRepeatMode(_ mode: RepeatMode) { repeatMode = mode }
    func setShuffle(_ on: Bool) { shuffleEnabled = on }

    // MARK: Simulated local user actions (what the Now Playing UI would do)

    func userSkipNext() {
        guard isRunning, currentIndex + 1 < queue.count else { return }
        currentIndex += 1
        setPosition(0)
    }
    func userSetPlaying(_ on: Bool) { setPosition(positionMs); isPlaying = on }
    func userSeek(_ ms: Int) { setPosition(ms) }
    func userAppend(_ items: [SetlistPlayer.Item]) { queue += items }
    func userRemoveUpcoming(at offset: Int) {
        let i = currentIndex + 1 + offset
        guard queue.indices.contains(i) else { return }
        queue.remove(at: i)
    }
    func userPlay(_ items: [SetlistPlayer.Item]) {
        queue = items; currentIndex = 0; isRunning = true; isPlaying = true; setPosition(0)
    }
}
