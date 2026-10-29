import Foundation
import Observation

/// The app-scoped adaptive pocket run (§4, the `InThePocketStore` pattern): builds the plan off
/// the main actor, plays it through the ONE shared sequencer under `pwr_<runId>` (or, for a Mix
/// moment, through Mix Auto-DJ — W7), and on a 1 Hz ticker reads the run's own verdicts from the
/// play-history log (the existing SkipTracker pipeline — never a second one) to:
///   · learn per-feature multipliers and ban skipped artists for the rest of the run (§4.3);
///   · re-plan upcoming rows slot-wise without dead air (§4.4, `SetlistPlayer.replaceUpcoming`);
///   · keep exactly enough rows queued for 100 PLAYED-THROUGH songs (W2): a skip tops the queue
///     up from the bench, and the run stops at the 100th play-through.
/// Run state that must survive a relaunch mid-run lives in `pocketdj-pocket-run.json`
/// (device-local); what was LEARNED is derived from history (`PocketTuning.fold`), never stored.
@MainActor
@Observable
final class PocketRunStore {

    static let target = 100
    static let replanDebounce: Double = 1.5
    static let rescoreEvery = 5
    static let ownershipGraceMs: Double = 10_000

    /// One run's persisted state.
    struct RunState: Codable, Equatable {
        var runId: UUID
        var momentKey: String?
        var label: String
        var seed: String
        var profile: PocketProfile
        var bench: [PocketRunPlanner.BenchEntry]
        var banned: [String] = []
        var playedThrough = 0
        var skips = 0
        var startedAtMs: Double
        var endedAtMs: Double?
        var finished = false
        var viaMix = false
        /// History events already counted.
        var processed: [UUID] = []
        var completedSinceRescore = 0
        /// songId → (slot, rowCollectionId) for the Mix path's history tags.
        var mixSlots: [String: Int] = [:]
        var mixCollections: [String: String] = [:]
        var nextSlot = PocketRunStore.target + 1
        /// Phase 5b: the mode a sustained activity change re-targeted the run to (once per mode).
        var retargetedMode: PocketMode? = nil
        var tag: String { PocketWheelIds.runTag(runId) }
    }

    /// A finished run, kept for the card's "Past runs" strip.
    struct RunSummary: Codable, Equatable, Identifiable {
        var id: UUID
        var momentKey: String?
        var label: String
        var startedAtMs: Double
        var playedThrough: Int
        var skips: Int
        var finished: Bool
    }

    struct Document: Codable {
        var schemaVersion = 1
        var active: RunState?
        var past: [RunSummary] = []
    }

    enum BuildState: Equatable { case idle, building, failed(String) }

    private(set) var active: RunState?
    private(set) var past: [RunSummary] = []
    private(set) var buildState: BuildState = .idle
    /// Bumped on every visible change (centre progress ring, Up Next badges).
    private(set) var revision = 0
    /// Rows re-tuned by the last re-plan (Up Next "Re-tuned ✦" badge for a few seconds).
    private(set) var retunedUids: Set<UUID> = []

    var isRunning: Bool { active != nil && active?.finished == false }
    var progress: (done: Int, total: Int, key: PocketMomentKey?)? {
        guard let a = active, !a.finished else { return nil }
        return (a.playedThrough, Self.target, a.momentKey.flatMap(PocketMomentKey.init(token:)))
    }

    // MARK: Seams

    @ObservationIgnored private let history: PlayHistoryStore
    @ObservationIgnored private weak var player: SetlistPlayer?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var tickerEnabled = true
    /// The candidate universe for a profile (playable songs → planner candidates), built OFF-main.
    @ObservationIgnored var candidates: () async -> [String: PocketRunPlanner.Candidate] = { [:] }
    /// Lifetime 👎 song ids.
    @ObservationIgnored var thumbsDown: () -> Set<String> = { [] }
    /// The history event of the track sounding NOW (its verdict is still pending).
    @ObservationIgnored var currentEventId: () -> UUID? = { nil }
    /// W7: start the run's songs as a Mix Auto-DJ queue. Returns how many were loadable (0 ⇒ the
    /// caller falls back to the sequencer). nil ⇒ no Mix path on this host.
    @ObservationIgnored var playThroughMix: (([PocketRunPlanner.Row], String) -> Int)?
    /// W7: is Mix Auto-DJ still playing this run (by its label)?
    @ObservationIgnored var mixOwnsRun: (String) -> Bool = { _ in false }
    /// W7: append songs to the Auto-DJ queue's tail (top-up / replacements).
    @ObservationIgnored var mixAppend: (([PocketRunPlanner.Row], String) -> Void)?
    @ObservationIgnored var onRunEnded: ((RunSummary) -> Void)?

