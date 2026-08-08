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
        // While the Add-to sheet is open the clock is HELD (see `beginFiling`) — read it
        // against the moment the sheet opened so the digits FREEZE behind the modal instead
        // of counting down time `endFiling` is about to buy back.
        let ref = filingSongId != nil ? filingStartedAt : now().timeIntervalSince1970
        return max(0, Int((deadlineEpoch - ref).rounded(.up)))
    }
    private(set) var lastRunRecord: GameScoreboardStore.RunRecord?
    private(set) var isNewHighScore = false
    private(set) var lastError: String?
    /// True when a top-up found the whole pool exhausted — the view shows
    /// "Catalog exhausted!" and offers an early end.
    private(set) var poolExhausted = false

    // MARK: - Filing through the Add-to picker ("file into ANY collection")

    /// Non-nil while the Add-to sheet is open for THIS card's song id. While it is set the
    /// round clock is HELD and the ticker's whole position/expiry/watchdog pass is suspended
    /// (see `tickOnce`): the player is reading a picker, not passing on cards, so the audio
    /// position says nothing about their position. The id is carried (not just a Bool) so a
    /// mid-sheet drift or top-up can never make the sheet file the WRONG card.
    private(set) var filingSongId: String?
    @ObservationIgnored private var filingStartedAt: TimeInterval = 0
    /// Max seconds of round clock a SINGLE sheet opening can buy back. Uncapped this is an
    /// untimed game (leave the picker open, curate at leisure, one point, repeat); at 0 the
    /// sheet path — the only scoring path when no targets are selected — is unplayable
    /// against a one-tap target button. 20 s comfortably covers "search, read, tap".
    static let maxFilingCreditSeconds: Double = 20

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
    /// Which ROUND-queue position the sequencer's own index 0 maps to. `startRound` hands
    /// the whole queue over (0); the audio watchdog re-hands only the TAIL from the current
    /// card, so the sequencer's index restarts at 0 against a later song — every read of
    /// `sequencer.index` adds this back so the drift re-sync stays honest.
    @ObservationIgnored private var audioBaseIndex = 0
    /// The last queue position audio was armed for. The watchdog re-arms AT MOST ONCE per
    /// card, so a card whose audio genuinely can't start costs one retry, never a loop.
    @ObservationIgnored private var lastAudioArmIndex: Int?
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
        // A target/filter collection the user has since DELETED (or that never synced to this
        // device) must not survive the reload: it leaves the setup screen with no checked row
        // yet a live Start button, and a round then files songs into an assign button labelled
        // "Collection" that writes nowhere. Prune to what exists right now.
        settings.targetCollectionIds.removeAll { !collectionExists($0) }
        settings.membershipCollectionIds = settings.membershipCollectionIds.filter(collectionExists)
    }

    /// Does this pls_/pkt_ id still resolve to a collection on this device?
    private func collectionExists(_ id: String) -> Bool {
        collections.pocket(id) != nil || collections.playlist(id) != nil
    }

    /// UI tests get an isolated defaults suite so a round's last-used settings can't leak
    /// from one test launch into the next (the CollectionsStore/BurnStore `launchURL`
    /// doctrine, applied to the one piece of puzzle state that lives in UserDefaults).
    static func launchDefaults() -> UserDefaults {
        guard ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil,
              let suite = UserDefaults(suiteName: "pdj.uitest.puzzle") else { return .standard }
        suite.removeObject(forKey: settingsKey)
        return suite
    }

    /// Update + persist the round settings (last-used settings survive relaunch).
    func updateSettings(_ s: PuzzleSettings) {
        settings = s
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.settingsKey) }
    }

    /// Snapshot the sampler inputs on the main actor — RAW COW containers ONLY. The
    /// derived structures (the ~96k-entry genre map, the membership Sets) are built
    /// OFF the main actor by `PuzzleSampler.Inputs(raw:)`: this runs on every debounced
    /// settings keystroke AND from the 0.25 s ticker's mid-round top-up, where a
    /// full-catalog walk on the main thread is a visible runloop stall (the Browse
    /// off-main doctrine).
    private func snapshotRawInputs() -> PuzzleSampler.RawInputs {
        let audio = audioAvailability()
        return PuzzleSampler.RawInputs(
            songs: app.songs,
            albumsById: app.albumsById,
            favoriteIds: favorites.favoriteIds,
            playCounts: playStats.playCountsSnapshot(),
            membershipCollections: settings.membershipCollectionIds.map { memberIds(of: $0) },
            targetCollections: settings.targetCollectionIds.map { memberIds(of: $0) },
            ripManifest: audio.ripManifest,
            burnedIds: audio.burnedIds,
            canStreamAppleMusic: audio.canStreamAppleMusic)
    }

    /// What audio this device can start RIGHT NOW, snapshotted on the main actor as raw COW
    /// containers only (the id Sets are derived off-actor in `PuzzleSampler.Inputs`).
    /// Injected as a closure so the engine keeps its narrow store list and unit tests can
    /// declare exactly which songs are playable. The default reports "nothing known
    /// playable": the sampler's playable-first pass then comes back empty and it falls back
    /// to the whole catalog, so a bare engine (tests, previews) behaves exactly as before.
    @ObservationIgnored var audioAvailability: () -> AudioAvailability = { AudioAvailability() }

    struct AudioAvailability {
        var ripManifest: [String: RipsStore.ManifestEntry] = [:]
        var burnedIds: Set<String> = []
        var canStreamAppleMusic: Bool = false
    }

    // MARK: - Sequencer ownership

    /// Prefix of the `sourceSetlistId` a puzzle run tags the shared sequencer with.
    static let runTagPrefix = "puzzle_"
    /// THIS round's sequencer tag.
    private var runTag: String { "\(Self.runTagPrefix)\(roundId.uuidString)" }
    /// True while the shared `SetlistPlayer` is still running the queue THIS round handed
    /// it. The sequencer is app-scoped: any other surface (Browse, a setlist detail, an
    /// MwF accept) may `play()` over it mid-round, which resets `index` to 0 against a
    /// foreign queue — so every read of `sequencer.index` and every skip/stop is gated.
    private var ownsSequencer: Bool {
        sequencer.isRunning && sequencer.sourceSetlistId == runTag
    }
    /// Someone ELSE is playing: the round can no longer trust the audio position, and must
    /// never skip or stop that run. (Distinct from "nothing is playing", which is just the
    /// queue running out.)
    private var sequencerTakenOver: Bool {
        sequencer.isRunning && sequencer.sourceSetlistId != runTag
    }

    private func memberIds(of collectionId: String) -> [String] {
        collectionId.hasPrefix("pkt_")
            ? collections.songIds(forPocket: collectionId)
            : collections.songIds(forPlaylist: collectionId)
    }

    /// How many songs match the current settings ("N songs match" in setup).
    func poolCount() async -> Int {
        let raw = snapshotRawInputs()
        let settings = settings
        return await Task.detached(priority: .userInitiated) {
            PuzzleSampler.poolCount(settings: settings, inputs: PuzzleSampler.Inputs(raw: raw))
        }.value
    }

    /// Start a round: sample → countdown → hand the queue to the sequencer → run.
    ///
    /// TARGETS ARE OPTIONAL (Levi 2026-08). A round needs exactly ONE thing to start: a
    /// non-empty sample. With no targets there are no one-tap assign buttons — every card is
    /// filed through the Add-to picker instead (`beginFiling`/`endFiling`), which files into
    /// ANY collection, so a round with no targets is a fully playable, fully scorable round.
    /// The pool is unaffected: `PuzzleSampler` already no-ops its all-targets filter on an
    /// empty array, and `assign(toTargetIndex:)` already bails on an out-of-range index.
    func startRound() async {
        guard phase == .idle || phase == .finished else { return }
        lastError = nil
        poolExhausted = false
        // A sheet the PREVIOUS round left open (dismissed without its onChange landing) must
        // never hold the new round's ticker hostage.
        filingSongId = nil
        // A stale top-up from the PREVIOUS round may still be in flight; its continuation
        // is round-guarded (see tickOnce) and so can never clear this flag for us.
        toppingUp = false
        phase = .sampling
        let raw = snapshotRawInputs()
        let settings = settings
        let rng = rng
        // Nobody can clear more than ~1 song/sec — sample enough to never starve.
        let n = max(60, settings.roundSeconds)
        let sampled = await Task.detached(priority: .userInitiated) {
            PuzzleSampler.sample(n, settings: settings, inputs: PuzzleSampler.Inputs(raw: raw), rng: rng)
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
        armAudio(fromQueueIndex: 0)
        deadlineEpoch = now().timeIntervalSince1970 + Double(settings.roundSeconds)
        phase = .running
        startTicker()
    }

    /// Hand the round's queue (from `i` onward) to the shared sequencer under THIS round's
    /// tag and start it. The single place audio is ever armed, so `audioBaseIndex` and the
    /// once-per-card guard can't drift apart.
    private func armAudio(fromQueueIndex i: Int) {
        guard i < queue.count else { return }
        audioBaseIndex = i
        lastAudioArmIndex = i
        sequencer.play(queue[i...].map { song in
            SetlistPlayer.Item(id: song.id, title: song.name, artist: song.artist,
                               lengthMs: song.length)
        }, sourceSetlistId: runTag)
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
        // Ownership first: another surface replaced the shared queue (the user popped to
        // Browse and played a playlist). Its index says NOTHING about this round, so end
        // the round cleanly — record the run, log nothing, and leave THEIR audio alone.
        if sequencerTakenOver {
            endRound(stopAudio: false)
            return
        }
        // FILING HOLD — the Add-to sheet owns the round. This return sits BEFORE the deadline
        // check, the audio watchdog, the drift re-sync AND the top-up, deliberately, so the
        // hold is one trivially-auditable early exit. The drift block is the dangerous one:
        // `SetlistPlayer` has no pause API, so audio keeps running behind the sheet, and if
        // the song ends naturally while the picker is open the drift re-sync would write
        // "expired" rows and advance `queueIndex` PAST the very card the sheet is filing —
        // the point would then score against the wrong song and the round would double-
        // advance. `endFiling` re-syncs the clock and the audio when the sheet closes.
        if filingSongId != nil { return }
        if now().timeIntervalSince1970 >= deadlineEpoch {
            endRound()
            return
        }
        // AUDIO WATCHDOG — the "a card on screen is a song you can hear" contract. The shared
        // sequencer stops ITSELF when a run runs out of queue or when every remaining source
        // failed to resolve, and from the round's side that is indistinguishable from silence
        // with nobody owning the player. Re-hand the queue from the CURRENT card so the round
        // gets its audio back instead of playing out mute. Not a takeover: `sequencerTakenOver`
        // is checked above, so nothing else is playing when we get here.
        if !sequencer.isRunning, current != nil, lastAudioArmIndex != queueIndex {
            armAudio(fromQueueIndex: queueIndex)
            return
        }
        // Drift re-sync: the audio advanced past the engine's position (natural track
        // end, or a lock-screen ⏭ the engine never saw) — each passed song EXPIRED
        // without a player action; audio stays authoritative for position.
        let audioPosition = audioBaseIndex + sequencer.index
        if ownsSequencer, audioPosition > queueIndex {
            let target = min(audioPosition, queue.count)
            // ONE persist for the whole burst (a per-row save re-encodes the entire
            // ≤20k-row document — inside the 0.25 s ticker, per passed song).
            decisions.recordBatch((queueIndex..<target).map {
                (songId: queue[$0].id, action: "expired", positionInRound: $0)
            }, roundId: roundId, settings: settings)
            queueIndex = target
        }
        // Top-up: never let the visible queue starve mid-round (single-flight).
        if queue.count - queueIndex < 10, !toppingUp, !poolExhausted {
            toppingUp = true
            let shown = Set(queue.map(\.id))
            let raw = snapshotRawInputs()
            let settings = settings
            let rng = rng
            // The round this top-up was armed FOR. `phase == .running` alone cannot tell
            // "this round still runs" from "a DIFFERENT round now runs" — an End→Start
            // while the sample is in flight would otherwise land round A's songs (wrong
            // filters, possible dupes) in round B's queue and flip B's poolExhausted.
            let armedRoundId = roundId
            Task { [weak self] in
                let extra = await Task.detached(priority: .userInitiated) {
                    PuzzleSampler.sample(40, settings: settings,
                                         inputs: PuzzleSampler.Inputs(raw: raw),
                                         rng: rng, excluding: shown)
                }.value
                // A stale round's continuation mutates NOTHING — not even `toppingUp`,
                // which belongs to the new round now (startRound reset it).
                guard let self, self.roundId == armedRoundId else { return }
                self.toppingUp = false
                guard self.phase == .running else { return }
                if extra.isEmpty {
                    self.poolExhausted = true
                    return
                }
                // The ROUND's queue always grows: it is this engine's own data, and the
                // round stays fully playable (assign/skip) even with no audio at all — a
                // sequencer-gated append would silently starve a silent round mid-play.
                self.queue.append(contentsOf: extra)
                // The AUDIO queue only grows while we still own the sequencer: the await
                // above is a window in which another surface could have played over it,
                // and appending into THEIR queue would hijack that playback. Divergence is
                // safe — every read of `sequencer.index` is ownership-gated, ownership is
                // never re-acquired mid-round (only `startRound` stamps the run tag), and
                // the very next tick ends a taken-over round.
                guard self.ownsSequencer else { return }
                self.sequencer.appendToQueue(extra.map {
                    SetlistPlayer.Item(id: $0.id, title: $0.name, artist: $0.artist,
                                       lengthMs: $0.length)
                })
            }
        }
    }

    /// File the current song into target `i` — one point.
    func assign(toTargetIndex i: Int) {
        guard phase == .running else { return }
        if sequencerTakenOver { endRound(stopAudio: false); return }
        guard let song = current, settings.targetCollectionIds.indices.contains(i) else { return }
        let cid = settings.targetCollectionIds[i]
        collections.addSong(song.id,
                            to: AddTarget(kind: cid.hasPrefix("pkt_") ? .pocket : .playlist, id: cid))
        creditFiling(song: song, collectionId: cid, collectionName: collectionName(cid))
    }

    /// THE ONE PLACE A FILING SCORES. Both the one-tap target buttons and the Add-to sheet
    /// land here, so the point, the summary row, the decision row (the rec-engine's training
    /// signal) and the advance can never drift apart between the two paths.
    ///
    /// ONE POINT PER CARD, not per collection: the card advances on the first successful add,
    /// so the multi-select picker cannot be farmed (open the sheet, tap five collections, five
    /// points). That is enforced STRUCTURALLY — `current` becomes the next song here — and it
    /// is what keeps a new score comparable to every historical one ("One point per song").
    private func creditFiling(song: IndexSong, collectionId: String, collectionName: String) {
        score += 1
        assignedThisRound.append((songId: song.id, title: song.name, artist: song.artist,
                                  collectionId: collectionId, collectionName: collectionName))
        decisions.record(roundId: roundId, songId: song.id, action: "assigned",
                         collectionId: collectionId, collectionName: collectionName,
                         positionInRound: queueIndex, settings: settings)
        advance()
    }

    /// The view calls this BEFORE presenting the Add-to sheet. Returns false when there is
    /// nothing to file (not running, no card, a sheet already up, or the sequencer was taken
    /// over — which ends the round exactly as `assign`/`skip` do).
    @discardableResult
    func beginFiling() -> Bool {
        guard phase == .running, let song = current, filingSongId == nil else { return false }
        if sequencerTakenOver { endRound(stopAudio: false); return false }
        filingSongId = song.id
        filingStartedAt = now().timeIntervalSince1970
        return true
    }

    /// The view calls this on dismiss — with a target (the player filed the card: score it) or
    /// nil (cancelled: no point, NO advance, the card stays). IDEMPOTENT: it is reachable from
    /// both the sheet's completion callback and the binding's `onChange`, and a second call
    /// must not credit the clock twice or score twice.
    ///
    /// CANCEL IS NOT A SKIP, deliberately: a player may cancel to hit a target button instead,
    /// and silently burning their card would be the worst possible surprise in a timed game.
    /// `skip()` remains the explicit pass and still records `action: "skipped"`.
    func endFiling(assignedTo target: AddTarget?) {
        guard let songId = filingSongId else { return }
        filingSongId = nil
        // Credit the held time, capped — see `maxFilingCreditSeconds`.
        deadlineEpoch += min(max(0, now().timeIntervalSince1970 - filingStartedAt),
                             Self.maxFilingCreditSeconds)
        // The card is verified BY ID: a stale sheet (the round ended, or the queue moved under
        // it) files nothing rather than scoring against the wrong song.
        if let target, phase == .running, let song = current, song.id == songId {
            creditFiling(song: song, collectionId: target.id,
                         collectionName: collectionName(target.id))
        }
        // Re-marry audio to the card the round is now showing. The audio ran on behind the
        // sheet (no pause API), so this is the same one-line re-arm the watchdog uses.
        if phase == .running, current != nil, !sequencerTakenOver,
           !sequencer.isRunning || audioBaseIndex + sequencer.index != queueIndex {
            armAudio(fromQueueIndex: queueIndex)
        }
    }

    /// Pass on the current song — no point, logged as a real signal.
    func skip() {
        guard phase == .running else { return }
        if sequencerTakenOver { endRound(stopAudio: false); return }
        guard let song = current else { return }
        decisions.record(roundId: roundId, songId: song.id, action: "skipped",
                         positionInRound: queueIndex, settings: settings)
        advance()
    }

    private func advance() {
        queueIndex += 1
        // Only ever skip OUR run — a foreign queue's track is not ours to advance.
        if ownsSequencer { sequencer.skipNext() }
    }

    /// End the round (deadline hit or the user's End button): stop audio, record the run.
    /// `stopAudio: false` is the ownership-lost path — the round is recorded and the
    /// ticker torn down, but whatever ELSE is playing keeps playing.
    func endRound(stopAudio: Bool = true) {
        guard phase == .running else { return }
        tickerTask?.cancel()
        tickerTask = nil
        if stopAudio, ownsSequencer { sequencer.stop() }
        // Land the round's rows now — WITHOUT blocking the main actor on an MB-scale
        // encode right as the summary presents. The scenePhase-background flush() still
        // drains synchronously if a suspension races the write.
        decisions.flushAsync()
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
