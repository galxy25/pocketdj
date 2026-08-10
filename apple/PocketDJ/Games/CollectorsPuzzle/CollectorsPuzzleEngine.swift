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
    /// Every target the OPEN picker reported a successful ADD into, in tap order, deduped by
    /// (kind,id) — a playlist filed into two chapters is still one collection. Observed (not
    /// `@ObservationIgnored`) so a future in-round badge reads it correctly.
    private(set) var filedTargetsThisOpening: [AddTarget] = []
    /// ONE POINT PER CARD, not per collection (Levi + lead, 2026-08-08). The rush rewards
    /// filing MANY songs; per-collection scoring would reward spamming one song into twenty
    /// crates and make every historical best incomparable. Flip this constant to change that
    /// decision — and only that constant, since it is the single place a filing scores.
    static let pointsPerFiledCard = 1
    /// Max seconds of round clock a SINGLE sheet opening can buy back. Uncapped this is an
    /// untimed game (leave the picker open, curate at leisure, one point, repeat); at 0 the
    /// sheet path — the only scoring path when no targets are selected — is unplayable
    /// against a one-tap target button. 20 s comfortably covers "search, read, tap".
    static let maxFilingCreditSeconds: Double = 20
    /// Extra allowance per collection filed BEYOND the first — see the credit site in
    /// `endFiling`. Multi-collection filing is the point of the feature; this is what keeps
    /// using it from costing round time.
    static let filingCreditPerExtraTarget: Double = 10
    /// Hard ceiling on a single opening's credit however many crates were filed, so the
    /// allowance can never become "the clock stops while the picker is open".
    static let maxFilingCreditCeilingSeconds: Double = 60

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

    /// LIFETIME play counts for the sampler's play-count bias. Injected in PocketDJApp from
    /// `PlayCountService.snapshot()` — Apple's ~144k-play baseline plus this app's own plays.
    ///
    /// Without it the bias reads `PlayStatsStore` alone, which knows only what PocketDJ itself
    /// played (~700 songs of a 90k catalog), so "favour what I play" barely moved the weights and
    /// "avoid what I play" treated a song hammered for a decade in Music.app as brand new. A nil
    /// provider keeps exactly that old behaviour, which is what unit tests and previews want.
    @ObservationIgnored var playCountsProvider: (() -> [String: Int])?

    /// LAST-PLAYED dates for the sampler's recency bias, from
    /// `PlayCountService.lastPlayedSnapshot()` — Apple's 56k dated songs merged with this app's
    /// own. A nil provider yields an empty map, which makes both recency biases a uniform scale
    /// over the pool and therefore leaves the sample byte-identical to today's — the same
    /// "absent provider ⇒ old behaviour" contract `playCountsProvider` has.
    @ObservationIgnored var lastPlayedProvider: (() -> [String: Double])?

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
        // Similarity only applies when there IS something to be similar to. Skipping the
        // snapshot when it can't be used keeps a target-less round's cost byte-identical to
        // today's (and keeps `allCollectionMemberships` — the expensive one — unread).
        let wantsSimilarity = settings.similarity != .off && !settings.targetCollectionIds.isEmpty
        // The dates are wanted by TWO consumers — the recency bias and the similarity ranker's
        // `wRecency` term — so a round needs them if either is live. Skipped otherwise: the map
        // is ~56k rows and this runs on every debounced settings keystroke AND the 0.25 s
        // mid-round top-up (the Browse off-main doctrine).
        let wantsRecency = settings.recencyBias != .off || wantsSimilarity
        let lastPlayed = wantsRecency ? (lastPlayedProvider?() ?? [:]) : [:]
        return PuzzleSampler.RawInputs(
            songs: app.songs,
            albumsById: app.albumsById,
            favoriteIds: favorites.favoriteIds,
            playCounts: playCountsProvider?() ?? playStats.playCountsSnapshot(),
            membershipCollections: settings.membershipCollectionIds.map { memberIds(of: $0) },
            targetCollections: settings.targetCollectionIds.map { memberIds(of: $0) },
            ripManifest: audio.ripManifest,
            burnedIds: audio.burnedIds,
            canStreamAppleMusic: audio.canStreamAppleMusic,
            allCollections: wantsSimilarity ? allCollectionMemberships() : [],
            plays: wantsSimilarity ? playHistorySnapshot() : [],
            cloudRanks: wantsSimilarity ? cloudRanks : [:],
            buildSimilarityProfile: wantsSimilarity,
            lastPlayedMs: lastPlayed,
            hasRecency: !lastPlayed.isEmpty)
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

    // MARK: - Similarity seams (injected closures, so `init` never grows)

    /// The play log — the "playback history graph" similarity signal. Injected as a closure
    /// for the same reason `audioAvailability` is: the engine keeps its narrow store list and
    /// its four test files keep their existing constructions. A bare engine returns [], which
    /// simply drops the co-play term from the profile's denominator. Hands over the raw COW
    /// array; the (songId, atMs) projection happens OFF the main actor in `Inputs(raw:)`.
    @ObservationIgnored var playHistorySnapshot: () -> [PlayHistoryStore.PlayEvent] = { [] }
    /// EVERY collection's membership — the "shared with another collection" signal. Same
    /// pattern, and CAPPED + memoized on the store side: `songIds(forPlaylist:)` walks a
    /// playlist's whole node tree and this is read from the 0.25 s ticker's top-up.
    @ObservationIgnored var allCollectionMemberships: () -> [[String]] = { [] }
    /// The CLOUD similarity booster: collection ids → similar song ids, best first. Default
    /// returns [] — the rec engine is off by default and the route may not be deployed, and
    /// neither case is a failure. Fetched ONCE per round, under a hard budget, before the
    /// sample; NEVER from the ticker (a timed game must never wait on a network).
    @ObservationIgnored var cloudSimilarProvider: (_ collectionIds: [String]) async -> [String] = { _ in [] }
    /// THIS round's cloud rank map (songId → 0…1). Frozen at `startRound`, reused by every
    /// top-up so the round's character doesn't drift at song 51.
    @ObservationIgnored private var cloudRanks: [String: Double] = [:]
    /// Hard budget on the one cloud call. A slow server must lose, not stall the countdown.
    static let cloudSimilarBudgetSeconds: Double = 2.5

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

    /// How many songs match the current settings, and how many of those the similarity ranker
    /// shortlists ("N songs match · M similar" in setup). ONE detached walk, not two.
    func poolStats() async -> PuzzleSampler.PoolStats {
        let raw = snapshotRawInputs()
        let settings = settings
        return await Task.detached(priority: .userInitiated) {
            PuzzleSampler.poolStats(settings: settings, inputs: PuzzleSampler.Inputs(raw: raw))
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
        // never hold the new round's ticker hostage — nor leave its noted targets showing.
        filingSongId = nil
        filedTargetsThisOpening = []
        // A stale top-up from the PREVIOUS round may still be in flight; its continuation
        // is round-guarded (see tickOnce) and so can never clear this flag for us.
        toppingUp = false
        phase = .sampling
        // THE ONE CLOUD CALL, here and nowhere else: before the sample, so the wait hides
        // behind the sampling spinner, and never in `tickOnce`'s top-up. Budgeted — if the
        // budget expires the round starts local-only and stays that way, because a timed game
        // must never wait on a network.
        await refreshCloudRanks()
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

    /// Fetch (or clear) THIS round's cloud rank map. Never throws, never surfaces an error:
    /// the engine being off, unreachable, or serving a 404 because the route isn't deployed
    /// yet are all the SAME outcome — an empty map, and a round that runs local-only, which
    /// is the default configuration rather than a fallback.
    private func refreshCloudRanks() async {
        cloudRanks = [:]
        let ids = settings.targetCollectionIds
        guard settings.similarity != .off, !ids.isEmpty else { return }
        let provider = cloudSimilarProvider
        let budget = Self.cloudSimilarBudgetSeconds
        let ranked: [String] = await withTaskGroup(of: [String]?.self) { group in
            group.addTask { await provider(ids) }
            group.addTask {
                try? await Task.sleep(for: .seconds(budget))
                return nil                       // the budget won the race
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
        guard !ranked.isEmpty else { return }
        let n = Double(ranked.count)
        // `uniquingKeysWith` and not `uniqueKeysWithValues`: a duplicate id in a server
        // response must not TRAP the app — the better (earlier) rank wins.
        cloudRanks = Dictionary(ranked.enumerated().map { ($0.element, max(0, 1 - Double($0.offset) / n)) },
                                uniquingKeysWith: { a, b in max(a, b) })
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
        let target = AddTarget(kind: cid.hasPrefix("pkt_") ? .pocket : .playlist, id: cid)
        collections.addSong(song.id, to: target)
        creditFiling(song: song, filedInto: [target])
    }

    /// THE ONE PLACE A FILING SCORES. Both the one-tap target buttons and the Add-to sheet
    /// land here, so the point, the summary row, the decision row (the rec-engine's training
    /// signal) and the advance can never drift apart between the two paths.
    ///
    /// ONE POINT PER CARD, not per collection — even when `targets` holds five of them. The
    /// picker is multi-select by design, so a per-ADD point would make one card worth five and
    /// every historical score meaningless. `pointsPerFiledCard` is the whole rule, and the card
    /// advances exactly once here whatever the length of `targets`.
    private func creditFiling(song: IndexSong, filedInto targets: [AddTarget]) {
        guard let primary = targets.first else { return }
        score += Self.pointsPerFiledCard
        assignedThisRound.append((songId: song.id, title: song.name, artist: song.artist,
                                  collectionId: primary.id,
                                  collectionName: Self.filedLabel(targets.map { collectionName($0.id) })))
        // The POINT is capped at one; the TRAINING SIGNAL is not. "This song belongs in these
        // five crates" is exactly what the rec engine wants, and `PuzzleDecisionStore.record`
        // coalesces its saves (scheduleSave), so N rows is still ONE document write.
        for t in targets {
            decisions.record(roundId: roundId, songId: song.id, action: "assigned",
                             collectionId: t.id, collectionName: collectionName(t.id),
                             positionInRound: queueIndex, settings: settings)
        }
        advance()
    }

    /// The summary row's one-line name for a filing: "Crate A" · "Crate A +2 more".
    static func filedLabel(_ names: [String]) -> String {
        guard let first = names.first else { return "Collection" }
        return names.count > 1 ? "\(first) +\(names.count - 1) more" : first
    }

    /// The view calls this BEFORE presenting the Add-to sheet. Returns false when there is
    /// nothing to file (not running, no card, a sheet already up, or the sequencer was taken
    /// over — which ends the round exactly as `assign`/`skip` do).
    @discardableResult
    func beginFiling() -> Bool {
        guard phase == .running, let song = current, filingSongId == nil else { return false }
        if sequencerTakenOver { endRound(stopAudio: false); return false }
        filingSongId = song.id
        filedTargetsThisOpening = []
        filingStartedAt = now().timeIntervalSince1970
        return true
    }

    /// The picker added the card to `target` while the sheet is STILL OPEN — a player filing
    /// one song into several collections, which is what the multi-select picker was always for.
    /// RECORDS ONLY: no point, no advance, no release of the clock hold, because the player is
    /// still filing. Ignored when no sheet is open (a late callback from a settled opening).
    func noteFiled(to target: AddTarget) {
        guard filingSongId != nil else { return }
        guard !filedTargetsThisOpening.contains(where: { $0.kind == target.kind && $0.id == target.id })
        else { return }
        filedTargetsThisOpening.append(target)
    }

    /// The view calls this on dismiss — the ONE settle point of a filing. It credits the held
    /// clock, scores the opening ONCE (whether the player tapped one collection or five), and
    /// advances; a cancelled opening means no point, NO advance, the card stays. IDEMPOTENT:
    /// it is reachable from both the sheet's completion callback and the binding's `onChange`,
    /// and a second call must not credit the clock twice or score twice.
    ///
    /// `assignedTo` is the LEGACY single-shot path, kept for callers (and tests) that score a
    /// target directly. The view always passes nil now and lets the opening's own
    /// `filedTargetsThisOpening` decide what was filed.
    ///
    /// CANCEL IS NOT A SKIP, deliberately: a player may cancel to hit a target button instead,
    /// and silently burning their card would be the worst possible surprise in a timed game.
    /// `skip()` remains the explicit pass and still records `action: "skipped"`.
    func endFiling(assignedTo target: AddTarget?) {
        guard let songId = filingSongId else { return }
        filingSongId = nil
        let noted = filedTargetsThisOpening
        filedTargetsThisOpening = []
        // What this opening actually FILED. The multi-select path re-checks LIVE membership: a
        // player who added and then UNCHECKED a collection (the picker's rows toggle) filed
        // nothing there, and unchecking them all is a Cancel — no point, and the card stays.
        let filed: [AddTarget] = target.map { [$0] } ?? noted.filter { stillContains(songId, $0) }
        // Credit the held time. The allowance SCALES with how many collections were actually
        // filed, which the flat cap did not: filing into five crates legitimately takes longer
        // than filing into one, and a flat 20 s made USING multi-collection filing score-
        // negative — the same single point, but every second past 20 was round clock the player
        // never got back. Scoring stays one-point-per-card, so the extra allowance buys no
        // score; it only stops the feature taxing the player for using it. Still bounded (see
        // `maxFilingCreditCeilingSeconds`), because uncapped credit is an untimed game.
        let allowance = min(Self.maxFilingCreditSeconds
                              + Self.filingCreditPerExtraTarget * Double(max(0, filed.count - 1)),
                            Self.maxFilingCreditCeilingSeconds)
        deadlineEpoch += min(max(0, now().timeIntervalSince1970 - filingStartedAt), allowance)
        // The card is verified BY ID: a stale sheet (the round ended, or the queue moved under
        // it) files nothing rather than scoring against the wrong song.
        if !filed.isEmpty, phase == .running, let song = current, song.id == songId {
            creditFiling(song: song, filedInto: filed)
        }
        // Re-marry audio to the card the round is now showing. The audio ran on behind the
        // sheet (no pause API), so this is the same one-line re-arm the watchdog uses.
        if phase == .running, current != nil, !sequencerTakenOver,
           !sequencer.isRunning || audioBaseIndex + sequencer.index != queueIndex {
            armAudio(fromQueueIndex: queueIndex)
        }
    }

    /// Is the song STILL in this target right now? The picker's rows are toggles, so an add
    /// the sheet reported can have been undone before it closed.
    private func stillContains(_ songId: String, _ t: AddTarget) -> Bool {
        switch t.kind {
        case .pocket:   return collections.pocket(t.id)?.songIds.contains(songId) ?? false
        case .playlist: return collections.playlist(t.id, contains: songId)
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