    @ObservationIgnored private var tickerTask: Task<Void, Never>?
    @ObservationIgnored private var topUpTask: Task<Void, Never>?
    /// After a top-up found nothing, don't rescore the pool again before this (epoch ms).
    @ObservationIgnored private var topUpBackoffUntilMs: Double = 0
    static let topUpBackoffMs: Double = 30_000
    @ObservationIgnored private var replanTask: Task<Void, Never>?
    @ObservationIgnored private var ownershipLostAtMs: Double?
    @ObservationIgnored private var cachedCandidates: [String: PocketRunPlanner.Candidate] = [:]
    @ObservationIgnored private var runTuning: PocketTuning.Multipliers = .neutral
    @ObservationIgnored private var priorEvidence = PocketTuning.Evidence()

    // MARK: Phase 5b seams — adapt to activity mid-run (opt-in)

    /// "Adapt runs to walking & running" (Settings ▸ Pocket Wheel; default off).
    @ObservationIgnored var adaptToActivity: () -> Bool = { false }
    /// Live CoreMotion updates while a run plays (`ListeningMotionStore.startLiveUpdates`).
    @ObservationIgnored var startActivityUpdates: ((@escaping @MainActor (MotionSegment) -> Void) -> Void)?
    @ObservationIgnored var stopActivityUpdates: () -> Void = {}
    /// The best pocket for NOW in a given mode (the wheel's best match with `mode_now` forced).
    @ObservationIgnored var profileForMode: (PocketMode) async -> PocketProfile? = { _ in nil }
    @ObservationIgnored private var activity = ActivityTracker()
    @ObservationIgnored private var retargetTask: Task<Void, Never>?

    /// The app's run store, for the play-history hooks built before it exists in `init`.
    static weak var shared: PocketRunStore?
    /// ⏸/▶ the sounding run (the centre button while a run plays).
    @ObservationIgnored var togglePause: () -> Void = {}

    /// Display names of live run tags ("Pocket · Tue 8 AM CarPlay") for History's context lookup.
    static var runNames: [String: String] = [:]

