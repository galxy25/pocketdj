import Foundation
import Observation
import AVFoundation

/// Off-main, serialized, last-writer-wins JSON writer (MixSessionWriter's shape). Encoding + the
/// atomic file write run on a background executor; a monotonic `version` guard means a
/// late-arriving stale snapshot can never clobber a newer one, regardless of Task scheduling.
private actor StudioWriter {
    private var written = 0
    func write(_ doc: StudioDocument, version: Int, to url: URL) {
        guard version > written else { return }
        written = version
        guard let data = try? JSONEncoder().encode(doc) else { return }
        try? data.write(to: url, options: .atomic)
    }
    /// Advance the watermark for a write already performed synchronously (by `flush`), so a
    /// later async write carrying an older version can't regress it.
    func markWritten(_ version: Int) { written = max(written, version) }
}

/// The Studio document store — samples, loops, sequencer patterns, instrument takes, and cue
/// points (spec §2). Owned by `PocketDJApp` (env). Persists `pocketdj-studio.json` with the
/// MixSessionStore persistence shape (versioned off-main writer, debounced save + `saveNow` +
/// synchronous `flush()`, `launchURL()` fixture seam) **plus** BurnStore's `reconcileOnLaunch`
/// semantics: every artifact resolves against the root it was actually WRITTEN to
/// (`wasUserFolder`); a record is dropped only when its file is PROVABLY gone from a REACHABLE
/// root; an unreachable user root (unplugged drive / offline provider) means SKIP — never prune.
/// Dangling cross-references (a loop's deleted parent sample, a pattern row's deleted target)
/// are FLAGGED via the `sampleExists`/`targetExists` helpers, never deleted — loops are
/// self-contained after render and missing pattern rows are skipped by playback/bounce.
///
/// This store persists; it never renders or plays. Engines (StudioEngine/StudioRender/
/// StudioMicRecorder) write files and hand records here; views push `settings` in (like
/// `MixRecorder`) so no app-init wiring is needed for the bookmark lookups.
@MainActor
@Observable
final class StudioStore {

    // The document lists, observed (the sub-tab lists render straight off these).
    private(set) var samples: [StudioSample] = []
    private(set) var loops: [StudioLoop] = []
    private(set) var patterns: [StudioPattern] = []
    private(set) var takes: [StudioTake] = []
    private(set) var cues: [StudioCue] = []
    private(set) var slices: [StudioSlice] = []

    /// Source of the per-family folder bookmarks. Pushed in from the view layer / app (like
    /// `MixRecorder.settings`) so this never has to be wired at app-init time. Weak ⇒ no retain
    /// of the app graph.
    @ObservationIgnored weak var settings: SettingsStore?

    /// The mic/instrument recorder's IN-FLIGHT capture file name, injected as a closure (nil
    /// when idle). `deleteAll(family:)` skips this open file — sweeping it mid-write corrupts
    /// the take and crashes the writer (the MixRecorder.activeTake doctrine).
    @ObservationIgnored var activeTakeFileName: (() -> String?)?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let writer = StudioWriter()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveVersion = 0

    // MARK: Init / persistence location

