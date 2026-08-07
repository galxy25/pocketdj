import Foundation
import Observation

/// The Collectors Puzzle round engine — APP-SCOPED (a running round survives tab
/// switches, per the SetlistPlayer/MixEngine doctrine). Audio flows ONLY through the
/// app-scoped `SetlistPlayer` (the existing one-audio-owner: provider chain,
/// NowPlayingArbiter, lock-screen card all unchanged) — this engine adds no audio nodes.
///
/// The engine stays authoritative for SCORING; the sequencer stays authoritative for
/// audio POSITION — the ticker's drift re-sync records "expired" for every track the
/// audio advanced past without a player action (natural end or lock-screen ⏭).
@MainActor
@Observable
final class CollectorsPuzzleEngine {

    enum Phase: Equatable {
        case idle, sampling, countdown(Int), running, finished
    }

    private(set) var phase: Phase = .idle
    private(set) var settings: PuzzleSettings
    private(set) var roundId = UUID()
    private(set) var queue: [IndexSong] = []
    private(set) var queueIndex = 0
    var current: IndexSong? {
        phase == .running && queueIndex < queue.count ? queue[queueIndex] : nil
    }
    private(set) var score = 0
    private(set) var assignedThisRound:
        [(songId: String, title: String, artist: String, collectionId: String, collectionName: String)] = []
    /// Wall-clock round deadline (seconds since 1970) — backgrounding holds it.
    private(set) var deadlineEpoch: TimeInterval = 0
    var remainingSeconds: Int {
        max(0, Int((deadlineEpoch - now().timeIntervalSince1970).rounded(.up)))
    }
    private(set) var lastRunRecord: GameScoreboardStore.RunRecord?
    private(set) var isNewHighScore = false
    private(set) var lastError: String?
    /// True when a top-up found the whole pool exhausted — the view shows
    /// "Catalog exhausted!" and offers an early end.
    private(set) var poolExhausted = false

    private let app: AppModel
    private let sequencer: SetlistPlayer
    private let collections: CollectionsStore
    private let favorites: FavoritesStore
    private let playStats: PlayStatsStore
    private let scoreboard: GameScoreboardStore
    private let decisions: PuzzleDecisionStore

    // Test seams.
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var rng: () -> Double = { Double.random(in: 0..<1) }
    /// Tests skip the 3-2-1.
    @ObservationIgnored var countdownEnabled = true

    @ObservationIgnored private var tickerTask: Task<Void, Never>?
    /// Single-flight guard on the mid-round top-up sample.
    @ObservationIgnored private var toppingUp = false
    private static let settingsKey = "pdj.puzzle.settings.v1"
    @ObservationIgnored private let defaults: UserDefaults