    init(history: PlayHistoryStore, player: SetlistPlayer?, fileURL: URL = PocketRunStore.defaultURL()) {
        self.history = history
        self.player = player
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let doc = try? JSONDecoder().decode(Document.self, from: data) {
            active = doc.active
            past = doc.past
            if let a = active { Self.runNames[a.tag] = a.label }
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-pocket-run.json")
    }

    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-pocket-run.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    private var nowMs: Double { now().timeIntervalSince1970 * 1000 }

    // MARK: Start

    /// Build and start a run for `profile`. A running run is replaced (its summary is kept).
    @discardableResult
    func start(profile: PocketProfile, seed: UInt64? = nil) async -> Bool {
        guard buildState != .building else { return false }
        buildState = .building
        if active != nil { endRun(finished: false) }
        let runId = UUID()
        let seed = seed ?? UInt64.random(in: 1...UInt64.max)
        let nowMs = self.nowMs
        let events = history.events
        let thumbs = thumbsDown()
        let pool = await candidates()
        cachedCandidates = pool
        let moment = profile.key
        let planOut = await Task.detached(priority: .userInitiated) { () -> (PocketRunPlanner.Plan, PocketTuning.Evidence) in
            let recent = Set(events.filter { nowMs - $0.playedAt < 12 * 3_600_000 }.map { SongVariant.baseId($0.songId) })
            let plays = events.map {
                InThePocketScorer.Play(songId: SongVariant.baseId($0.songId), atMs: $0.playedAt,
                                       tzOffsetMin: $0.tzOffsetMin ?? 0, outcome: $0.outcome.rawValue, ctx: nil)
            }
            let fam = InThePocketScorer.familiarity(plays)
            let prior = PocketTuning.fold(verdicts: PocketTuning.verdicts(from: events).map(\.verdict),
                                          for: moment, nowMs: nowMs, features: { pool[$0]?.features })
            let tuning = PocketTuning.multipliers(prior, allowBans: false)
            let plan = PocketRunPlanner.plan(.init(profile: profile, candidates: pool, excluded: recent.union(thumbs),
                                                   familiarity: fam, tuning: tuning, seed: seed))
            return (plan, prior)
        }.value
        let (plan, prior) = planOut
        guard !plan.rows.isEmpty else {
            buildState = .failed("Not enough playable songs fit this pocket yet. Download some, or connect Apple Music.")
            return false
        }
        priorEvidence = prior
        runTuning = PocketTuning.multipliers(prior, allowBans: false)
        let label = "Pocket · " + (moment.map { $0.shortLabel.replacingOccurrences(of: " · ", with: " ") } ?? profile.caption)
        var state = RunState(runId: runId, momentKey: moment?.token, label: label, seed: String(seed), profile: profile,
                             bench: plan.bench, startedAtMs: nowMs)
        Self.runNames[state.tag] = label
        // W7: a Mix moment plays through Mix Auto-DJ when enough of the run can load on the decks.
        if profile.mode == .mix, let mix = playThroughMix {
            let loaded = mix(plan.rows, label)
            if loaded >= 10 {
                state.viaMix = true
                for r in plan.rows {
                    state.mixSlots[r.songId] = r.slot
                    if let c = r.collectionId { state.mixCollections[r.songId] = c }
                }
            }
        }
        if !state.viaMix {
            player?.play(plan.rows.compactMap { item(for: $0, runId: runId) }, sourceSetlistId: state.tag)
        }
        active = state
        buildState = .idle
        ownershipLostAtMs = nil
        revision &+= 1
        persist()
        if !state.viaMix, adaptToActivity(), let start = startActivityUpdates {
            activity = ActivityTracker()
            start { [weak self] seg in self?.noteActivity(seg) }
        }
        DiagLog.shared.log("pocketrun", "start run=\(runId.uuidString.prefix(8)) moment=\(moment?.token ?? profile.tier.rawValue) rows=\(plan.rows.count) bench=\(plan.bench.count) mix=\(state.viaMix)")
        startTicker()
        return true
    }

    private func item(for row: PocketRunPlanner.Row, runId: UUID) -> SetlistPlayer.Item? {
        guard let c = cachedCandidates[row.songId] else { return nil }
        return SetlistPlayer.Item(id: c.id, title: c.title, artist: c.artist, lengthMs: c.lengthMs,
                                  plan: .init(runId: runId, slot: row.slot, collectionId: row.collectionId,
                                              score: row.score, pinned: false))
    }

    /// Is the shared sequencer still playing THIS run? Every queue edit (trim, top-up, re-plan,
    /// re-target) is gated on it: once the listener starts anything else (a CarPlay playlist, a
    /// Browse song), that queue is theirs and a run must never append to or edit it.
    func ownsSequencer(_ a: RunState) -> Bool {
        guard !a.viaMix, let player else { return false }
        return player.isRunning && player.sourceSetlistId == a.tag
    }

    /// The History tag for a play the sequencer is making now (nil when it isn't a run row).
    func tag(forPlan plan: SetlistPlayer.PlanTag?) -> PocketRunTag? {
        guard let plan, let a = active, a.runId == plan.runId else { return nil }
        return PocketRunTag(runId: a.runId, momentKey: a.momentKey ?? "", rowCollectionId: plan.collectionId, slot: plan.slot)
    }

    /// The History tag for a Mix deck play of `songId` during a W7 run.
    func mixTag(forSongId songId: String, label: String?) -> PocketRunTag? {
        guard let a = active, a.viaMix, label == a.label, let slot = a.mixSlots[songId] else { return nil }
        return PocketRunTag(runId: a.runId, momentKey: a.momentKey ?? "", rowCollectionId: a.mixCollections[songId], slot: slot)
    }

    // MARK: Observe

    func resumeTrackingIfNeeded() {
        guard let a = active, !a.finished else { return }
        if !a.viaMix, adaptToActivity(), let start = startActivityUpdates {
            activity = ActivityTracker()
            start { [weak self] seg in self?.noteActivity(seg) }
        }
        if cachedCandidates.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                self.cachedCandidates = await self.candidates()
                self.startTicker()
            }
        } else {
            startTicker()
        }
    }

    private func startTicker() {
        guard tickerEnabled, tickerTask == nil else { return }
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { break }
                self.evaluate()
                try? await Task.sleep(for: .seconds(1))
            }
            self?.tickerTask = nil
        }
    }

    /// One evaluation — the ticker's body and the test seam: count new verdicts, learn, keep the
    /// 100-play-through invariant, schedule a re-plan, end on ownership loss.
    func evaluate() {
        guard var a = active, !a.finished else { return }
        let t = nowMs
        let owns = a.viaMix ? mixOwnsRun(a.label) : (player.map { $0.isRunning && $0.sourceSetlistId == a.tag } ?? false)
        if owns { ownershipLostAtMs = nil } else if ownershipLostAtMs == nil { ownershipLostAtMs = t }

        // A restored-but-held run is not sounding: nothing to learn or edit until ▶.
        if !a.viaMix, player?.isHeldForResume == true { return }
        let current = currentEventId()
        let processed = Set(a.processed)
        var newSkip = false
        var changed = false
        let mine = history.installId
        // ONE bounded tail walk (back to the run's start) — never a full-history scan on main.
        var runVerdicts: [PocketTuning.Verdict] = []
        for e in history.events.reversed() {
            if e.playedAt < a.startedAtMs - 60_000 { break }
            guard let tag = e.pocketRun, tag.runId == a.runId, e.id != current,
                  e.originInstallId == nil || e.originInstallId == mine else { continue }
            runVerdicts.append(.init(songId: SongVariant.baseId(e.songId), skipped: e.wasSkipped == true,
                                     fraction: e.listenedFraction, atMs: e.playedAt, momentKey: tag.momentKey,
                                     rowCollectionId: tag.rowCollectionId))
            guard !processed.contains(e.id) else { continue }
            a.processed.append(e.id)
            changed = true
            if e.wasSkipped == true {
                a.skips += 1
                newSkip = true
            } else {
                a.playedThrough += 1
                a.completedSinceRescore += 1
            }
        }
        if changed {
            let verdicts = runVerdicts
            let features: (String) -> PocketTuning.Features? = { [cachedCandidates] in cachedCandidates[$0]?.features }
            var evidence = priorEvidence
            evidence.merge(PocketTuning.runEvidence(verdicts, features: features), scale: 1)
            // Bans come from THIS run's evidence only (W5); the prior only shifts multipliers.
            let runOnly = PocketTuning.multipliers(PocketTuning.runEvidence(verdicts, features: features), allowBans: true)
            var tuning = PocketTuning.multipliers(evidence, allowBans: false)
            tuning.bannedArtists = runOnly.bannedArtists
            runTuning = tuning
            a.banned = tuning.bannedArtists.sorted()
        }
        active = a
        if changed { revision &+= 1; persist() }

        let ownsQueue = ownsSequencer(a) || a.viaMix
        if a.playedThrough >= Self.target {
            if ownsQueue { trimToInvariant() }
            // The 100th play-through is in: the run is over once the queue has run out.
            if !owns || (player?.upcoming.contains { $0.plan?.runId == a.runId } ?? false) == false {
                endRun(finished: true)
                return
            }
        }
        if !owns, let lost = ownershipLostAtMs, t - lost >= Self.ownershipGraceMs {
            endRun(finished: a.playedThrough >= Self.target)
            return
        }
        // Lost the sequencer (inside the grace window): learn, but never touch its queue.
        guard ownsQueue else { return }
        if newSkip {
            scheduleReplan()
        } else if a.completedSinceRescore >= Self.rescoreEvery {
            active?.completedSinceRescore = 0
            scheduleReplan(delay: 0)
        }
        trimToInvariant()
    }

    /// W2: keep queued run rows == 100 − played-through − (1 if a run row is sounding with its
    /// verdict pending). Excess run rows leave the TAIL; a shortfall is topped up from the bench.
    ///
    /// The SOUNDING run row counts as done once it is ≥ 90 % played (its live fraction — a
    /// listen past half can no longer become a skip), so the queue empties right after the 100th
    /// play-through instead of starting a 101st. While it is still short of that, one SPARE row
    /// stays queued in case it gets skipped (the skip verdict lands only as the next row starts).
    func trimToInvariant() {
        guard let a = active, !a.finished, !a.viaMix, let player, ownsSequencer(a) else { return }
        let needed = Self.rowsNeeded(target: Self.target, playedThrough: a.playedThrough,
                                     currentIsRun: player.isRunning && player.index < player.queue.count
                                        && player.queue[player.index].plan?.runId == a.runId,
                                     currentFraction: currentEventId().flatMap { id in
                                         history.events.last { $0.id == id }?.listenedFraction })
        // Pinned (listener-moved) run rows still COUNT toward the 100; only unpinned ones leave.
        let upcomingRun = player.upcoming.filter { $0.plan?.runId == a.runId }
        let removable = upcomingRun.filter { $0.plan?.pinned != true }
        if upcomingRun.count > needed {
            let excess = removable.suffix(min(removable.count, upcomingRun.count - needed)).map(\.uid)
            if !excess.isEmpty { _ = player.replaceUpcoming([:], removing: Set(excess)) }
        } else if upcomingRun.count < needed, player.isRunning, !player.isHeldForResume {
            topUp(needed - upcomingRun.count)
        }
    }

    /// The pure W2 invariant (see `trimToInvariant`).
    nonisolated static func rowsNeeded(target: Int, playedThrough: Int, currentIsRun: Bool, currentFraction: Double?) -> Int {
        let nearlyDone = currentIsRun && (currentFraction ?? 0) >= 0.9
        let done = playedThrough + (nearlyDone ? 1 : 0)
        let pending = currentIsRun && !nearlyDone ? 1 : 0
        let base = target - done - pending
        if base <= 0 { return pending == 1 && done < target ? 1 : 0 }   // the spare
        return base
    }

    /// Score the pool OFF the main actor (it is the whole playable catalog), append on main if the
    /// run still owns the sequencer, and back off for 30 s when nothing qualifies.
    private func topUp(_ count: Int) {
        guard let a = active, let player, topUpTask == nil, nowMs >= topUpBackoffUntilMs else { return }
        let inRun = Set(player.queue.map(\.id))
        let tail = player.queue.suffix(3).map(\.id)
        let pool = cachedCandidates, tuning = runTuning, profile = a.profile, thumbs = thumbsDown()
        topUpTask = Task { [weak self] in
            let picks = await Task.detached(priority: .userInitiated) {
                PocketRunPlanner.topUp(count: count, profile: profile, candidates: pool, tuning: tuning,
                                       familiarity: [:], inRun: inRun, tail: tail, excluded: thumbs)
            }.value
            guard let self else { return }
            defer { self.topUpTask = nil }
            guard var cur = self.active, cur.runId == a.runId, !cur.finished, self.ownsSequencer(cur),
                  let player = self.player else { return }
            guard !picks.isEmpty else { self.topUpBackoffUntilMs = self.nowMs + Self.topUpBackoffMs; return }
            var items: [SetlistPlayer.Item] = []
            let fresh = picks.filter { p in !player.queue.contains { $0.id == p.songId } }
            for p in fresh {
                let row = PocketRunPlanner.Row(songId: p.songId, slot: cur.nextSlot, collectionId: pool[p.songId]
                    .map { PocketRunPlanner.bucket($0, profile: profile) } ?? nil, score: p.score)
                cur.nextSlot += 1
                if let it = self.item(for: row, runId: cur.runId) { items.append(it) }
            }
            cur.bench.removeAll { b in fresh.contains { $0.songId == b.songId } }
            self.active = cur
            player.appendRunRows(items)
            self.persist()
            DiagLog.shared.log("pocketrun", "topup run=\(cur.runId.uuidString.prefix(8)) n=\(items.count) playedThrough=\(cur.playedThrough) skips=\(cur.skips)")
        }
    }

    /// Test seam: wait for an in-flight top-up.
    func awaitTopUp() async { await topUpTask?.value }

    // MARK: Re-plan

    func scheduleReplan(delay: Double = PocketRunStore.replanDebounce) {
        replanTask?.cancel()
        replanTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.replanNow()
        }
    }

    /// Compute (off-main) and apply (main, protection re-checked at apply time) a re-plan.
    func replanNow() async {
        guard let a = active, !a.finished, !a.viaMix, let player, ownsSequencer(a) else { return }
        let started = Date()
        let rows = player.replaceableUpcomingRows(runId: a.runId)
        guard !rows.isEmpty else { return }
        let live = rows.map { PocketRunPlanner.LiveRow(uid: $0.uid, songId: $0.songId, slot: $0.slot,
                                                       collectionId: $0.collectionId, requiresInstant: $0.requiresInstant) }
        var neighbours: [UUID: (prev: String?, next: String?)] = [:]
        for r in rows { neighbours[r.uid] = (r.prevSongId, r.nextSongId) }
        let inRun = Set(player.queue.map(\.id))
        let pool = cachedCandidates, tuning = runTuning, profile = a.profile, thumbs = thumbsDown()
        let result = await Task.detached(priority: .userInitiated) {
            PocketRunPlanner.replan(profile: profile, candidates: pool, tuning: tuning, familiarity: [:], live: live,
                                    inRun: inRun, neighbours: neighbours, excluded: thumbs)
        }.value
        guard let cur = active, cur.runId == a.runId, ownsSequencer(cur) else { return }
        var items: [UUID: SetlistPlayer.Item] = [:]
        for r in result.replacements {
            if let it = item(for: .init(songId: r.songId, slot: r.slot, collectionId: r.collectionId, score: r.score), runId: a.runId) {
                items[r.uid] = it
            }
        }
        let applied = player.replaceUpcoming(items, removing: Set(result.removals))
        retunedUids = Set(items.values.map(\.uid))
        revision &+= 1
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        DiagLog.shared.log("pocketrun", "replan run=\(a.runId.uuidString.prefix(8)) skips=\(a.skips) replaced=\(result.replacements.count) removed=\(result.removals.count) applied=\(applied) banned=[\(result.banned.joined(separator: ","))] ms=\(ms)")
        trimToInvariant()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.retunedUids = []
        }
    }

    // MARK: Adapt to activity (Phase 5b)

    /// A live motion sample. A SUSTAINED change (≥ 3 min) into a body mode the run isn't for
    /// re-targets the run's remaining slots toward the best moment for that mode, through the
    /// same protected replace path as a re-plan. Once per mode per run.
    func noteActivity(_ seg: MotionSegment) {
        guard let a = active, !a.finished, !a.viaMix else { return }
        activity.note(seg)
        guard let mode = activity.sustainedMode(now: now()), mode != (a.retargetedMode ?? a.profile.mode),
              retargetTask == nil else { return }
        retargetTask = Task { [weak self] in
            defer { self?.retargetTask = nil }
            guard let self, let profile = await self.profileForMode(mode) else { return }
            await self.retarget(to: profile, mode: mode)
        }
    }

    /// Re-plan every replaceable upcoming row from `profile` (slot order kept).
    func retarget(to profile: PocketProfile, mode: PocketMode) async {
        guard var a = active, !a.finished, let player, ownsSequencer(a) else { return }
        let rows = player.replaceableUpcomingRows(runId: a.runId)
        guard !rows.isEmpty else { return }
        let inRun = Set(player.queue.prefix(player.index + 1).map(\.id))
        let pool = cachedCandidates, tuning = runTuning, thumbs = thumbsDown(), seed = UInt64(a.seed) ?? 1
        let plan = await Task.detached(priority: .userInitiated) {
            PocketRunPlanner.plan(.init(profile: profile, candidates: pool, excluded: inRun.union(thumbs), tuning: tuning,
                                        seed: seed &+ 1, slots: rows.count))
        }.value
        guard let cur = active, cur.runId == a.runId, ownsSequencer(cur) else { return }
        a = cur
        var items: [UUID: SetlistPlayer.Item] = [:]
        for (row, planned) in zip(rows.sorted { $0.slot < $1.slot }, plan.rows) {
            if let it = item(for: .init(songId: planned.songId, slot: row.slot, collectionId: planned.collectionId,
                                        score: planned.score), runId: a.runId) { items[row.uid] = it }
        }
        let applied = player.replaceUpcoming(items, removing: [])
        a.retargetedMode = mode
        a.profile = profile
        a.bench = plan.bench
        active = a
        retunedUids = Set(items.values.map(\.uid))
        revision &+= 1
        persist()
        DiagLog.shared.log("pocketrun", "retarget run=\(a.runId.uuidString.prefix(8)) mode=\(mode.rawValue) applied=\(applied)")
    }

    // MARK: End

    func stop() {
        guard active != nil else { return }
        if active?.viaMix == false, let tag = active?.tag, player?.sourceSetlistId == tag { player?.stop() }
        endRun(finished: false)
    }

    private func endRun(finished: Bool) {
        guard var a = active else { return }
        stopActivityUpdates()
        retargetTask?.cancel(); retargetTask = nil
        tickerTask?.cancel(); tickerTask = nil
        replanTask?.cancel(); replanTask = nil
        topUpTask?.cancel(); topUpTask = nil
        a.finished = true
        a.endedAtMs = nowMs
        let summary = RunSummary(id: a.runId, momentKey: a.momentKey, label: a.label, startedAtMs: a.startedAtMs,
                                 playedThrough: a.playedThrough, skips: a.skips, finished: finished)
        past.append(summary)
        if past.count > 50 { past.removeFirst(past.count - 50) }
        active = finished ? a : nil
        Self.runNames[a.tag] = nil
        revision &+= 1
        persist()
        DiagLog.shared.log("pocketrun", "end run=\(a.runId.uuidString.prefix(8)) finished=\(finished) playedThrough=\(a.playedThrough) skips=\(a.skips)")
        onRunEnded?(summary)
    }

    /// Dismiss the "Pocket finished" card.
    func dismissFinished() {
        guard active?.finished == true else { return }
        active = nil
        revision &+= 1
        persist()
    }

    /// The card's "Past runs" strip for a moment.
    func runHistory(for key: PocketMomentKey) -> [PocketRunHistoryRow] {
        let df = DateFormatter()
        df.dateFormat = "EEE d MMM"
        return past.filter { $0.momentKey == key.token }.reversed().prefix(5).map {
            PocketRunHistoryRow(id: $0.id, label: df.string(from: Date(timeIntervalSince1970: $0.startedAtMs / 1000)),
                                playedThrough: $0.playedThrough,
                                skipRate: $0.playedThrough + $0.skips > 0 ? Double($0.skips) / Double($0.playedThrough + $0.skips) : 0)
        }
    }

    func clearLocal() {
        tickerTask?.cancel(); tickerTask = nil
        replanTask?.cancel(); replanTask = nil
        active = nil
        past = []
        revision &+= 1
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        let doc = Document(active: active, past: past)
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// Phase 5b: "is the body doing something new, for long enough?" Pure.
struct ActivityTracker {
    static let sustainSeconds: TimeInterval = 180
    private(set) var activity: String?
    private(set) var since: Date?

    /// Fold in a live sample; the clock restarts whenever the activity changes. Low-confidence
    /// samples are ignored.
    mutating func note(_ seg: MotionSegment) {
        guard seg.confidence >= MotionSettle.minConfidence else { return }
        if seg.activity != activity { activity = seg.activity; since = seg.start }
    }

    /// The run mode a sustained activity implies (running / walking / trip), or nil.
    func sustainedMode(now: Date) -> PocketMode? {
        guard let a = activity, let t = since, now.timeIntervalSince(t) >= Self.sustainSeconds else { return nil }
        switch a {
        case MotionToken.running: return .running
        case MotionToken.walking: return .walking
        case MotionToken.automotive, MotionToken.cycling: return .trip
        default: return nil
        }
    }
}