    init(fileURL: URL = StudioStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(StudioDocument.self, from: data) {
            samples = doc.samples
            loops = doc.loops
            patterns = doc.patterns
            takes = doc.takes
            cues = doc.cues
            slices = doc.slices
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-studio.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (deterministic, never touches real
    /// studio content) — the standard `PDJ_USE_FIXTURE` store seam.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-studio.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    private var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    /// The user-picked folder bookmark for a family (nil ⇒ app-managed). Takes/instruments are
    /// ALWAYS app-managed (spec §3), so they short-circuit to nil — which also keeps
    /// `StudioFolders.resolveRoot`'s "no bookmark for app-managed families" assert honest.
    func bookmark(for family: StudioFamily) -> Data? {
        switch family {
        case .samples: return settings?.samplesFolderBookmark
        case .loops: return settings?.loopsFolderBookmark
        case .sequences: return settings?.sequencesFolderBookmark
        case .takes, .instruments: return nil
        }
    }

    // MARK: - Samples

    func sample(_ id: String) -> StudioSample? { samples.first { $0.id == id } }

    /// File a sample record (the audio file already exists on disk — capture/carve writes it
    /// first, then records it here). Upserts by id so a crash-retry can never duplicate a row.
    @discardableResult
    func addSample(_ sample: StudioSample) -> StudioSample {
        if let i = samples.firstIndex(where: { $0.id == sample.id }) {
            samples[i] = sample
        } else {
            samples.append(sample)
        }
        saveNow()
        return sample
    }

    func renameSample(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = samples.firstIndex(where: { $0.id == id }) else { return }
        samples[i].name = n
        saveNow()
    }

    /// Persist a sample's beat grid (the tap-tempo / manual-BPM affordance, or a caller-computed
    /// inherited grid). Grid changes do NOT bump `renderRevision` — the render bakes EDITS, not
    /// the grid (the grid drives slicing math only).
    func setSampleGrid(_ id: String, _ grid: StudioGrid?) {
        guard let i = samples.firstIndex(where: { $0.id == id }) else { return }
        samples[i].grid = grid
        saveNow()
    }

    /// Update a sample's non-destructive edit. Clamped to legal ranges; `renderRevision` is
    /// bumped exactly when the value actually changed (the render-cache freshness stamp).
    /// Debounced save — edits stream continuously from sliders.
    func updateSampleEdit(_ id: String, _ edit: StudioSampleEdit) {
        guard let i = samples.firstIndex(where: { $0.id == id }) else { return }
        let clamped = edit.clamped()
        guard samples[i].edit != clamped else { return }
        samples[i].edit = clamped
        samples[i].renderRevision += 1
        scheduleSave()
    }

    /// StudioRender files a finished render cache here (edits baked at `revision`). The cache is
    /// fresh only while `revision == renderRevision` — an edit landing mid-render simply leaves
    /// the new cache stale and playback keeps using the raw file.
    func setRenderedSample(_ id: String, fileName: String, wasUserFolder: Bool, revision: Int) {
        guard let i = samples.firstIndex(where: { $0.id == id }) else { return }
        samples[i].renderedFileName = fileName
        samples[i].renderedRevision = revision
        samples[i].renderedWasUserFolder = wasUserFolder
        saveNow()
    }

    /// What a sample deletion would leave behind: the loops sliced from it (they keep playing —
    /// self-contained after render — but can't be re-sliced) and the pattern rows targeting it
    /// (they go silent as "missing" rows). The delete confirmation reads this (spec §2). Works
    /// for loop ids too (`loopCount` is then 0).
    func referrers(for targetId: String) -> (loopCount: Int, patternRowCount: Int) {
        let loopCount = loops.filter { $0.sampleId == targetId }.count
        let rowCount = patterns.reduce(0) { $0 + $1.rows.filter { $0.targetId == targetId }.count }
        return (loopCount, rowCount)
    }

    /// Delete a sample: its raw file, its render cache (best-effort — derived + re-renderable),
    /// and its record. Referencing loops and pattern rows are NEVER touched (spec §2). Returns
    /// false — record kept, nothing deleted — when the raw file's user root is unreachable
    /// right now (dropping the record without deleting the file would orphan it forever).
    @discardableResult
    func deleteSample(_ id: String) -> Bool {
        guard let i = samples.firstIndex(where: { $0.id == id }) else { return false }
        let s = samples[i]
        let bm = bookmark(for: .samples)
        if let got = StudioFolders.fileURL(family: .samples, fileName: s.fileName,
                                           wasUserFolder: s.wasUserFolder, bookmark: bm) {
            try? FileManager.default.removeItem(at: got.url)
            got.release?()
        } else if s.wasUserFolder && !userRootReachable(.samples) {
            return false   // can't even check the root — keep the record (no data destruction)
        }
        // Render cache: best-effort. An unreachable cache root never blocks the delete — a stray
        // stale cache is derived data, cleaned up by the family sweep whenever the root returns.
        if let rf = s.renderedFileName,
           let got = StudioFolders.fileURL(family: .samples, fileName: rf,
                                           wasUserFolder: s.renderedWasUserFolder ?? false, bookmark: bm) {
            try? FileManager.default.removeItem(at: got.url)
            got.release?()
        }
        slices.removeAll { $0.sampleId == id }   // pads are markers on this sample — no orphans
        samples.remove(at: i)
        saveNow()
        return true
    }

    /// Does a sample still exist? Loops show the "source removed" note (and disable re-slicing)
    /// off this — the dangling `sampleId` itself is kept forever (flag, never delete).
    func sampleExists(_ id: String) -> Bool { sample(id) != nil }

    // MARK: - Loops

    func loop(_ id: String) -> StudioLoop? { loops.first { $0.id == id } }

    /// File a rendered loop (the CAF is already on disk). Upserts by id.
    @discardableResult
    func addLoop(_ loop: StudioLoop) -> StudioLoop {
        if let i = loops.firstIndex(where: { $0.id == loop.id }) {
            loops[i] = loop
        } else {
            loops.append(loop)
        }
        saveNow()
        return loop
    }

    func renameLoop(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = loops.firstIndex(where: { $0.id == id }) else { return }
        loops[i].name = n
        saveNow()
    }

    /// Delete a loop (file + record). Pattern rows targeting it stay as "missing" rows. Same
    /// unreachable-root rule as `deleteSample`.
    @discardableResult
    func deleteLoop(_ id: String) -> Bool {
        guard let i = loops.firstIndex(where: { $0.id == id }) else { return false }
        let l = loops[i]
        if let got = StudioFolders.fileURL(family: .loops, fileName: l.fileName,
                                           wasUserFolder: l.wasUserFolder, bookmark: bookmark(for: .loops)) {
            try? FileManager.default.removeItem(at: got.url)
            got.release?()
        } else if l.wasUserFolder && !userRootReachable(.loops) {
            return false
        }
        loops.remove(at: i)
        saveNow()
        return true
    }

    /// Does a pattern row's target (sample or loop) still exist? The sequencer mutes + skips
    /// rows where this is false (never a throw — spec §2).
    func targetExists(_ id: String) -> Bool { sample(id) != nil || loop(id) != nil }

    // MARK: - Patterns (sequencer)

    func pattern(_ id: String) -> StudioPattern? { patterns.first { $0.id == id } }

    /// Create/replace a pattern. Upserts by id.
    @discardableResult
    func addPattern(_ pattern: StudioPattern) -> StudioPattern {
        if let i = patterns.firstIndex(where: { $0.id == pattern.id }) {
            patterns[i] = pattern
        } else {
            patterns.append(pattern)
        }
        saveNow()
        return pattern
    }

    /// Rename does NOT re-mark the bounce dirty — the audio is unchanged.
    func renamePattern(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = patterns.firstIndex(where: { $0.id == id }) else { return }
        patterns[i].name = n
        saveNow()
    }

    /// The one mutation door for a pattern's MUSICAL content — every edit through here re-marks
    /// `bounceDirty` (spec §2: "re-marked dirty on any edit") so a stale bounce can never play
    /// or export as the pattern. The stale file stays on disk (rebounce overwrites it).
    func mutatePattern(_ id: String, _ mutate: (inout StudioPattern) -> Void) {
        guard let i = patterns.firstIndex(where: { $0.id == id }) else { return }
        mutate(&patterns[i])
        patterns[i].bounceDirty = true
        saveNow()
    }

    func setPatternStep(_ id: String, row: Int, col: Int, on: Bool) {
        guard (0..<StudioPattern.stepCount).contains(col) else { return }
        mutatePattern(id) { p in
            guard p.rows.indices.contains(row) else { return }
            p.rows[row].steps[col] = on
        }
    }

    func setPatternBpm(_ id: String, _ bpm: Double) {
        guard bpm > 0 else { return }
        mutatePattern(id) { $0.bpm = bpm }
    }

    func addPatternRow(_ id: String, targetId: String) {
        mutatePattern(id) { $0.rows.append(StudioPatternRow(targetId: targetId)) }
    }

    func removePatternRow(_ id: String, row: Int) {
        mutatePattern(id) { p in
            guard p.rows.indices.contains(row) else { return }
            p.rows.remove(at: row)
        }
    }

    func setPatternRowGain(_ id: String, row: Int, gainDb: Double) {
        guard let i = patterns.firstIndex(where: { $0.id == id }),
              patterns[i].rows.indices.contains(row) else { return }
        patterns[i].rows[row].gainDb = gainDb
        patterns[i].bounceDirty = true
        scheduleSave()   // slider-driven → debounced, unlike the discrete edits above
    }

    /// StudioRender files a finished bounce here: records where it landed and clears the dirty
    /// flag. An edit that raced the bounce wins — `mutatePattern` runs after this and re-dirties.
    func setPatternBounced(_ id: String, fileName: String, wasUserFolder: Bool) {
        guard let i = patterns.firstIndex(where: { $0.id == id }) else { return }
        patterns[i].fileName = fileName
        patterns[i].wasUserFolder = wasUserFolder
        patterns[i].bounceDirty = false
        saveNow()
    }

    /// Delete a pattern (bounce file + record). Same unreachable-root rule: a bounce stranded in
    /// an unreachable user folder keeps its record so the file is never orphaned.
    @discardableResult
    func deletePattern(_ id: String) -> Bool {
        guard let i = patterns.firstIndex(where: { $0.id == id }) else { return false }
        let p = patterns[i]
        if let f = p.fileName {
            if let got = StudioFolders.fileURL(family: .sequences, fileName: f,
                                               wasUserFolder: p.wasUserFolder,
                                               bookmark: bookmark(for: .sequences)) {
                try? FileManager.default.removeItem(at: got.url)
                got.release?()
            } else if p.wasUserFolder && !userRootReachable(.sequences) {
                return false
            }
        }
        patterns.remove(at: i)
        saveNow()
        return true
    }

    // MARK: - Takes

    func take(_ id: String) -> StudioTake? { takes.first { $0.id == id } }

    /// File a finished take (audio already under the app-managed takes root). Upserts by id.
    @discardableResult
    func addTake(_ take: StudioTake) -> StudioTake {
        if let i = takes.firstIndex(where: { $0.id == take.id }) {
            takes[i] = take
        } else {
            takes.append(take)
        }
        saveNow()
        return take
    }

    func renameTake(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = takes.firstIndex(where: { $0.id == id }) else { return }
        takes[i].name = n
        saveNow()
    }

    /// Persist an EDITED note stream for a take (score editing, spec §7). Sets `editedEvents` so the
    /// score/replay/MIDI read it instead of the raw performance, and extends `durationMs` if a
    /// placed note runs past the old end (the take's audio is unchanged — replay plays events).
    func setTakeEvents(_ id: String, events: [StudioNoteEvent]) {
        guard let i = takes.firstIndex(where: { $0.id == id }) else { return }
        takes[i].editedEvents = events
        if let maxOff = events.map(\.offMs).max(), maxOff > takes[i].durationMs {
            takes[i].durationMs = maxOff
        }
        saveNow()
    }

    /// Drop a take's edits — the score reverts to deriving from the raw performance.
    func revertTakeEdits(_ id: String) {
        guard let i = takes.firstIndex(where: { $0.id == id }), takes[i].editedEvents != nil else { return }
        takes[i].editedEvents = nil
        saveNow()
    }

    /// Delete a take (file + record). Takes are always app-managed — the root is always
    /// reachable, so there is no keep-record branch. Samples created via "Use as sample" are
    /// untouched (they COPIED the audio; their `.take` source is provenance only).
    @discardableResult
    func deleteTake(_ id: String) -> Bool {
        guard let i = takes.firstIndex(where: { $0.id == id }) else { return false }
        if let got = StudioFolders.fileURL(family: .takes, fileName: takes[i].fileName,
                                           wasUserFolder: false, bookmark: nil) {
            try? FileManager.default.removeItem(at: got.url)
            got.release?()
        }
        takes.remove(at: i)
        saveNow()
        return true
    }

    // MARK: - Cues (max 8 slots per song, store-enforced)

    /// A song's cues, slot-ordered (the 8-button row maps by slot, not array position).
    func cues(forSong songId: String) -> [StudioCue] {
        cues.filter { $0.songId == songId }.sorted { $0.slot < $1.slot }
    }

    func cue(songId: String, slot: Int) -> StudioCue? {
        cues.first { $0.songId == songId && $0.slot == slot }
    }

    /// Set/replace the cue in a slot. The 8-per-song cap is enforced HERE by the slot domain
    /// itself (0–7): an out-of-range slot is rejected, so no code path can ever file a ninth
    /// cue. Replacing keeps the existing cue's id + name (a re-set moves the point; `name:`
    /// non-nil overrides). Returns the stored cue, nil when rejected.
    @discardableResult
    func setCue(songId: String, slot: Int, positionMs: Int, name: String? = nil) -> StudioCue? {
        guard !songId.isEmpty, (0..<StudioCue.maxSlots).contains(slot) else { return nil }
        let pos = max(0, positionMs)
        if let i = cues.firstIndex(where: { $0.songId == songId && $0.slot == slot }) {
            cues[i].positionMs = pos
            if let name { cues[i].name = normalizedCueName(name) }
            saveNow()
            return cues[i]
        }
        let cue = StudioCue(id: StudioFactory.newCueId(), songId: songId, slot: slot,
                            positionMs: pos, name: name.flatMap(normalizedCueName))
        cues.append(cue)
        saveNow()
        return cue
    }

    func removeCue(songId: String, slot: Int) {
        let before = cues.count
        cues.removeAll { $0.songId == songId && $0.slot == slot }
        if cues.count != before { saveNow() }
    }

    /// Rename a cue (nil/blank clears back to the slot's default label).
    func renameCue(songId: String, slot: Int, name: String?) {
        guard let i = cues.firstIndex(where: { $0.songId == songId && $0.slot == slot }) else { return }
        cues[i].name = name.flatMap(normalizedCueName)
        saveNow()
    }

    /// Nudge a cue's position by ±deltaMs (clamped to ≥ 0). Debounced save — nudge buttons are
    /// tapped repeatedly.
    func nudgeCue(songId: String, slot: Int, deltaMs: Int) {
        guard let i = cues.firstIndex(where: { $0.songId == songId && $0.slot == slot }) else { return }
        cues[i].positionMs = max(0, cues[i].positionMs + deltaMs)
        scheduleSave()
    }

    // MARK: - Slices (max 8 pads per sample, store-enforced; the 8-cap mirrors cues)

    /// A sample's slices, slot-ordered (the 8-pad grid maps by slot, not array position).
    func slices(forSample sampleId: String) -> [StudioSlice] {
        slices.filter { $0.sampleId == sampleId }.sorted { $0.slot < $1.slot }
    }

    func slice(sampleId: String, slot: Int) -> StudioSlice? {
        slices.first { $0.sampleId == sampleId && $0.slot == slot }
    }

    /// The [start, end) window a slice PLAYS: from its own start to the next slice's start (by
    /// time, across all pads) or the sample's effective end. nil if the slice/sample is gone or the
    /// window is empty (a start at/after the end).
    func sliceWindow(sampleId: String, slot: Int) -> (startMs: Int, endMs: Int)? {
        guard let s = slice(sampleId: sampleId, slot: slot), let sample = sample(sampleId) else { return nil }
        let nextStart = slices.filter { $0.sampleId == sampleId && $0.startMs > s.startMs }
            .map(\.startMs).min()
        // Raw duration: slices/playSlice operate on the raw sample file (0:00 = raw start), so the
        // last pad ends at the raw end — not the (trim-shortened) effective duration.
        let end = nextStart ?? sample.durationMs
        guard end > s.startMs else { return nil }
        return (s.startMs, end)
    }

    /// Set/replace one pad's start. The 8-per-sample cap is the slot domain itself (0–7), so no
    /// path can file a ninth. Replacing keeps the id + name (a re-set just moves the point).
    @discardableResult
    func setSlice(sampleId: String, slot: Int, startMs: Int, name: String? = nil) -> StudioSlice? {
        guard !sampleId.isEmpty, (0..<StudioSlice.maxSlots).contains(slot) else { return nil }
        let start = max(0, startMs)
        if let i = slices.firstIndex(where: { $0.sampleId == sampleId && $0.slot == slot }) {
            slices[i].startMs = start
            if let name { slices[i].name = normalizedCueName(name) }
            saveNow()
            return slices[i]
        }
        let slice = StudioSlice(id: StudioFactory.newSliceId(), sampleId: sampleId, slot: slot,
                                startMs: start, name: name.flatMap(normalizedCueName))
        slices.append(slice)
        saveNow()
        return slice
    }

    /// Replace ALL of a sample's slices with a set of start points (auto-slice): de-duped, sorted,
    /// capped at `maxSlots`, slot = time order. Clears the sample's existing pads first.
    func setSlices(sampleId: String, startsMs: [Int]) {
        guard !sampleId.isEmpty else { return }
        slices.removeAll { $0.sampleId == sampleId }
        let starts = Array(Set(startsMs.map { max(0, $0) })).sorted().prefix(StudioSlice.maxSlots)
        for (slot, start) in starts.enumerated() {
            slices.append(StudioSlice(id: StudioFactory.newSliceId(), sampleId: sampleId,
                                      slot: slot, startMs: start))
        }
        saveNow()
    }

    func removeSlice(sampleId: String, slot: Int) {
        let before = slices.count
        slices.removeAll { $0.sampleId == sampleId && $0.slot == slot }
        if slices.count != before { saveNow() }
    }

    func clearSlices(sampleId: String) {
        let before = slices.count
        slices.removeAll { $0.sampleId == sampleId }
        if slices.count != before { saveNow() }
    }

    func renameSlice(sampleId: String, slot: Int, name: String?) {
        guard let i = slices.firstIndex(where: { $0.sampleId == sampleId && $0.slot == slot }) else { return }
        slices[i].name = name.flatMap(normalizedCueName)
        saveNow()
    }

    /// Nudge a pad's start by ±deltaMs (clamped ≥ 0). Debounced — nudge buttons repeat.
    func nudgeSlice(sampleId: String, slot: Int, deltaMs: Int) {
        guard let i = slices.firstIndex(where: { $0.sampleId == sampleId && $0.slot == slot }) else { return }
        slices[i].startMs = max(0, slices[i].startMs + deltaMs)
        scheduleSave()
    }

    /// Blank cue names collapse to nil so the UI's "unnamed ⇒ slot label" rule has one truth.
    private func normalizedCueName(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }

    // MARK: - Playback resolution (collections / audition seam)

    /// Resolve a studio id (`smp_`/`lp_`/`ptn_`) to a playable LOCAL file — the
    /// `BurnStore.localURLForPlayback` contract: the security scope (user-folder files) is KEPT
    /// OPEN and the returned `release` closure is called by the player on stop / next load.
    /// `title` + `lengthMs` feed SetlistPlayer items and Now Playing without a second lookup.
    ///   • smp_ → the render cache when present + FRESH (`renderedRevision == renderRevision`),
    ///     else the raw sample file (edits audible only via the live chain then — never a stale bake);
    ///   • lp_ → the rendered loop CAF;
    ///   • ptn_ → the bounce, ONLY when `!bounceDirty` (a dirty pattern has no truthful file ⇒ nil);
    ///   • anything else (takes, song ids) → nil — not collection-playable through this store.
    func localURLForPlayback(id: String)
        -> (url: URL, release: (() -> Void)?, title: String, lengthMs: Int)? {
        if id.hasPrefix("smp_") {
            guard let s = sample(id) else { return nil }
            let bm = bookmark(for: .samples)
            if s.isRenderFresh, let rf = s.renderedFileName,
               let got = StudioFolders.fileURL(family: .samples, fileName: rf,
                                               wasUserFolder: s.renderedWasUserFolder ?? false,
                                               bookmark: bm) {
                return (got.url, got.release, s.name, s.effectiveDurationMs)
            }
            guard let got = StudioFolders.fileURL(family: .samples, fileName: s.fileName,
                                                  wasUserFolder: s.wasUserFolder, bookmark: bm)
            else { return nil }
            return (got.url, got.release, s.name, s.effectiveDurationMs)
        }
        if id.hasPrefix("lp_") {
            guard let l = loop(id),
                  let got = StudioFolders.fileURL(family: .loops, fileName: l.fileName,
                                                  wasUserFolder: l.wasUserFolder,
                                                  bookmark: bookmark(for: .loops))
            else { return nil }
            return (got.url, got.release, l.name, l.lengthMs)
        }
        if id.hasPrefix("ptn_") {
            guard let p = pattern(id), !p.bounceDirty, let f = p.fileName,
                  let got = StudioFolders.fileURL(family: .sequences, fileName: f,
                                                  wasUserFolder: p.wasUserFolder,
                                                  bookmark: bookmark(for: .sequences))
            else { return nil }
            return (got.url, got.release, p.name, StudioPattern.barMs(bpm: p.bpm))
        }
        return nil
    }

    /// Metadata for a studio id WITHOUT touching disk — collection stats/realize synthetic
    /// entries (title, real lengthMs, bpm when known) and the row kind badge read this.
    func displayInfo(forStudioId id: String)
        -> (title: String, lengthMs: Int, bpm: Double?, kindLabel: String)? {
        if id.hasPrefix("smp_"), let s = sample(id) {
            return (s.name, s.effectiveDurationMs, s.grid?.bpm, "Sample")
        }
        if id.hasPrefix("lp_"), let l = loop(id) {
            return (l.name, l.lengthMs, l.bpm, "Loop")
        }
        if id.hasPrefix("ptn_"), let p = pattern(id) {
            return (p.name, StudioPattern.barMs(bpm: p.bpm), p.bpm, "Sequence")
        }
        return nil
    }

    // MARK: - Reconcile (launch)

    /// Prune records whose file vanished — iOS purges Application Support under storage
    /// pressure without touching the JSON document (BurnStore.reconcileOnLaunch semantics):
    ///   • each artifact resolves against the root it was WRITTEN to (`wasUserFolder`);
    ///   • an UNREACHABLE user root ⇒ SKIP, never prune (nothing is provably gone);
    ///   • a provably-gone file in a reachable root ⇒ drop the record — except derived
    ///     artifacts: a sample's lost render cache just clears the cache fields, a pattern's
    ///     lost bounce clears `fileName` + re-marks dirty (the pattern's DATA is its steps);
    ///   • dangling cross-refs (loop→sample, row→target, sample→take) are left alone — they are
    ///     flagged at read time (`sampleExists`/`targetExists`), never deleted.
    func reconcileOnLaunch() {
        var changed = false
        var reachableByFamily: [StudioFamily: Bool] = [:]
        func userReachable(_ f: StudioFamily) -> Bool {
            if let r = reachableByFamily[f] { return r }
            let r = userRootReachable(f)
            reachableByFamily[f] = r
            return r
        }
        /// True only when the file is PROVABLY gone: its root resolves and the file isn't there.
        func provablyGone(_ f: StudioFamily, _ fileName: String, _ wasUser: Bool) -> Bool {
            if wasUser && !userReachable(f) { return false }   // can't check → never prune
            guard let got = StudioFolders.fileURL(family: f, fileName: fileName,
                                                  wasUserFolder: wasUser, bookmark: bookmark(for: f))
            else { return true }
            got.release?()
            return false
        }

        samples.removeAll { s in
            let gone = provablyGone(.samples, s.fileName, s.wasUserFolder)
            if gone { changed = true }
            return gone
        }
        for i in samples.indices {
            guard let rf = samples[i].renderedFileName,
                  provablyGone(.samples, rf, samples[i].renderedWasUserFolder ?? false) else { continue }
            samples[i].renderedFileName = nil
            samples[i].renderedRevision = nil
            samples[i].renderedWasUserFolder = nil
            changed = true
        }
        loops.removeAll { l in
            let gone = provablyGone(.loops, l.fileName, l.wasUserFolder)
            if gone { changed = true }
            return gone
        }
        for i in patterns.indices {
            guard let f = patterns[i].fileName,
                  provablyGone(.sequences, f, patterns[i].wasUserFolder) else { continue }
            patterns[i].fileName = nil
            patterns[i].bounceDirty = true
            changed = true
        }
        takes.removeAll { t in
            let gone = provablyGone(.takes, t.fileName, false)
            if gone { changed = true }
            return gone
        }
        if changed { saveNow() }
    }

    /// Is a family's user root resolvable RIGHT NOW? false when no bookmark is set or it fails
    /// to resolve — the "keep the record, nothing was provably deleted" gate.
    private func userRootReachable(_ family: StudioFamily) -> Bool {
        guard family.supportsUserFolder,
              let bm = bookmark(for: family),
              let root = StudioFolders.resolveRoot(family: family, bookmark: bm, requireWritable: false),
              root.isUserFolder else { return false }
        if root.scoped { root.url.stopAccessingSecurityScopedResource() }
        return true
    }

    // MARK: - Storage manager (per-family usage + delete-all)

    /// Ids the document knows for a family — the user-root ownership gate (the
    /// `BurnStore.ownsAuxFile` discipline: in a user-picked folder, only exact-shape files with
    /// a document-known id are ever counted or swept).
    private func documentIds(for family: StudioFamily) -> Set<String> {
        switch family {
        case .samples: return Set(samples.map(\.id))
        case .loops: return Set(loops.map(\.id))
        case .sequences: return Set(patterns.map(\.id))
        case .takes: return Set(takes.map(\.id))
        case .instruments: return []   // pack files live in InstrumentPacks' ledger, app root only
        }
    }

    /// On-disk bytes for one family's artifacts (Settings ▸ Storage usage row).
    func usageBytes(family: StudioFamily) -> Int {
        StudioFolders.usageBytes(family: family, bookmark: bookmark(for: family),
                                 knownIds: documentIds(for: family))
    }

    /// Storage manager: delete EVERYTHING in one family — files in both reachable roots AND the
    /// family's records. Safety rules (spec §3, MixSessionStore.deleteAllRecordings doctrine):
    ///   • the recorder's ACTIVE take file is skipped (its metadata isn't filed yet; sweeping
    ///     the open file would corrupt the capture) — callers run the recorder's orphan
    ///     recovery FIRST so crash-orphans are filed, then swept, not silently destroyed;
    ///   • in the user root only exact-shape files with document-known ids are swept (a user's
    ///     own files are never touched); the app root is app-private, shape alone owns;
    ///   • records whose user root is UNREACHABLE are KEPT (nothing was provably deleted);
    ///     everything else is dropped — this is a whole-family wipe, not a cache sweep.
    func deleteAll(family: StudioFamily) {
        let fm = FileManager.default
        let known = documentIds(for: family)
        let active = activeTakeFileName?()
        StudioFolders.forEachRoot(family: family, bookmark: bookmark(for: family)) { root, isUserFolder in
            let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            for n in names {
                guard n != active,
                      let id = StudioFolders.fileId(family: family, name: n) else { continue }
                if isUserFolder && !known.contains(id) { continue }
                try? fm.removeItem(at: root.appendingPathComponent(n))
            }
        }
        // Prune the records: drop unless the file survived (the skipped active take) or its
        // user root couldn't be checked. A record with no file at all (never-bounced pattern)
        // has nothing to orphan — it goes with the family wipe.
        let userReachable = userRootReachable(family)
        func keepRecord(_ fileName: String?, _ wasUser: Bool) -> Bool {
            guard let fileName, !fileName.isEmpty else { return false }
            if wasUser && !userReachable { return true }
            guard let got = StudioFolders.fileURL(family: family, fileName: fileName,
                                                  wasUserFolder: wasUser, bookmark: bookmark(for: family))
            else { return false }
            got.release?()
            return true   // still on disk (active take) → keep its record too
        }
        switch family {
        case .samples: samples.removeAll { !keepRecord($0.fileName, $0.wasUserFolder) }
        case .loops: loops.removeAll { !keepRecord($0.fileName, $0.wasUserFolder) }
        case .sequences: patterns.removeAll { !keepRecord($0.fileName, $0.wasUserFolder) }
        case .takes: takes.removeAll { !keepRecord($0.fileName, false) }
        case .instruments: break   // records belong to InstrumentPacks; only files were swept
        }
        saveNow()
    }

    // MARK: - Fixture seeding (PDJ_SEED_STUDIO=1 — UI tests / demos)

    /// Seed deterministic studio content for UI tests: 1 sample (constant 120 BPM grid),
    /// 1 loop, 1 pattern, and 2 cues on the fixture catalog's first song (`sng_1`). Gated on
    /// `PDJ_SEED_STUDIO=1` and an empty document (idempotent). Copies the bundled fixture audio
    /// when present, else synthesizes a 1 s tone so the seeded rows are never dead files.
    /// Donations/Spotlight are deliberately NOT involved (spec §11).
    func seedFixtureIfRequested(bundle: Bundle = .main) {
        guard ProcessInfo.processInfo.environment["PDJ_SEED_STUDIO"] == "1" else { return }
        guard samples.isEmpty, loops.isEmpty, patterns.isEmpty, cues.isEmpty else { return }
        guard let samplesDir = try? StudioFolders.appRoot(.samples),
              let loopsDir = try? StudioFolders.appRoot(.loops) else { return }

        // Fixed (non-uuid) ids so UI tests can address rows (`sample-row-smp_fixture`).
        let sampleId = "smp_fixture", loopId = "lp_fixture", patternId = "ptn_fixture"
        let sampleFile = StudioFolders.fileName(.samples, id: sampleId)
        let loopFile = StudioFolders.fileName(.loops, id: loopId)

        let sampleURL = samplesDir.appendingPathComponent(sampleFile)
        if let bundled = bundle.url(forResource: "studio-fixture", withExtension: "m4a") {
            try? FileManager.default.removeItem(at: sampleURL)
            try? FileManager.default.copyItem(at: bundled, to: sampleURL)
        }
        var sampleMs = 1_000
        if !FileManager.default.fileExists(atPath: sampleURL.path) {
            _ = Self.writeSeedTone(to: sampleURL, seconds: 1.0, aac: true)
        } else if let af = try? AVAudioFile(forReading: sampleURL), af.processingFormat.sampleRate > 0 {
            sampleMs = Int(Double(af.length) / af.processingFormat.sampleRate * 1000)
        }
        // The loop is ALWAYS synthesized LPCM CAF (the family's real format) — ½ s = 1 beat at
        // 120 BPM, with the frame count the write reports as the authoritative length.
        let loopFrames = Self.writeSeedTone(to: loopsDir.appendingPathComponent(loopFile),
                                            seconds: 0.5, aac: false)

        let now = nowMs
        addSample(StudioSample(id: sampleId, name: "Seeded Sample", fileName: sampleFile,
                               wasUserFolder: false, createdAt: now, durationMs: sampleMs,
                               source: .track(songId: "sng_1", startMs: 0, endMs: sampleMs),
                               grid: StudioGrid(bpm: 120, firstDownbeatMs: 0, beatsMs: [])))
        addLoop(StudioLoop(id: loopId, name: "Seeded Loop", sampleId: sampleId, anchorMs: 0,
                           beats: .one, bpm: 120, lengthMs: 500, frames: loopFrames,
                           fileName: loopFile, wasUserFolder: false, createdAt: now))
        var steps = Array(repeating: false, count: StudioPattern.stepCount)
        steps[0] = true; steps[4] = true; steps[8] = true; steps[12] = true
        addPattern(StudioPattern(id: patternId, name: "Seeded Pattern", bpm: 120,
                                 rows: [StudioPatternRow(targetId: sampleId, steps: steps)],
                                 createdAt: now))
        setCue(songId: "sng_1", slot: 0, positionMs: 1_000, name: "Intro")
        setCue(songId: "sng_1", slot: 1, positionMs: 5_000, name: "Drop")

        // A tiny piano take (C4 D4 E4 G4 quarters at 120 BPM) so the Score screen — and its
        // editor — is reachable in UI tests / demos. Audio is a synth tone (replay plays events).
        if takes.isEmpty, let takesDir = try? StudioFolders.appRoot(.takes) {
            let takeId = "tk_fixture"
            let takeFile = StudioFolders.fileName(.takes, id: takeId)
            Self.writeSeedTone(to: takesDir.appendingPathComponent(takeFile), seconds: 2.0, aac: true)
            let events = [60, 62, 64, 67].enumerated().map { i, n in
                StudioNoteEvent(onMs: i * 500, offMs: i * 500 + 480, note: n, velocity: 96)
            }
            addTake(StudioTake(id: takeId, name: "Seeded Take", instrument: .piano,
                               fileName: takeFile, bpm: 120, events: events,
                               durationMs: 2_000, createdAt: now))
        }
    }

    /// Write a short 440 Hz tone (44.1 kHz mono) — AAC m4a or LPCM 16-bit CAF. Returns the
    /// frame count written (0 on failure). Seed-only: production audio is written by the
    /// capture/render engines, never here.
    @discardableResult
    private static func writeSeedTone(to url: URL, seconds: Double, aac: Bool) -> Int64 {
        let sr = 44_100.0
        var settings: [String: Any] = [
            AVFormatIDKey: aac ? kAudioFormatMPEG4AAC : kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
        ]
        if !aac {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
        }
        try? FileManager.default.removeItem(at: url)
        guard let file = try? AVAudioFile(forWriting: url, settings: settings) else { return 0 }
        let frames = AVAudioFrameCount(sr * seconds)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return 0 }
        buf.frameLength = frames
        if let p = buf.floatChannelData?[0] {
            for i in 0..<Int(frames) {
                p[i] = sinf(Float(i) * 2 * .pi * 440 / Float(sr)) * 0.5
            }
        }
        guard (try? file.write(from: buf)) != nil else { return 0 }
        return Int64(frames)
    }

    // MARK: - Persistence plumbing (MixSessionStore shape)

    private func snapshotDocument() -> StudioDocument {
        StudioDocument(schemaVersion: studioSchemaVersion, samples: samples, loops: loops,
                       patterns: patterns, takes: takes, cues: cues, slices: slices)
    }

    /// Debounced save for continuous streams (edit sliders, cue nudges) — ~0.6 s of quiescence.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Immediate, off-main, versioned write (cancels any pending debounce).
    private func saveNow() {
        saveTask?.cancel(); saveTask = nil
        saveVersion += 1
        let v = saveVersion
        let doc = snapshotDocument()
        let url = fileURL
        let w = writer
        Task { await w.write(doc, version: v, to: url) }
    }

    /// Force-persist now (scene → background / quit). Writes SYNCHRONOUSLY so an OS suspension
    /// right after `.background` can't drop the latest mutation — then advances the writer's
    /// watermark so an in-flight async save carrying an older snapshot can't regress it.
    func flush() {
        saveTask?.cancel(); saveTask = nil
        saveVersion += 1
        let v = saveVersion
        let doc = snapshotDocument()
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: fileURL, options: .atomic)
        }
        let w = writer
        Task { await w.markWritten(v) }
    }
}
