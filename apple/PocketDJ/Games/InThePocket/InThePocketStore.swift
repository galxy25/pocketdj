import Foundation
import Observation

/// IN THE POCKET — the APP-SCOPED game store (a running round survives tab switches and leaving
/// the game screen, the SetlistPlayer / Gem Collector doctrine). It:
///   · builds a round OFF the main actor with the pure `InThePocketScorer` (context now + the
///     latest pocket results + this device's history + its past rounds);
///   · plays it through the ONE shared sequencer (`SetlistPlayer`) under a run tag
///     (`itp_<round id>`), so History reads "Game · In the Pocket" and the lock screen, CarPlay
///     and the provider chain are all the ordinary ones;
///   · tracks it with the pure `InThePocketRoundEvaluator` over the play-history log (the app's
///     existing skip / played-fraction machinery) on a 1 Hz ticker that runs whether or not the
///     game screen is showing;
///   · persists every round (`pocketdj-in-the-pocket.json`, DEVICE-LOCAL — not CloudSync'd: it
///     holds free-text feedback, and the cloud copy is the opt-in upload) and records finished
///     ones on the scoreboard;
///   · hands finished rounds to `ListeningPocketsService` for upload (`uploadWires`).
@MainActor
@Observable
final class InThePocketStore {

    enum BuildState: Equatable {
        case idle
        case building
        case failed(String)
    }

    /// Oldest → newest.
    private(set) var rounds: [InThePocketRound] = []
    /// The round the game screen shows (built, playing, or just finished).
    private(set) var currentRoundId: UUID?
    private(set) var buildState: BuildState = .idle
    /// Index of the song playing now in the active round.
    private(set) var currentSongIndex: Int?

    var current: InThePocketRound? { currentRoundId.flatMap { id in rounds.last { $0.id == id } } }
    var activeRound: InThePocketRound? { rounds.last { $0.isActive } }

    // MARK: - Dependencies (closures, so `init` stays small and tests need no app graph)

    @ObservationIgnored private let history: PlayHistoryStore
    @ObservationIgnored private let scoreboard: GameScoreboardStore
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored var now: () -> Date = { Date() }

    /// The catalog (songs + albums for genre categories). Empty by default.
    @ObservationIgnored var catalogSnapshot: () -> (songs: [String: IndexSong], albums: [String: IndexAlbum]) = { ([:], [:]) }
    /// What can make sound right now (Gem Collector's seam, reused verbatim).
    @ObservationIgnored var audioAvailability: () -> CollectorsPuzzleEngine.AudioAvailability = { .init() }
    /// This device's collections + add log (pockets × collections). Empty by default ⇒ the
    /// scorer behaves exactly as without collections. Flattened OFF the main actor in `makeInput`.
    @ObservationIgnored var collectionsInput: () -> ListeningPocketsCollections.Input = { .init() }
    /// The latest cloud results (`ListeningPocketsService.results`).
    @ObservationIgnored var results: () -> ListeningPocketsResults? = { nil }
    /// Current place / trip GUESS + its display label (nil off iOS / location off).
    @ObservationIgnored var contextGuess: () -> (tag: ListeningContextTag?, label: String?) = { (nil, nil) }
    /// Start the round's queue on the shared sequencer under `runTag`.
    @ObservationIgnored var play: ([SetlistPlayer.Item], String) -> Void = { _, _ in }
    /// Is the shared sequencer still running THIS run tag?
    @ObservationIgnored var ownsRun: (String) -> Bool = { _ in false }
    /// A round finished, or a finished round's feedback/rating changed — upload soon.
    @ObservationIgnored var onRoundsChanged: () -> Void = {}
    @ObservationIgnored var appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    @ObservationIgnored private var tickerTask: Task<Void, Never>?
    /// Test seam: unit tests drive `evaluate()` themselves instead of the 1 Hz ticker.
    @ObservationIgnored var tickerEnabled = true
    @ObservationIgnored private var ownershipLostAtMs: Double?

    static let runTagPrefix = "itp_"
    static func runTag(_ id: UUID) -> String { runTagPrefix + id.uuidString }
    static let maxRounds = 300

    struct Document: Codable {
        var schemaVersion = 1
        var rounds: [InThePocketRound] = []
        var currentRoundId: UUID?