    init(app: AppModel, sequencer: SetlistPlayer, collections: CollectionsStore,
         favorites: FavoritesStore, playStats: PlayStatsStore,
         scoreboard: GameScoreboardStore, decisions: PuzzleDecisionStore,
         defaults: UserDefaults = .standard) {
        self.app = app
        self.sequencer = sequencer
        self.collections = collections
        self.favorites = favorites
        self.playStats = playStats
        self.scoreboard = scoreboard
        self.decisions = decisions
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey),
           let s = try? JSONDecoder().decode(PuzzleSettings.self, from: data) {
            settings = s
        } else {
            settings = PuzzleSettings()
        }
    }

    /// Update + persist the round settings (last-used settings survive relaunch).
    func updateSettings(_ s: PuzzleSettings) {
        settings = s
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.settingsKey) }
    }

    /// Snapshot the sampler inputs on the main actor (cheap: COW arrays + sets).
    private func snapshotInputs() -> PuzzleSampler.Inputs {
        let albumsById = app.albumsById
        var genreBySongId: [String: String] = [:]
        genreBySongId.reserveCapacity(app.songs.count)
        // Genre lives on the ALBUM; category once per album, then fan out.
        var categoryByAlbum: [String: String] = [:]
        for song in app.songs {
            guard let albumId = song.albumId else { continue }
            let cat = categoryByAlbum[albumId] ?? Genre.category(albumsById[albumId]?.genre)
            categoryByAlbum[albumId] = cat
            genreBySongId[song.id] = cat
        }
        var membershipUnion = Set<String>()
        for cid in settings.membershipCollectionIds {
            membershipUnion.formUnion(memberIds(of: cid))
        }
        let perTarget = settings.targetCollectionIds.map { Set(memberIds(of: $0)) }
        return PuzzleSampler.Inputs(songs: app.songs, genreBySongId: genreBySongId,
                                    favoriteIds: favorites.favoriteIds,
                                    playCounts: playStats.playCountsSnapshot(),
                                    membershipUnion: membershipUnion,
                                    perTargetMembership: perTarget)
    }

    private func memberIds(of collectionId: String) -> [String] {
        collectionId.hasPrefix("pkt_")
            ? collections.songIds(forPocket: collectionId)
            : collections.songIds(forPlaylist: collectionId)
    }

    /// How many songs match the current settings ("N songs match" in setup).
    func poolCount() async -> Int {
        let inputs = snapshotInputs()
        let settings = settings
        return await Task.detached(priority: .userInitiated) {
            PuzzleSampler.poolCount(settings: settings, inputs: inputs)
        }.value
    }

    /// Start a round: sample → countdown → hand the queue to the sequencer → run.
    func startRound() async {
        guard phase == .idle || phase == .finished else { return }
        guard (1...3).contains(settings.targetCollectionIds.count) else {
            lastError = "Pick 1–3 target collections."
            return
        }
        lastError = nil
        poolExhausted = false
        phase = .sampling
        let inputs = snapshotInputs()
        let settings = settings
        let rng = rng
        // Nobody can clear more than ~1 song/sec — sample enough to never starve.
        let n = max(60, settings.roundSeconds)
        let sampled = await Task.detached(priority: .userInitiated) {
            PuzzleSampler.sample(n, settings: settings, inputs: inputs, rng: rng)
        }.value
        guard !sampled.isEmpty else {
            lastError = "No songs match these settings."
            phase = .idle
            return
        }
        queue = sampled
        queueIndex = 0
        score = 0
        assignedThisRound = []
        isNewHighScore = false
        lastRunRecord = nil
        roundId = UUID()
        if countdownEnabled {
            for n in stride(from: 3, through: 1, by: -1) {
                phase = .countdown(n)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        sequencer.play(queue.map { song in
            SetlistPlayer.Item(id: song.id, title: song.name, artist: song.artist,
                               lengthMs: song.length)
        }, sourceSetlistId: nil)
        deadlineEpoch = now().timeIntervalSince1970 + Double(settings.roundSeconds)
        phase = .running
        startTicker()
    }

    private func startTicker() {
        tickerTask?.cancel()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tickOnce()
                try? await Task.sleep(for: .seconds(0.25))
            }
        }
    }

    /// One ticker turn — also the test seam (tests drive ticks directly, no timers).
    func tickOnce() {
        guard phase == .running else { return }
        if now().timeIntervalSince1970 >= deadlineEpoch {
            endRound()
            return
        }
        // Drift re-sync: the audio advanced past the engine's position (natural track
        // end, or a lock-screen ⏭ the engine never saw) — each passed song EXPIRED
        // without a player action; audio stays authoritative for position.
        if sequencer.isRunning, sequencer.index > queueIndex {
            let target = min(sequencer.index, queue.count)
            for i in queueIndex..<target {
                decisions.record(roundId: roundId, songId: queue[i].id, action: "expired",
                                 positionInRound: i, settings: settings)
            }
            queueIndex = target
        }
        // Top-up: never let the visible queue starve mid-round (single-flight).
        if queue.count - queueIndex < 10, !toppingUp, !poolExhausted {
            toppingUp = true
            let shown = Set(queue.map(\.id))
            let inputs = snapshotInputs()
            let settings = settings
            let rng = rng
            Task { [weak self] in
                let extra = await Task.detached(priority: .userInitiated) {
                    PuzzleSampler.sample(40, settings: settings, inputs: inputs,
                                         rng: rng, excluding: shown)
                }.value
                guard let self else { return }
                self.toppingUp = false
                guard self.phase == .running else { return }
                if extra.isEmpty {
                    self.poolExhausted = true
                    return
                }
                self.queue.append(contentsOf: extra)
                self.sequencer.appendToQueue(extra.map {
                    SetlistPlayer.Item(id: $0.id, title: $0.name, artist: $0.artist,
                                       lengthMs: $0.length)
                })
            }
        }
    }

    /// File the current song into target `i` — one point.
    func assign(toTargetIndex i: Int) {
        guard phase == .running, let song = current,
              settings.targetCollectionIds.indices.contains(i) else { return }
        let cid = settings.targetCollectionIds[i]
        let name = collectionName(cid)
        collections.addSong(song.id,
                            to: AddTarget(kind: cid.hasPrefix("pkt_") ? .pocket : .playlist, id: cid))
        score += 1
        assignedThisRound.append((songId: song.id, title: song.name, artist: song.artist,
                                  collectionId: cid, collectionName: name))
        decisions.record(roundId: roundId, songId: song.id, action: "assigned",
                         collectionId: cid, collectionName: name,
                         positionInRound: queueIndex, settings: settings)
        advance()
    }

    /// Pass on the current song — no point, logged as a real signal.
    func skip() {
        guard phase == .running, let song = current else { return }
        decisions.record(roundId: roundId, songId: song.id, action: "skipped",
                         positionInRound: queueIndex, settings: settings)
        advance()
    }

    private func advance() {
        queueIndex += 1
        sequencer.skipNext()
    }

    /// End the round (deadline hit or the user's End button): stop audio, record the run.
    func endRound() {
        guard phase == .running else { return }
        tickerTask?.cancel()
        tickerTask = nil
        sequencer.stop()
        phase = .finished
        let best = scoreboard.bestScore(.collectorsPuzzle) ?? 0
        isNewHighScore = score > best
        lastRunRecord = scoreboard.record(
            game: .collectorsPuzzle, score: score, settingsSummary: settings.summaryLine,
            detail: ["assigned": String(assignedThisRound.count),
                     "roundSeconds": String(settings.roundSeconds)])
    }

    /// Dismiss the summary back to setup (settings kept).
    func reset() {
        guard phase == .finished else { return }
        phase = .idle
        poolExhausted = false
    }

    func collectionName(_ id: String) -> String {
        collections.pocket(id)?.name ?? collections.playlist(id)?.name ?? "Collection"
    }
}
