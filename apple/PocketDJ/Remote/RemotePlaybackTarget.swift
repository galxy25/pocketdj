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
    /// Position reads are coarse (Apple Music's clock) — drift needs a wider threshold.
    var hasCoarsePosition: Bool { get }
    /// The device's SYSTEM silenced the audio (an interruption that didn't resume, a route loss)
    /// and nothing has started it since — a speaker must not resume it on its own.
    var isSystemPaused: Bool { get }

    /// Bumped on every current-row change / restart, with WHY (`SetlistPlayer.TransitionCause`):
    /// only `.user` transitions are the listener's intent; the rest are the player's own.
    var transitionSeq: Int { get }
    var lastTransitionCause: SetlistPlayer.TransitionCause { get }
    /// `transitionSeq` of the last `.user` transition.
    var lastUserTransitionSeq: Int { get }
    /// Bumped on every ▶/⏸ the listener pressed, with the state they asked for.
    var userPlayIntentSeq: Int { get }
    var lastUserPlayIntent: Bool { get }

    /// Start a fresh run of `items` ON `startIndex`, `atMs` into that song — loaded PAUSED
    /// (nothing sounds; the first ▶ resumes at `atMs`) when `startPaused`.
    func play(_ items: [SetlistPlayer.Item], startIndex: Int, atMs: Int, startPaused: Bool)
    /// Jump onto an upcoming row, starting it `atMs` in (the start cue — a seek issued after the
    /// jump would land on the OLD track's backend while the new one is still resolving).
    func jumpToUpcoming(uid: UUID, atMs: Int)
    /// Replace the first `count` upcoming rows with `items`; rows after them are kept.
    func replaceUpcoming(first count: Int, with items: [SetlistPlayer.Item])
    /// Insert `items` before the upcoming row `uid` (nil ⇒ append).
    func insertUpcoming(_ items: [SetlistPlayer.Item], before uid: UUID?)
    func appendToQueue(_ items: [SetlistPlayer.Item])
    func setPlaying(_ on: Bool)
    func seek(toMs ms: Int)
    func setRepeatMode(_ mode: RepeatMode)
    func setShuffle(_ on: Bool)
    /// This device became a CONTROLLER: silence it and keep it silent — cancel any start in
    /// flight (a pause racing a pending start is a no-op that the start then overrides).
    func silenceForController()
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
    var isTransitioning: Bool { sequencer.isStartInFlight || player.reasonForWaitingToPlay != "-" }
    var hasCoarsePosition: Bool { coordinator.activeBackend == .appleMusic }
    var isSystemPaused: Bool { player.systemPauseHeld }
    var transitionSeq: Int { sequencer.transitionSeq }
    var lastTransitionCause: SetlistPlayer.TransitionCause { sequencer.lastTransitionCause }
    var lastUserTransitionSeq: Int { sequencer.lastUserTransitionSeq }
    var userPlayIntentSeq: Int { sequencer.userPlayIntentSeq }
    var lastUserPlayIntent: Bool { sequencer.lastUserPlayIntent }

    // Every mutation below runs as a Remote APPLY (`applyingRemote`): tagged `.remote`, never
    // listener intent, and past the controller gate.

    func play(_ items: [SetlistPlayer.Item], startIndex: Int, atMs: Int, startPaused: Bool) {
        guard !items.isEmpty else { return }
        let i = max(0, min(startIndex, items.count - 1))
        sequencer.applyingRemote {
            sequencer.play(items, startIndex: i, startPaused: startPaused, startAtMs: atMs > 1_000 ? atMs : nil)
        }
    }

    func jumpToUpcoming(uid: UUID, atMs: Int) {
        sequencer.applyingRemote {
            if atMs > 1_000, let it = sequencer.upcoming.first(where: { $0.uid == uid }) {
                sequencer.cueNextStart(songId: it.id, atMs: atMs)
            }
            sequencer.jumpToUpcoming(uid: uid)
        }
    }

    func replaceUpcoming(first count: Int, with items: [SetlistPlayer.Item]) {
        sequencer.applyingRemote { sequencer.replaceUpcomingSegment(count: count, with: items) }
    }

    func insertUpcoming(_ items: [SetlistPlayer.Item], before uid: UUID?) {
        guard !items.isEmpty else { return }
        sequencer.applyingRemote {
            if let uid { sequencer.insertInQueue(items, before: uid) } else { sequencer.appendToQueue(items) }
        }
    }

    func appendToQueue(_ items: [SetlistPlayer.Item]) {
        sequencer.applyingRemote { sequencer.appendToQueue(items) }
    }

    /// ▶/⏸ through the SAME routing the Now Playing panel uses (held deck → resume, Apple Music
    /// → the coordinator, local → the engine), only when the state actually differs.
    func setPlaying(_ on: Bool) {
        guard sequencer.isRunning, on != isPlaying else { return }
        sequencer.applyingRemote {
            NowPlayingPanel.togglePlayPause(sequencer: sequencer, coordinator: coordinator, player: player)
        }
    }

    func seek(toMs ms: Int) {
        // A held (paused-loaded) deck has no audio to seek: move its resume point.
        if sequencer.isHeldForResume { sequencer.setHeldResumePosition(ms: ms); return }
        let s = Double(max(0, ms)) / 1000
        if coordinator.activeBackend == .appleMusic {
            coordinator.seekAppleMusic(to: s)
        } else {
            // The card timeline is song-relative (the shared-album-file offset is added inside).
            player.seekFromCard(toCardSeconds: s)
        }
    }

    func setRepeatMode(_ mode: RepeatMode) { sequencer.applyingRemote { sequencer.setRepeatMode(mode) } }
    func setShuffle(_ on: Bool) { sequencer.applyingRemote { sequencer.setShuffle(on) } }
    func silenceForController() { sequencer.holdSilentForRemote() }
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
    var hasCoarsePosition = false
    private(set) var isSystemPaused = false
    private(set) var transitionSeq = 0
    private(set) var lastTransitionCause: SetlistPlayer.TransitionCause = .user
    private(set) var lastUserTransitionSeq = 0
    private(set) var userPlayIntentSeq = 0
    private(set) var lastUserPlayIntent = false
    /// A start in flight that will SOUND when it settles (`settlePendingStart`) — the real
    /// player's race a plain pause can't win.
    private(set) var pendingStartWillPlay = false
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

    private func transition(_ cause: SetlistPlayer.TransitionCause) {
        transitionSeq += 1
        lastTransitionCause = cause
        if cause == .user { lastUserTransitionSeq = transitionSeq }
    }

    func play(_ items: [SetlistPlayer.Item], startIndex: Int, atMs: Int, startPaused: Bool) {
        guard !items.isEmpty else { return }
        log.append(startPaused ? "play(paused)" : "play")
        queue = items
        currentIndex = max(0, min(startIndex, items.count - 1))
        isRunning = true
        shuffleEnabled = false
        pendingStartWillPlay = false
        isPlaying = !startPaused
        if !startPaused { isSystemPaused = false }
        setPosition(atMs)
        transition(.remote)
    }

    func jumpToUpcoming(uid: UUID, atMs: Int) {
        guard let i = queue.firstIndex(where: { $0.uid == uid }), i > currentIndex else { return }
        log.append(atMs > 1_000 ? "jump@\(atMs)" : "jump")
        isSystemPaused = false                 // a jump loads (and sounds) the row
        currentIndex = i
        setPosition(atMs > 1_000 ? atMs : 0)
        transition(.remote)
    }

    func replaceUpcoming(first count: Int, with items: [SetlistPlayer.Item]) {
        guard isRunning else { return }
        log.append("replaceUpcoming")
        let lo = min(currentIndex + 1, queue.count)
        let hi = min(queue.count, lo + max(0, count))
        queue.replaceSubrange(lo..<hi, with: items)
    }

    func insertUpcoming(_ items: [SetlistPlayer.Item], before uid: UUID?) {
        guard isRunning, !items.isEmpty else { return }
        log.append("insert")
        if let uid, let i = queue.firstIndex(where: { $0.uid == uid }), i > currentIndex {
            queue.insert(contentsOf: items, at: i)
        } else {
            queue += items
        }
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
        if on { isSystemPaused = false }
    }

    func seek(toMs ms: Int) {
        log.append("seek")
        setPosition(ms)
    }

    func setRepeatMode(_ mode: RepeatMode) { repeatMode = mode }
    func setShuffle(_ on: Bool) { shuffleEnabled = on }

    func silenceForController() {
        guard isPlaying || pendingStartWillPlay || isTransitioning else { return }
        log.append("silence")
        setPosition(positionMs)
        isPlaying = false
        pendingStartWillPlay = false
        isTransitioning = false
    }

    // MARK: Simulated local user actions (what the Now Playing UI would do)

    func userSkipNext() {
        guard isRunning, currentIndex + 1 < queue.count else { return }
        currentIndex += 1
        setPosition(0)
        transition(.user)
    }
    func userSetPlaying(_ on: Bool) {
        userPlayIntentSeq += 1
        lastUserPlayIntent = on
        setPosition(positionMs); isPlaying = on
        if on { isSystemPaused = false }
    }
    func userSeek(_ ms: Int) { setPosition(ms) }
    func userAppend(_ items: [SetlistPlayer.Item]) { queue += items }
    func userRemoveUpcoming(at offset: Int) {
        let i = currentIndex + 1 + offset
        guard queue.indices.contains(i) else { return }
        queue.remove(at: i)
    }
    func userPlay(_ items: [SetlistPlayer.Item]) {
        queue = items; currentIndex = 0; isRunning = true; isPlaying = true; setPosition(0)
        transition(.user)
    }

    // MARK: Simulated player-driven events (no listener involved)

    /// The player moved on BY ITSELF (`cause`: a natural end, a stall hop, a dead source…).
    /// Past the last row a natural end stops the set (the sequencer's end-of-set teardown).
    func simulateAutoAdvance(_ cause: SetlistPlayer.TransitionCause) {
        guard isRunning else { return }
        transition(cause)
        if currentIndex + 1 < queue.count {
            currentIndex += 1
            setPosition(0)
        } else {
            isRunning = false
            isPlaying = false
            queue = []
            currentIndex = 0
        }
    }
    /// The device's SYSTEM paused it (an interruption without resume / a route loss) — no
    /// listener intent recorded.
    func simulateSystemPause() {
        guard isPlaying else { return }
        setPosition(positionMs)
        isPlaying = false
        isSystemPaused = true
    }
    /// A start in flight: nothing sounds yet, and it WILL sound when it settles.
    func beginPendingStart() {
        isTransitioning = true
        pendingStartWillPlay = true
        setPosition(positionMs)
        isPlaying = false
    }
    func settlePendingStart() {
        isTransitioning = false
        if pendingStartWillPlay { pendingStartWillPlay = false; setPosition(positionMs); isPlaying = true }
    }
}