        init(rounds: [InThePocketRound], currentRoundId: UUID?) {
            self.rounds = rounds; self.currentRoundId = currentRoundId
        }
        enum CodingKeys: String, CodingKey { case schemaVersion, rounds, currentRoundId }
        /// Per-element lenient (the PlayHistoryStore doctrine): one unreadable round written by a
        /// newer build must not take the rest with it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
            rounds = ((try? c.decode([Lenient].self, forKey: .rounds)) ?? []).compactMap(\.round)
            currentRoundId = (try? c.decodeIfPresent(UUID.self, forKey: .currentRoundId)) ?? nil
        }
        private struct Lenient: Decodable {
            let round: InThePocketRound?
            init(from decoder: Decoder) throws { round = try? InThePocketRound(from: decoder) }
        }
    }

    init(history: PlayHistoryStore, scoreboard: GameScoreboardStore,
         fileURL: URL = InThePocketStore.defaultURL()) {
        self.history = history
        self.scoreboard = scoreboard
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            rounds = doc.rounds
            currentRoundId = doc.currentRoundId
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-in-the-pocket.json")
    }

    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-in-the-pocket.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    private var nowMs: Double { now().timeIntervalSince1970 * 1000 }

    // MARK: - Build

    /// Build a new round for NOW (replaces an unstarted one; refused while a round is playing).
    func buildRound(seed: UInt64? = nil) async {
        guard buildState != .building, activeRound == nil else { return }
        buildState = .building
        let nowMs = self.nowMs
        let tz = TimeZone.current.secondsFromGMT(for: now()) / 60
        let guess = contextGuess()
        let context = InThePocketContext.make(atMs: nowMs, tzOffsetMin: tz, ctx: guess.tag)
        let label = context.ctx == nil ? nil : guess.label
        let snapshot = catalogSnapshot()
        let availability = audioAvailability()
        let events = history.events
        let results = results()
        let past = rounds.filter(\.isFinished)
        let collections = collectionsInput()
        let seed = seed ?? UInt64.random(in: 1...UInt64.max)

        let outcome = await Task.detached(priority: .userInitiated) {
            let input = Self.makeInput(context: context, contextLabel: label, results: results,
                                       songs: snapshot.songs, albums: snapshot.albums,
                                       availability: availability, events: events, pastRounds: past,
                                       nowMs: nowMs, seed: seed, collections: collections)
            return InThePocketScorer.build(input)
        }.value

        switch outcome {
        case .failure(.nothingPlayable):
            buildState = .failed("Nothing can play right now. Connect Apple Music, or download some songs, then try again.")
        case .failure(.notEnoughCandidates):
            buildState = .failed("Not enough fresh, playable songs fit this moment yet. Play some music and try again.")
        case .success(let out):
            let round = InThePocketRound(
                id: UUID(), createdAtMs: nowMs, startedAtMs: nil, endedAtMs: nil, updatedAtMs: nowMs,
                tzOffsetMin: tz, context: context, contextLabel: label, mode: out.mode,
                seed: String(seed), algoVersion: InThePocketScorer.algoVersion,
                targets: out.targets + (out.bpmBand.map {
                    [InThePocketTarget(dim: "bpm", value: "\(Int($0.lowerBound))-\(Int($0.upperBound))",
                                       label: "\(Int($0.lowerBound))–\(Int($0.upperBound)) BPM", weight: InThePocketScorer.bpmWeight)]
                } ?? []),
                songs: out.picks.map {
                    InThePocketSong(id: $0.song.id, title: $0.song.title, artist: $0.song.artist,
                                    lengthMs: $0.song.lengthMs, score: $0.score, why: $0.why)
                },
                outcome: nil, rating: nil, feedback: nil, appVersion: appVersion)
            chipsById[round.id] = out.chips
            // An unstarted round is simply replaced (it predicted nothing yet).
            if let cur = current, cur.startedAtMs == nil { rounds.removeAll { $0.id == cur.id } }
            rounds.append(round)
            trim()
            currentRoundId = round.id
            buildState = .idle
            persist()
        }
    }

    /// The round's "why" chips. Kept for the session; rebuilt from the round otherwise.
    @ObservationIgnored private var chipsById: [UUID: [String]] = [:]
    func chips(for round: InThePocketRound) -> [String] {
        if let c = chipsById[round.id] { return c }
        var out = [round.context.timePhrase]
        if let l = round.contextLabel { out.append(l) }
        if let b = round.targets.first(where: { $0.dim == "bpm" }) { out.append(b.label) }
        let genres = round.targets.filter { $0.dim == "genre" }.prefix(2).map(\.label)
        if !genres.isEmpty { out.append(genres.joined(separator: "/")) }
        return out
    }

    /// Off-main: catalog + history → the scorer's input. Only songs that are playable or in the
    /// history are converted (the catalog is ~96k rows; a round needs a small slice of it).
    nonisolated static func makeInput(context: InThePocketContext, contextLabel: String?,
                                      results: ListeningPocketsResults?,
                                      songs: [String: IndexSong], albums: [String: IndexAlbum],
                                      availability: CollectorsPuzzleEngine.AudioAvailability,
                                      events: [PlayHistoryStore.PlayEvent], pastRounds: [InThePocketRound],
                                      nowMs: Double, seed: UInt64,
                                      collections: ListeningPocketsCollections.Input = .init()) -> InThePocketScorer.Input {
        var playable = Set(availability.ripManifest.keys).union(availability.burnedIds)
        if availability.canStreamAppleMusic {
            for s in songs.values where s.appleMusicId != nil { playable.insert(s.id) }
        }
        playable = playable.filter { songs[$0] != nil }
        var wanted = playable
        for e in events { wanted.insert(SongVariant.baseId(e.songId)) }
        // Collections: the same flattening (and caps) the upload sends, plus each member's add
        // time. Members join the converted catalog so a collection's centroid can resolve.
        let flat = ListeningPocketsCollections.flattened(collections.source)
        let adds = CollectionFlattener.addTimes(collections: flat, activity: collections.activity,
                                                pockets: collections.source.pockets,
                                                albumTracks: collections.source.albumTracks)
        let infos = flat.compactMap { c -> InThePocketScorer.CollectionInfo? in
            guard !c.songIds.isEmpty else { return nil }
            return InThePocketScorer.CollectionInfo(id: c.id, name: c.name.isEmpty ? nil : c.name,
                                                    songIds: Set(c.songIds), addedAtMs: adds[c.id] ?? [:])
        }
        for c in infos { wanted.formUnion(c.songIds) }
        var genreByAlbum: [String: String?] = [:]
        var catalog: [String: InThePocketScorer.Song] = [:]
        catalog.reserveCapacity(wanted.count)
        for id in wanted {
            guard let s = songs[id] else { continue }
            var genre: String?
            if let aid = s.albumId {
                if let g = genreByAlbum[aid] { genre = g } else {
                    let cat = Genre.category(albums[aid]?.genre)
                    genre = cat == Genre.other ? nil : cat.lowercased()
                    genreByAlbum[aid] = genre
                }
            }
            catalog[id] = InThePocketScorer.Song(id: s.id, title: s.name, artist: s.artist, lengthMs: s.length,
                                                 genre: genre, bpm: s.bpm, camelot: s.camelot,
                                                 moods: (s.sentimentKeywords ?? []).map { $0.lowercased() })
        }
        let plays = events.map {
            InThePocketScorer.Play(songId: SongVariant.baseId($0.songId), atMs: $0.playedAt,
                                   tzOffsetMin: $0.tzOffsetMin ?? 0, outcome: $0.outcome.rawValue,
                                   ctx: $0.listeningContext)
        }
        return InThePocketScorer.Input(context: context, contextLabel: contextLabel, results: results,
                                       catalog: catalog, playableIds: playable, plays: plays,
                                       pastRounds: pastRounds, nowMs: nowMs, seed: seed,
                                       collections: infos)
    }

    // MARK: - Play + track

    /// ▶ — play the current (unstarted) round.
    func start() {
        guard let i = index(of: currentRoundId), rounds[i].startedAtMs == nil, activeRound == nil else { return }
        let t = nowMs
        rounds[i].startedAtMs = t
        rounds[i].updatedAtMs = t
        ownershipLostAtMs = nil
        persist()
        play(rounds[i].songs.map { SetlistPlayer.Item(id: $0.id, title: $0.title, artist: $0.artist, lengthMs: $0.lengthMs) },
             Self.runTag(rounds[i].id))
        startTicker()
    }

    /// App launch / foreground: keep tracking a round that was playing when the app went away.
    func resumeTrackingIfNeeded() {
        if activeRound != nil { startTicker() }
    }

    private func startTicker() {
        guard tickerEnabled, tickerTask == nil else { return }
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.activeRound != nil else { break }
                self.evaluate()
                try? await Task.sleep(for: .seconds(1))
            }
            self?.tickerTask = nil
        }
    }

    /// One evaluation of the active round — the ticker's body, and the test seam.
    func evaluate(forceEnd: Bool = false) {
        guard let i = rounds.lastIndex(where: { $0.isActive }), let started = rounds[i].startedAtMs else {
            currentSongIndex = nil
            return
        }
        let t = nowMs
        let tag = Self.runTag(rounds[i].id)
        if ownsRun(tag) { ownershipLostAtMs = nil } else if ownershipLostAtMs == nil { ownershipLostAtMs = t }
        let lost = forceEnd ? t - InThePocketRoundEvaluator.settleMs : ownershipLostAtMs
        let mine = history.installId
        var obs: [InThePocketRoundEvaluator.Observation] = []
        for e in history.events.reversed() {
            if e.playedAt < started - InThePocketRoundEvaluator.startToleranceMs { break }
            guard e.originInstallId == nil || e.originInstallId == mine else { continue }
            obs.append(.init(e))
        }
        let v = InThePocketRoundEvaluator.evaluate(songIds: rounds[i].songs.map(\.id), startedAtMs: started,
                                                   events: obs, ownershipLostAtMs: lost, nowMs: t)
        var r = rounds[i]
        for k in r.songs.indices {
            r.songs[k].state = v.states[k]
            r.songs[k].eventId = v.eventIds[k]
            r.songs[k].fraction = v.fractions[k]
        }
        currentSongIndex = v.currentIndex
        if let outcome = v.outcome {
            r.outcome = outcome
            r.endedAtMs = t
            r.updatedAtMs = t
            rounds[i] = r
            persist()
            let completed = r.songs.filter { $0.state == .completed }.count
            scoreboard.record(game: .inThePocket, score: completed,
                              settingsSummary: chips(for: r).joined(separator: " · "),
                              detail: ["outcome": outcome.token, "roundId": r.id.uuidString,
                                       "songs": String(r.songs.count)],
                              at: t)
            currentSongIndex = nil
            onRoundsChanged()
        } else if r != rounds[i] {
            rounds[i] = r
            persist()
        }
    }

    /// "End round" — stop tracking now; the verdict is whatever the log already says.
    func endActiveRound() {
        evaluate(forceEnd: true)
    }

    /// Clear the screen for a fresh round (the finished one stays in the log).
    func dismissCurrent() {
        guard current?.isActive != true else { return }
        if let cur = current, cur.startedAtMs == nil { rounds.removeAll { $0.id == cur.id } }
        currentRoundId = nil
        buildState = .idle
        persist()
    }

    // MARK: - Feedback

    /// Save the round's free-text feedback (capped) and optional 1…5 rating. Allowed during and
    /// after the round; a FINISHED round's change re-uploads (its `updatedAtMs` moves).
    func saveFeedback(roundId: UUID, text: String?, rating: Int?) {
        guard let i = index(of: roundId) else { return }
        let capped = InThePocketRound.capFeedback(text)
        let r = rating.flatMap { (1...5).contains($0) ? $0 : nil }
        guard capped != rounds[i].feedback || r != rounds[i].rating else { return }
        rounds[i].feedback = capped
        rounds[i].rating = r
        rounds[i].updatedAtMs = max(nowMs, rounds[i].updatedAtMs + 1)
        persist()
        if rounds[i].isFinished { onRoundsChanged() }
    }

    // MARK: - Upload + stats

    /// Every FINISHED round as an upload row (the service filters by its own ack fingerprints).
    func uploadWires(installId: String) -> [InThePocketRoundWire] {
        rounds.compactMap { $0.wire(installId: installId) }
    }

    /// Account deletion: drop every round and the file.
    func clearLocal() {
        tickerTask?.cancel(); tickerTask = nil
        rounds = []
        currentRoundId = nil
        currentSongIndex = nil
        buildState = .idle
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Persistence

    private func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return rounds.lastIndex { $0.id == id }
    }

    private func trim() {
        guard rounds.count > Self.maxRounds else { return }
        let overflow = rounds.count - Self.maxRounds
        var dropped = 0
        rounds.removeAll { r in
            guard dropped < overflow, !r.isActive, r.id != currentRoundId else { return false }
            dropped += 1
            return true
        }
    }

    private func persist() {
        let doc = Document(rounds: rounds, currentRoundId: currentRoundId)
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }
}
