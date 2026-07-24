import Foundation

// MARK: - Studio schema — samples, loops, patterns, takes, cues (versioned, lenient)
//
// Data model for the Performance tab ("Studio" in code — the `Performance/` FOLDER is taken by the
// pocket realize engine, and a type literally named `Performance` already exists there; see the
// spec's collision table, docs/design/performance-studio-spec.md §0). One versioned document
// (`pocketdj-studio.json`) persisted by `StudioStore`, following the collections doctrine
// (CollectionsSchema.swift header):
//   • additive-only — never remove/repurpose a field; bump `studioSchemaVersion` on shape changes;
//   • EVERY field decodes leniently (`try?` + default) so a future build's document never bricks
//     this one, and the document's LISTS decode per-element lossily — one broken element (a future
//     kind, hand-edited JSON) drops that element only, never the list, never the document;
//   • ids are minted with type prefixes (`smp_`/`lp_`/`ptn_`/`tk_`) like `CollectionsFactory`,
//     because studio ids ride collections' EXISTING string arrays (spec §8) and every consumer —
//     playback, stats, and crucially the rip/stemify guards — routes on the prefix.
let studioSchemaVersion = 1

// MARK: - Lossy element box (per-element list decoding)

/// Decodes ONE list element, swallowing its failure. The document arrays decode as
/// `[StudioLossyBox<T>]` + compactMap so a single malformed element is dropped instead of
/// throwing away the whole array (the native PlaylistNode unknown-kind data-loss lesson —
/// see the collections map — applied here from day one).
private struct StudioLossyBox<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Sample source (provenance)

/// Where a sample's audio came from. Provenance ONLY — playback always reads the sample's own
/// file; in particular "Use as sample" from a take COPIES the audio (spec §2), so a `.take`
/// sample never depends on the take file still existing.
enum StudioSource: Hashable, Sendable {
    /// Carved out of an indexed track: the song + the region (ms from the SONG's 0:00) it was
    /// cut from — enough to show "from <song> 1:02–1:10" and to re-carve if the user asks.
    case track(songId: String, startMs: Int, endMs: Int)
    /// Recorded from the microphone (no grid until the tap-tempo/manual-BPM affordance sets one).
    case mic
    /// Copied from an instrument take's rendered audio (`tk_…` id, provenance only).
    case take(takeId: String)
    /// Imported from an arbitrary audio file the user picked in the file browser — the original
    /// file name is kept only for the "from <name>" label. The audio was transcoded + copied into
    /// the samples folder, so the external file never needs to exist again (like `.take`, and no
    /// grid until auto-detect/tap-tempo sets one).
    case file(originalName: String)
    /// Captured from an EXTERNAL audio input (a USB-C / line / interface, e.g. a TX-6 mixer) rather
    /// than the built-in mic — `inputName` is the port name for the "from <name>" label. Same
    /// capture path as `.mic`; only the routed input + provenance differ.
    case lineIn(inputName: String?)
}

extension StudioSource: Codable {
    private enum CodingKeys: String, CodingKey { case type, songId, startMs, endMs, takeId, originalName, inputName }

    /// Lenient: an unknown/missing `type` (a future source kind read by this build) degrades to
    /// `.mic` — generic "recorded audio" provenance. The sample's FILE is what matters and it
    /// still plays; only the provenance label is lost, and only on this older build.
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        switch (try? c?.decode(String.self, forKey: .type)) ?? "mic" {
        case "track":
            self = .track(songId: (try? c?.decode(String.self, forKey: .songId)) ?? "",
                          startMs: (try? c?.decode(Int.self, forKey: .startMs)) ?? 0,
                          endMs: (try? c?.decode(Int.self, forKey: .endMs)) ?? 0)
        case "take":
            self = .take(takeId: (try? c?.decode(String.self, forKey: .takeId)) ?? "")
        case "file":
            self = .file(originalName: (try? c?.decode(String.self, forKey: .originalName)) ?? "")
        case "lineIn":
            self = .lineIn(inputName: try? c?.decode(String.self, forKey: .inputName))
        default:
            self = .mic
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .track(let songId, let startMs, let endMs):
            try c.encode("track", forKey: .type)
            try c.encode(songId, forKey: .songId)
            try c.encode(startMs, forKey: .startMs)
            try c.encode(endMs, forKey: .endMs)
        case .mic:
            try c.encode("mic", forKey: .type)
        case .take(let takeId):
            try c.encode("take", forKey: .type)
            try c.encode(takeId, forKey: .takeId)
        case .file(let originalName):
            try c.encode("file", forKey: .type)
            try c.encode(originalName, forKey: .originalName)
        case .lineIn(let inputName):
            try c.encode("lineIn", forKey: .type)
            try c.encodeIfPresent(inputName, forKey: .inputName)
        }
    }
}

// MARK: - Beat grid (per-sample)

/// A sample's beat grid, in ms from the SAMPLE's 0:00 (a track sample inherits the parent song's
/// `analysis-<songId>.json` grid offset-shifted by the carve region — done by the CALLER; this
/// store just persists what it's given). `beatsMs` empty ⇒ a CONSTANT grid synthesized from
/// `bpm` + `firstDownbeatMs` (mic samples after tap-tempo, take samples from `take.bpm`) —
/// the same fallback convention `BeatMath.sliceBoundaries` implements.
struct StudioGrid: Codable, Hashable, Sendable {
    var bpm: Double
    var firstDownbeatMs: Int
    /// The REAL measured per-beat timestamps (handles tempo drift); empty ⇒ constant grid.
    var beatsMs: [Int]

    /// The tuple shape `BeatMath.sliceBoundaries(anchorMs:beats:grid:)` consumes.
    var sliceGrid: (bpm: Double, firstDownbeatMs: Int, beatsMs: [Int]) { (bpm, firstDownbeatMs, beatsMs) }

    enum CodingKeys: String, CodingKey { case bpm, firstDownbeatMs, beatsMs }
    init(bpm: Double, firstDownbeatMs: Int = 0, beatsMs: [Int] = []) {
        self.bpm = bpm; self.firstDownbeatMs = firstDownbeatMs; self.beatsMs = beatsMs
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // bpm defaults to 120 (not 0): loop-length math divides by it, and a 0-bpm grid would
        // poison every consumer — 120 keeps a degraded document usable.
        bpm = (try? c.decode(Double.self, forKey: .bpm)) ?? 120
        firstDownbeatMs = (try? c.decode(Int.self, forKey: .firstDownbeatMs)) ?? 0
        beatsMs = (try? c.decode([Int].self, forKey: .beatsMs)) ?? []
    }
}

// MARK: - Sample edit (non-destructive)

/// A sample's non-destructive edit state — applied live at audition and BAKED only when
/// rendering (loop save / pattern use / the collection-playback render cache; spec §10 "Save
/// bakes nothing"). Plain value equality (`Equatable` via `Hashable`) is the edit-revision
/// contract: `StudioStore.updateSampleEdit` bumps `StudioSample.renderRevision` exactly when
/// the new value `!=` the old one, which is what invalidates a stale render cache.
struct StudioSampleEdit: Codable, Hashable, Sendable {
    /// Trim window (ms from the sample's 0:00). `trimEndMs == 0` means "to the end of the file"
    /// so the neutral value needs no knowledge of the file's length.
    var trimStartMs: Int = 0
    var trimEndMs: Int = 0
    var gainDb: Double = 0
    /// Playback rate 0.5–2.0 (1 = neutral). Clamped by `clamped()`, mirrored by the engine's
    /// timePitch limits.
    var rate: Double = 1
    /// Pitch shift in semitones, ±12.
    var pitchSemitones: Double = 0
    /// Effect sends, 0…1 (0 = dry).
    var reverbWet: Double = 0
    var delayWet: Double = 0
    /// B6 mixer-deck FX (ADDITIVE + OPTIONAL — absent ⇒ 0 ⇒ off, no schema bump). Both bake into
    /// the render exactly like the reverb/delay wets, so a sequencer row inherits them for free.
    /// `compWet` = compressor amount 0…1 (dynamics glue). `filterAmt` = resonant low-pass sweep
    /// 0…1 (0 = open/off → ~250 Hz), reusing the EQ band so the gain carrier is untouched.
    var compWet: Double = 0
    var filterAmt: Double = 0

    /// The do-nothing edit (a fresh sample; also what "reset edits" restores).
    static let neutral = StudioSampleEdit()

    var isNeutral: Bool { self == .neutral }

    /// Pure, testable range clamp — the store applies it on every write so a persisted edit can
    /// never carry an out-of-range value into the audition chain or the offline renderer.
    func clamped() -> StudioSampleEdit {
        var e = self
        e.trimStartMs = max(0, trimStartMs)
        e.trimEndMs = max(0, trimEndMs)
        if e.trimEndMs > 0, e.trimEndMs < e.trimStartMs { e.trimEndMs = e.trimStartMs }
        e.gainDb = min(12, max(-60, gainDb))
        e.rate = min(2.0, max(0.5, rate))
        e.pitchSemitones = min(12, max(-12, pitchSemitones))
        e.reverbWet = min(1, max(0, reverbWet))
        e.delayWet = min(1, max(0, delayWet))
        e.compWet = min(1, max(0, compWet))
        e.filterAmt = min(1, max(0, filterAmt))
        return e
    }

    enum CodingKeys: String, CodingKey {
        case trimStartMs, trimEndMs, gainDb, rate, pitchSemitones, reverbWet, delayWet
        case compWet, filterAmt
    }
    init(trimStartMs: Int = 0, trimEndMs: Int = 0, gainDb: Double = 0, rate: Double = 1,
         pitchSemitones: Double = 0, reverbWet: Double = 0, delayWet: Double = 0,
         compWet: Double = 0, filterAmt: Double = 0) {
        self.trimStartMs = trimStartMs; self.trimEndMs = trimEndMs; self.gainDb = gainDb
        self.rate = rate; self.pitchSemitones = pitchSemitones
        self.reverbWet = reverbWet; self.delayWet = delayWet
        self.compWet = compWet; self.filterAmt = filterAmt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trimStartMs = (try? c.decode(Int.self, forKey: .trimStartMs)) ?? 0
        trimEndMs = (try? c.decode(Int.self, forKey: .trimEndMs)) ?? 0
        gainDb = (try? c.decode(Double.self, forKey: .gainDb)) ?? 0
        rate = (try? c.decode(Double.self, forKey: .rate)) ?? 1
        pitchSemitones = (try? c.decode(Double.self, forKey: .pitchSemitones)) ?? 0
        reverbWet = (try? c.decode(Double.self, forKey: .reverbWet)) ?? 0
        delayWet = (try? c.decode(Double.self, forKey: .delayWet)) ?? 0
        // Additive/optional: a legacy edit with no comp/filter keys decodes to 0 (off).
        compWet = (try? c.decode(Double.self, forKey: .compWet)) ?? 0
        filterAmt = (try? c.decode(Double.self, forKey: .filterAmt)) ?? 0
    }
}

// MARK: - Sample

/// A recorded/carved audio sample. The RAW file (`sample-<id>.m4a`) is immutable after capture;
/// edits are non-destructive metadata on top, baked only into derived artifacts (loops, pattern
/// row buffers) and into the optional RENDER CACHE the collection-playback path prefers.
struct StudioSample: Codable, Identifiable, Hashable, Sendable {
    var id: String                    // "smp_…" (StudioFactory)
    var name: String
    /// The RAW audio file's name inside the samples family folder (deterministic
    /// `sample-<id>.m4a`, minted via `StudioFolders.fileName`).
    var fileName: String
    /// Where the raw file was WRITTEN: true ⇒ the user-picked samples folder (resolved via its
    /// security-scoped bookmark), false ⇒ the app-managed root. Mirrors `MixRecording.wasUserFolder`
    /// — an artifact forever resolves against the root it was actually written to, never the
    /// current setting.
    var wasUserFolder: Bool = false
    var createdAt: Double = 0         // epoch ms
    /// RAW audio length (pre-edit). Post-edit length is `effectiveDurationMs`.
    var durationMs: Int = 0
    var source: StudioSource = .mic
    /// nil until known: track samples inherit (offset-shifted, by the CALLER), take samples get a
    /// constant grid from `take.bpm`, mic samples gain one via tap-tempo/manual BPM (spec §2).
    var grid: StudioGrid?
    var edit: StudioSampleEdit = .neutral
    /// Monotonic edit stamp — bumped by the store whenever `edit` actually changes. The render
    /// cache is FRESH iff `renderedRevision == renderRevision`; playback falls back to the raw
    /// file otherwise (never plays a stale bake).
    var renderRevision: Int = 0

    // Render cache (edits baked, written by StudioRender via `StudioStore.setRenderedSample`).
    // Its own wasUserFolder because the samples folder setting may have changed between the raw
    // capture and the render — each file resolves against where IT was written.
    var renderedFileName: String?
    var renderedRevision: Int?
    var renderedWasUserFolder: Bool?
    /// F9: the sample folder this sample belongs to (a `StudioSampleFolder` `sfld_…` id), or nil =
    /// Unfiled. ADDITIVE + OPTIONAL organizational metadata: a legacy document with no `folderId`
    /// key decodes to nil (Unfiled), and a `folderId` pointing at a folder no longer in the
    /// document reads as Unfiled at the view layer — never a decode failure, never a wipe.
    var folderId: String?

    /// Whether the render cache exists (per the record) AND matches the current edit revision.
    /// Disk existence is still checked at resolve time (`StudioStore.localURLForPlayback`).
    var isRenderFresh: Bool { renderedFileName != nil && renderedRevision == renderRevision }

    /// The length (ms) the sample PLAYS at with its current edit applied — trim window over
    /// rate. This is what collection stats/realize consume so a trimmed 2 s stab never counts
    /// as its raw 30 s capture.
    var effectiveDurationMs: Int {
        let end = edit.trimEndMs > 0 ? min(edit.trimEndMs, durationMs) : durationMs
        let window = max(0, end - max(0, edit.trimStartMs))
        let rate = edit.rate > 0 ? edit.rate : 1
        return Int((Double(window) / rate).rounded())
    }

    enum CodingKeys: String, CodingKey {
        case id, name, fileName, wasUserFolder, createdAt, durationMs, source, grid, edit
        case renderRevision, renderedFileName, renderedRevision, renderedWasUserFolder, folderId
    }
    init(id: String, name: String, fileName: String, wasUserFolder: Bool = false,
         createdAt: Double = 0, durationMs: Int = 0, source: StudioSource = .mic,
         grid: StudioGrid? = nil, edit: StudioSampleEdit = .neutral, renderRevision: Int = 0,
         renderedFileName: String? = nil, renderedRevision: Int? = nil,
         renderedWasUserFolder: Bool? = nil, folderId: String? = nil) {
        self.id = id; self.name = name; self.fileName = fileName
        self.wasUserFolder = wasUserFolder; self.createdAt = createdAt
        self.durationMs = durationMs; self.source = source; self.grid = grid; self.edit = edit
        self.renderRevision = renderRevision; self.renderedFileName = renderedFileName
        self.renderedRevision = renderedRevision; self.renderedWasUserFolder = renderedWasUserFolder
        self.folderId = folderId
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? StudioFactory.newSampleId()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        fileName = (try? c.decode(String.self, forKey: .fileName)) ?? ""
        wasUserFolder = (try? c.decode(Bool.self, forKey: .wasUserFolder)) ?? false
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        durationMs = (try? c.decode(Int.self, forKey: .durationMs)) ?? 0
        source = (try? c.decode(StudioSource.self, forKey: .source)) ?? .mic
        grid = try? c.decode(StudioGrid.self, forKey: .grid)
        edit = (try? c.decode(StudioSampleEdit.self, forKey: .edit)) ?? .neutral
        renderRevision = (try? c.decode(Int.self, forKey: .renderRevision)) ?? 0
        renderedFileName = try? c.decode(String.self, forKey: .renderedFileName)
        renderedRevision = try? c.decode(Int.self, forKey: .renderedRevision)
        renderedWasUserFolder = try? c.decode(Bool.self, forKey: .renderedWasUserFolder)
        // Additive/optional: absent ⇒ nil (Unfiled) — the wipe-safety default.
        folderId = try? c.decode(String.self, forKey: .folderId)
    }
}

// MARK: - Sample folder (F9 — flat organizational grouping)

/// A flat, named folder for organizing SAMPLES (spec F9) — mirrors `PlaylistFolder`. Membership is
/// by `StudioSample.folderId` (ONE folder per sample; nil = Unfiled), so a folder carries no member
/// list — it's just an id + name + timestamps. DEVICE-LOCAL like the sample audio (Studio is
/// deliberately not in the CloudSync registry). Lenient/all-optional decode per the studio doctrine
/// (every field `try?` + default), so a future build's document never bricks this one.
struct StudioSampleFolder: Codable, Identifiable, Hashable, Sendable {
    var id: String                    // "sfld_…" — NON-collection-riding (like cue_/slc_)
    var name: String
    var createdAt: Double = 0
    var updatedAt: Double = 0

    enum CodingKeys: String, CodingKey { case id, name, createdAt, updatedAt }
    init(id: String, name: String, createdAt: Double = 0, updatedAt: Double = 0) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? StudioFactory.newSampleFolderId()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
    }
}

// MARK: - Loop

/// Beat-window sizes a loop can be sliced at (spec §1: ½, 1, 2, 4, 8, 16, 32 beats). Raw value
/// IS the beat count (0.5…32) so it round-trips as a plain JSON number and feeds beat math
/// directly; an unknown persisted value decodes leniently to `.four` at the `StudioLoop` site.
enum LoopBeats: Double, Codable, CaseIterable, Hashable, Sendable {
    case half = 0.5, one = 1, two = 2, four = 4, eight = 8, sixteen = 16, thirtyTwo = 32

    /// The beat count as the number beat math consumes (0.5…32).
    var beatCount: Double { rawValue }

    /// Slice-button label ("½", "1", … "32").
    var label: String { self == .half ? "½" : String(Int(rawValue)) }
}

/// A beat-grid-synced slice of a sample, RENDERED at save time to an LPCM CAF
/// (`loop-<id>.caf`) with the sample's edits baked, so it plays standalone/offline and loops
/// seamlessly (AAC priming/padding makes m4a loop files tick at the seam — spec §2). A loop is
/// SELF-CONTAINED after render: deleting the parent sample leaves it playable (re-slicing is
/// disabled and the row shows a "source removed" note — `StudioStore.sampleExists`).
struct StudioLoop: Codable, Identifiable, Hashable, Sendable {
    var id: String                    // "lp_…"
    var name: String
    /// The parent sample this was sliced from (dangling after that sample is deleted — flagged,
    /// never cleaned up: the loop's audio doesn't depend on it).
    var sampleId: String
    /// Where the slice started, ms from the parent SAMPLE's 0:00 (for re-slicing UI).
    var anchorMs: Int = 0
    var beats: LoopBeats = .four
    /// The tempo the window was sliced at (drives the sequencer default + display).
    var bpm: Double = 120
    /// The rendered window's length in ms (display/stats; the frame count is the truth).
    var lengthMs: Int = 0
    /// AUTHORITATIVE rendered length in FRAMES. Loop audition trims/pads the decoded buffer to
    /// exactly this count before `scheduleBuffer(options: .loops)` — ms-derived frame counts
    /// round differently per sample rate and a ±1-frame seam ticks audibly (spec §2).
    var frames: Int64 = 0
    /// `loop-<id>.caf` in the loops family folder.
    var fileName: String
    var wasUserFolder: Bool = false
    var createdAt: Double = 0

    enum CodingKeys: String, CodingKey {
        case id, name, sampleId, anchorMs, beats, bpm, lengthMs, frames, fileName, wasUserFolder, createdAt
    }
    init(id: String, name: String, sampleId: String, anchorMs: Int = 0, beats: LoopBeats = .four,
         bpm: Double = 120, lengthMs: Int = 0, frames: Int64 = 0, fileName: String,
         wasUserFolder: Bool = false, createdAt: Double = 0) {
        self.id = id; self.name = name; self.sampleId = sampleId; self.anchorMs = anchorMs
        self.beats = beats; self.bpm = bpm; self.lengthMs = lengthMs; self.frames = frames
        self.fileName = fileName; self.wasUserFolder = wasUserFolder; self.createdAt = createdAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? StudioFactory.newLoopId()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        sampleId = (try? c.decode(String.self, forKey: .sampleId)) ?? ""
        anchorMs = (try? c.decode(Int.self, forKey: .anchorMs)) ?? 0
        beats = (try? c.decode(LoopBeats.self, forKey: .beats)) ?? .four
        bpm = (try? c.decode(Double.self, forKey: .bpm)) ?? 120
        lengthMs = (try? c.decode(Int.self, forKey: .lengthMs)) ?? 0
        frames = (try? c.decode(Int64.self, forKey: .frames)) ?? 0
        fileName = (try? c.decode(String.self, forKey: .fileName)) ?? ""
        wasUserFolder = (try? c.decode(Bool.self, forKey: .wasUserFolder)) ?? false
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
    }
}

// MARK: - Pattern (16-step sequencer; user-facing label "Sequencer")

/// One sequencer row: a target (sample `smp_…` or loop `lp_…`) + its 16 step toggles + a row
/// gain. A row whose target was deleted stays in the pattern as a muted "missing" row —
/// playback and bounce SKIP it (never a throw), and re-adding a target with the same id would
/// revive it (spec §2).
struct StudioPatternRow: Codable, Hashable, Sendable {
    var targetId: String
    /// One toggle per step; the owning pattern's `stepCount` sets the length (SEQ4). Lenient
    /// decode preserves the full array, and `StudioPattern` resizes every row to its stepCount.
    var steps: [Bool]
    var gainDb: Double = 0
    /// Per-step trigger mode: `true` = LOOP (the hit keeps re-looping until the sequencer next
    /// retriggers this row — typically the same step one bar later, which restarts it), `false`
    /// = one-shot (plays once from the trigger, the original behavior). Meaningful only where
    /// `steps` is on. Additive field (docs without it decode to all-false = all one-shot); an
    /// older build that saves the document drops it — accepted schema doctrine.
    var loopSteps: [Bool]
    /// Per-step stretch span: 0 = natural length (untouched), n ≥ 1 = tempo-fit the sample to
    /// EXACTLY n steps (time-stretch via rate, pitch preserved). Meaningful only where `steps`
    /// is on. Same additive treatment as `loopSteps` (absent ⇒ all 0).
    var stepSpans: [Int]

    /// A row with no sounding step (contributes nothing; also the freshly-added state).
    var isSilent: Bool { !steps.contains(true) }

    enum CodingKeys: String, CodingKey { case targetId, steps, gainDb, loopSteps, stepSpans }
    init(targetId: String, steps: [Bool] = Array(repeating: false, count: StudioPattern.defaultStepCount),
         gainDb: Double = 0,
         loopSteps: [Bool] = Array(repeating: false, count: StudioPattern.defaultStepCount),
         stepSpans: [Int] = Array(repeating: 0, count: StudioPattern.defaultStepCount)) {
        // Length-preserving: a row built with a long `steps` keeps it; a default row is 16.
        // StudioPattern.resized re-sizes it to the owning pattern's stepCount when it differs (SEQ4).
        let n = max(steps.count, StudioPattern.defaultStepCount)
        self.targetId = targetId
        self.steps = StudioPatternRow.normalized(steps, to: n)
        self.gainDb = gainDb
        self.loopSteps = StudioPatternRow.normalized(loopSteps, to: n)
        self.stepSpans = StudioPatternRow.normalizedSpans(stepSpans, to: n)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetId = (try? c.decode(String.self, forKey: .targetId)) ?? ""
        // Preserve the FULL decoded step array (up to maxStepCount) — do NOT truncate to the
        // default here, or a long SEQ4 pattern's rows would silently lose steps 16+ on load.
        // StudioPattern.init(from:) resizes every row to the pattern's own stepCount afterward.
        let rawSteps = (try? c.decode([Bool].self, forKey: .steps)) ?? []
        // Pad short/legacy arrays up to the default (16) but PRESERVE longer ones (up to 365) —
        // StudioPattern.init(from:) then resizes every row to the pattern's authoritative stepCount.
        let n = max(rawSteps.count, StudioPattern.defaultStepCount)
        steps = StudioPatternRow.normalized(rawSteps, to: n)
        gainDb = (try? c.decode(Double.self, forKey: .gainDb)) ?? 0
        loopSteps = StudioPatternRow.normalized((try? c.decode([Bool].self, forKey: .loopSteps)) ?? [], to: n)
        stepSpans = StudioPatternRow.normalizedSpans((try? c.decode([Int].self, forKey: .stepSpans)) ?? [], to: n)
    }

    /// Pad/truncate a bool array to exactly `count` (pure, testable).
    static func normalized(_ steps: [Bool], to count: Int = StudioPattern.defaultStepCount) -> [Bool] {
        var s = Array(steps.prefix(count))
        if s.count < count { s += Array(repeating: false, count: count - s.count) }
        return s
    }

    /// `normalized` for the span array: pad/truncate to `count` AND clamp each span to 0…count
    /// (a hand-edited document can't demand a stretch longer than the pattern).
    static func normalizedSpans(_ spans: [Int], to count: Int = StudioPattern.defaultStepCount) -> [Int] {
        var s = Array(spans.prefix(count)).map { min(max($0, 0), count) }
        if s.count < count { s += Array(repeating: 0, count: count - s.count) }
        return s
    }

    /// Re-size all three step arrays to exactly `count` (SEQ4 — sizing a row to its pattern's
    /// stepCount). Direct mutation bypasses the init's default normalization.
    func resized(to count: Int) -> StudioPatternRow {
        var r = self
        r.steps = StudioPatternRow.normalized(steps, to: count)
        r.loopSteps = StudioPatternRow.normalized(loopSteps, to: count)
        r.stepSpans = StudioPatternRow.normalizedSpans(stepSpans, to: count)
        return r
    }
}

/// A 16-step sequencer pattern — one bar of 16ths in 4/4 over sample/loop rows. Bounced to
/// `pattern-<id>.m4a` on demand; ANY edit re-marks `bounceDirty` so a stale bounce is never
/// played/exported as the pattern (spec §2).
struct StudioPattern: Codable, Identifiable, Hashable, Sendable {
    /// The default pattern length — one bar of 16th notes in 4/4 (step duration = 60/bpm/4 s).
    static let defaultStepCount = 16
    /// The longest supported pattern (SEQ4): ~23 bars of 16ths.
    static let maxStepCount = 365

    var id: String                    // "ptn_…"
    var name: String
    var bpm: Double = 120
    /// Steps per row (SEQ4). Additive-optional: docs without it decode to 16, and an older build
    /// that re-saves drops it (accepted schema doctrine) — NEVER bump a version for this. Rows are
    /// always sized to this via `StudioPatternRow.resized` on init/decode.
    var stepCount: Int = defaultStepCount
    var rows: [StudioPatternRow] = []
    /// The rendered bounce (`pattern-<id>.m4a`), nil until first bounced. Kept on disk when
    /// dirty (cheap; rebounce overwrites) — `bounceDirty` is what gates playback/export.
    var fileName: String?
    /// True whenever the pattern changed since `fileName` was rendered. Starts true (no bounce).
    var bounceDirty: Bool = true
    /// Root the BOUNCE file was written to (the pattern itself lives in the document).
    var wasUserFolder: Bool = false
    var createdAt: Double = 0

    /// Any sounding step at all? A pattern with zero sounding steps refuses to bounce/play with
    /// an inline notice — zero-frame schedules crash (spec §2). The engine additionally skips
    /// rows whose target is missing (a store-level check, `StudioStore.targetExists`).
    var hasSoundingSteps: Bool { rows.contains { !$0.isSilent } }

    /// One musical bar's length (ms) at `bpm` — 4 beats of 4/4 (the bounce's nominal length and
    /// the step grid's loop period). Pure + testable; guards a 0 bpm document with the 120 default.
    static func barMs(bpm: Double) -> Int {
        let b = bpm > 0 ? bpm : 120
        return Int((240_000.0 / b).rounded())
    }

    /// This pattern's full loop length in ms — `stepCount` sixteenths at `bpm` (one bar when
    /// stepCount is 16, proportionally longer for a multi-bar SEQ4 pattern). Its length wherever
    /// it appears in a collection.
    var lengthMs: Int { StudioPattern.barMs(bpm: bpm) * stepCount / StudioPattern.defaultStepCount }

    /// Clamp a step count to the supported 1…max range.
    static func clampStepCount(_ n: Int) -> Int { min(max(n, 1), maxStepCount) }

    enum CodingKeys: String, CodingKey {
        case id, name, bpm, stepCount, rows, fileName, bounceDirty, wasUserFolder, createdAt
    }
    init(id: String, name: String, bpm: Double = 120, stepCount: Int = defaultStepCount,
         rows: [StudioPatternRow] = [], fileName: String? = nil, bounceDirty: Bool = true,
         wasUserFolder: Bool = false, createdAt: Double = 0) {
        self.id = id; self.name = name; self.bpm = bpm
        self.stepCount = StudioPattern.clampStepCount(stepCount)
        self.rows = rows.map { $0.resized(to: self.stepCount) }
        self.fileName = fileName; self.bounceDirty = bounceDirty
        self.wasUserFolder = wasUserFolder; self.createdAt = createdAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? StudioFactory.newPatternId()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        bpm = (try? c.decode(Double.self, forKey: .bpm)) ?? 120
        stepCount = StudioPattern.clampStepCount((try? c.decode(Int.self, forKey: .stepCount))
                                                 ?? StudioPattern.defaultStepCount)
        rows = ((try? c.decode([StudioLossyBox<StudioPatternRow>].self, forKey: .rows)) ?? [])
            .compactMap(\.value).map { $0.resized(to: stepCount) }
        fileName = try? c.decode(String.self, forKey: .fileName)
        bounceDirty = (try? c.decode(Bool.self, forKey: .bounceDirty)) ?? true
        wasUserFolder = (try? c.decode(Bool.self, forKey: .wasUserFolder)) ?? false
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
    }
}

// MARK: - Instruments + takes

/// The seven v1 virtual instruments. Raw string persists in takes; `gmProgram` is the General
/// MIDI program the shared sound bank is addressed with (`loadSoundBankInstrument(program:)`) —
/// the numbers are the GM standard's, locked in the spec (§2/§6): a changed mapping would make
/// every saved take replay on the wrong instrument.
enum InstrumentKey: String, Codable, CaseIterable, Hashable, Sendable {
    case piano, violin, bassGuitar, acousticGuitar, trumpet, clarinet, harp

    /// General MIDI program number (0-based) within the shared GM bank.
    var gmProgram: UInt8 {
        switch self {
        case .piano: return 0
        case .violin: return 40
        case .bassGuitar: return 33      // GM 34 "Electric Bass (finger)", 0-based 33
        case .acousticGuitar: return 25  // GM 26 "Acoustic Guitar (steel)", 0-based 25
        case .trumpet: return 56
        case .clarinet: return 71
        case .harp: return 46            // GM 47 "Orchestral Harp", 0-based 46
        }
    }

    var displayName: String {
        switch self {
        case .piano: return "Piano"
        case .violin: return "Violin"
        case .bassGuitar: return "Bass Guitar"
        case .acousticGuitar: return "Acoustic Guitar"
        case .trumpet: return "Trumpet"
        case .clarinet: return "Clarinet"
        case .harp: return "Harp"
        }
    }
}

/// One played note inside a take. Times are ms measured from BEAT 1 — the end of the count-in
/// (spec §4/§7): the same anchor ScoreQuantizer snaps to, so the score, the replay, and the MIDI
/// export all agree on where the music starts. `note`/`velocity` are raw MIDI (0–127).
/// How a note is spelled on the staff (spec §7 editing). Absent on an event ⇒ DERIVE the spelling
/// (C-major sharps: a black key is the natural-below + ♯). An explicit value overrides that so an
/// EDITED note can read as a flat (E♭, not D♯). DISPLAY-ONLY — the MIDI note is the sound, so the
/// MIDI/PDF exports (SMF writes raw MIDI numbers) are unaffected by spelling.
enum Accidental: String, Codable, Hashable, Sendable { case natural, sharp, flat }

struct StudioNoteEvent: Codable, Hashable, Sendable {
    var onMs: Int
    var offMs: Int
    var note: Int
    var velocity: Int
    /// Optional spelling override (nil ⇒ derived). Additive: old builds ignore the extra key.
    var accidental: Accidental?

    enum CodingKeys: String, CodingKey { case onMs, offMs, note, velocity, accidental }
    init(onMs: Int, offMs: Int, note: Int, velocity: Int, accidental: Accidental? = nil) {
        self.onMs = onMs; self.offMs = offMs; self.note = note
        self.velocity = velocity; self.accidental = accidental
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onMs = (try? c.decode(Int.self, forKey: .onMs)) ?? 0
        offMs = (try? c.decode(Int.self, forKey: .offMs)) ?? 0
        note = (try? c.decode(Int.self, forKey: .note)) ?? 0
        velocity = (try? c.decode(Int.self, forKey: .velocity)) ?? 0
        accidental = try? c.decode(Accidental.self, forKey: .accidental)
    }
}

/// A recorded instrument performance ("instrumental"): the captured audio (`take-<id>.m4a`) plus
/// the raw note-event log the score is quantized from and the replay/MIDI/audio export read. The
/// file is recorded into app storage and relocated into the user's instrumentals folder on clean
/// finish (`wasUserFolder` stamps which root holds it — same discipline as `StudioSample`).
struct StudioTake: Codable, Identifiable, Hashable, Sendable {
    var id: String                    // "tk_…"
    var name: String
    var instrument: InstrumentKey = .piano
    /// `take-<id>.m4a`. Recorded into app storage, then RELOCATED into the user's instrumentals
    /// folder on clean finish when one is configured (`StudioStore.addTakeRelocating`).
    var fileName: String
    /// Where the file was WRITTEN: true ⇒ the user-picked instrumentals folder (resolved via its
    /// security-scoped bookmark), false ⇒ the app-managed root. Mirrors `StudioSample.wasUserFolder`
    /// — an instrumental forever resolves against the root it was actually written to, never the
    /// current setting. Additive (old takes decode false = app storage).
    var wasUserFolder: Bool = false
    /// The click/quantize tempo the take was recorded at (ScoreQuantizer's grid).
    var bpm: Double = 120
    /// Raw UNQUANTIZED events (ms from beat 1 = end of count-in) — quantization happens at
    /// score-render time so it can improve without touching saved takes.
    var events: [StudioNoteEvent] = []
    var durationMs: Int = 0
    var createdAt: Double = 0
    /// User-EDITED note stream (spec §7 editing). nil ⇒ never edited: the score/replay/MIDI derive
    /// from raw `events` (so quantizer improvements still apply). Non-nil ⇒ the score is the source
    /// of truth for this take — score/replay/MIDI read THIS instead. Additive: old builds drop it.
    var editedEvents: [StudioNoteEvent]?

    /// The events the score, replay, and exports read: the edited stream once the user has touched
    /// the score, else the raw performance.
    var scoreEvents: [StudioNoteEvent] { editedEvents ?? events }

    /// Rendered-audio cache: the take's `scoreEvents` synthesized through its instrument into a real
    /// `.m4a` (`take-<id>-r0.m4a`), so a live-saved take — whose raw `fileName` is a SILENT
    /// placeholder — is audible in collection playback + Mix. Populated lazily by
    /// `StudioTakeRenderer.ensureRendered`; CLEARED on a score edit (stale). Its own `wasUserFolder`
    /// because the instrumentals folder setting may have changed since the raw capture.
    var renderedFileName: String?
    var renderedWasUserFolder: Bool?

    /// Demux provenance (F8 slice B — the comping↔melody switch). `demuxSourceKey` is the
    /// `DemuxDocument` key the take was extracted from (so the switch re-reaches the chords /
    /// stem); `demuxMode` is "comping" or "melody". BOTH nil for a take that isn't a Demux
    /// instrumental. Additive-OPTIONAL (the `editedEvents` precedent) — NO schemaVersion bump, so
    /// an old take without them decodes intact.
    var demuxSourceKey: String?
    var demuxMode: String?

    enum CodingKeys: String, CodingKey {
        case id, name, instrument, fileName, wasUserFolder, bpm, events, durationMs, createdAt, editedEvents
        case renderedFileName, renderedWasUserFolder, demuxSourceKey, demuxMode
    }
    init(id: String, name: String, instrument: InstrumentKey = .piano, fileName: String,
         wasUserFolder: Bool = false, bpm: Double = 120, events: [StudioNoteEvent] = [],
         durationMs: Int = 0, createdAt: Double = 0, editedEvents: [StudioNoteEvent]? = nil,
         renderedFileName: String? = nil, renderedWasUserFolder: Bool? = nil,
         demuxSourceKey: String? = nil, demuxMode: String? = nil) {
        self.id = id; self.name = name; self.instrument = instrument; self.fileName = fileName
        self.wasUserFolder = wasUserFolder; self.bpm = bpm; self.events = events
        self.durationMs = durationMs; self.createdAt = createdAt; self.editedEvents = editedEvents
        self.renderedFileName = renderedFileName; self.renderedWasUserFolder = renderedWasUserFolder
        self.demuxSourceKey = demuxSourceKey; self.demuxMode = demuxMode
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? StudioFactory.newTakeId()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        instrument = (try? c.decode(InstrumentKey.self, forKey: .instrument)) ?? .piano
        fileName = (try? c.decode(String.self, forKey: .fileName)) ?? ""
        wasUserFolder = (try? c.decode(Bool.self, forKey: .wasUserFolder)) ?? false
        bpm = (try? c.decode(Double.self, forKey: .bpm)) ?? 120
        events = ((try? c.decode([StudioLossyBox<StudioNoteEvent>].self, forKey: .events)) ?? [])
            .compactMap(\.value)
        durationMs = (try? c.decode(Int.self, forKey: .durationMs)) ?? 0
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        editedEvents = (try? c.decode([StudioLossyBox<StudioNoteEvent>].self, forKey: .editedEvents))?
            .compactMap(\.value)
        renderedFileName = try? c.decode(String.self, forKey: .renderedFileName)
        renderedWasUserFolder = try? c.decode(Bool.self, forKey: .renderedWasUserFolder)
        demuxSourceKey = try? c.decode(String.self, forKey: .demuxSourceKey)
        demuxMode = try? c.decode(String.self, forKey: .demuxMode)
    }
}

// MARK: - Cue points

/// One cue point on an indexed track — tap-to-play-from-here (spec §9). At most
/// `StudioCue.maxSlots` per song, STORE-enforced (`StudioStore.setCue` rejects out-of-range
/// slots; the 8-slot UI maps 1:1). `slot` doubles as the stable color index.
struct StudioCue: Codable, Identifiable, Hashable, Sendable {
    /// 8 slots (0–7) per song — the hard cap the store enforces.
    static let maxSlots = 8

    var id: String                    // "cue_…" (NOT a collection-riding prefix — see StudioFactory)
    var songId: String
    var slot: Int                     // 0–7, unique per (songId, slot)
    var positionMs: Int
    var name: String?

    enum CodingKeys: String, CodingKey { case id, songId, slot, positionMs, name }
    init(id: String, songId: String, slot: Int, positionMs: Int, name: String? = nil) {
        self.id = id; self.songId = songId; self.slot = slot
        self.positionMs = positionMs; self.name = name
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? StudioFactory.newCueId()
        songId = (try? c.decode(String.self, forKey: .songId)) ?? ""
        slot = (try? c.decode(Int.self, forKey: .slot)) ?? 0
        positionMs = (try? c.decode(Int.self, forKey: .positionMs)) ?? 0
        name = try? c.decode(String.self, forKey: .name)
    }
}

// MARK: - Slices (sample partition → performance pads)

/// One slice of a SAMPLE — a start-marker cue point that plays until the NEXT slice's start (by
/// time) or the sample's end (spec: slicing). Up to `maxSlots` per sample, store-enforced. `slot`
/// is the stable pad index / colour (0–7); the play-out boundary is derived from sibling starts,
/// NOT the slot, so pads may be dragged out of time order. A slice is an audition-only MARKER with
/// a NON-riding id (like a cue) — "Make pad" bakes the region into a real `smp_` sample that then
/// flows through Loops / the sequencer / use-as-sample under the normal studio-id fence.
struct StudioSlice: Codable, Identifiable, Hashable, Sendable {
    /// 8 slots (0–7) per sample — the hard cap the store enforces (matches the 8-pad grid).
    static let maxSlots = 8

    var id: String                    // "slc_…" (NOT a collection-riding prefix — see StudioFactory)
    var sampleId: String
    var slot: Int                     // 0–7, unique per (sampleId, slot); also the pad/colour index
    var startMs: Int                  // slice IN point, SAMPLE-relative (the OUT is the next start)
    var name: String?

    enum CodingKeys: String, CodingKey { case id, sampleId, slot, startMs, name }
    init(id: String, sampleId: String, slot: Int, startMs: Int, name: String? = nil) {
        self.id = id; self.sampleId = sampleId; self.slot = slot
        self.startMs = startMs; self.name = name
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? StudioFactory.newSliceId()
        sampleId = (try? c.decode(String.self, forKey: .sampleId)) ?? ""
        slot = (try? c.decode(Int.self, forKey: .slot)) ?? 0
        startMs = (try? c.decode(Int.self, forKey: .startMs)) ?? 0
        name = try? c.decode(String.self, forKey: .name)
    }
}

// MARK: - Document (persistence envelope)

/// The versioned studio document (`pocketdj-studio.json`). Every list decodes per-element
/// lossily and every element decodes leniently — a future build's fields/kinds degrade to
/// defaults or drop the single element, never the document (the schema doctrine above).
struct StudioDocument: Codable, Sendable {
    var schemaVersion: Int = studioSchemaVersion
    var samples: [StudioSample] = []
    var loops: [StudioLoop] = []
    var patterns: [StudioPattern] = []
    var takes: [StudioTake] = []
    var cues: [StudioCue] = []
    var slices: [StudioSlice] = []
    /// F9: flat sample folders (device-local). New OPTIONAL collection: a legacy document with no
    /// `folders` key decodes to `[]`, and the list decodes per-element lossily like every other.
    var folders: [StudioSampleFolder] = []
    /// On-device DETECTED musical key (Camelot code) per performance item, keyed by studio id
    /// (`smp_`/`lp_`/`ptn_`/`tk_`). Populated by `StudioAnalyzer` when an item is added to a
    /// collection; consumed for harmonic mix-glide. A parallel map (not a per-model field) so it
    /// rides one additive key across all four families. Absent ⇒ not analyzed yet.
    var keys: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, samples, loops, patterns, takes, cues, slices, folders, keys
    }
    init(schemaVersion: Int = studioSchemaVersion, samples: [StudioSample] = [],
         loops: [StudioLoop] = [], patterns: [StudioPattern] = [], takes: [StudioTake] = [],
         cues: [StudioCue] = [], slices: [StudioSlice] = [],
         folders: [StudioSampleFolder] = [], keys: [String: String] = [:]) {
        self.schemaVersion = schemaVersion; self.samples = samples; self.loops = loops
        self.patterns = patterns; self.takes = takes; self.cues = cues; self.slices = slices
        self.folders = folders; self.keys = keys
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 0
        samples = ((try? c.decode([StudioLossyBox<StudioSample>].self, forKey: .samples)) ?? [])
            .compactMap(\.value)
        loops = ((try? c.decode([StudioLossyBox<StudioLoop>].self, forKey: .loops)) ?? [])
            .compactMap(\.value)
        patterns = ((try? c.decode([StudioLossyBox<StudioPattern>].self, forKey: .patterns)) ?? [])
            .compactMap(\.value)
        takes = ((try? c.decode([StudioLossyBox<StudioTake>].self, forKey: .takes)) ?? [])
            .compactMap(\.value)
        cues = ((try? c.decode([StudioLossyBox<StudioCue>].self, forKey: .cues)) ?? [])
            .compactMap(\.value)
        slices = ((try? c.decode([StudioLossyBox<StudioSlice>].self, forKey: .slices)) ?? [])
            .compactMap(\.value)
        folders = ((try? c.decode([StudioLossyBox<StudioSampleFolder>].self, forKey: .folders)) ?? [])
            .compactMap(\.value)
        keys = (try? c.decode([String: String].self, forKey: .keys)) ?? [:]
    }
}

// MARK: - Factory (id minting — mirrors CollectionsFactory)

enum StudioFactory {
    static func uid() -> String { UUID().uuidString.lowercased() }
    static func newSampleId() -> String { "smp_" + uid() }
    static func newLoopId() -> String { "lp_" + uid() }
    static func newPatternId() -> String { "ptn_" + uid() }
    static func newTakeId() -> String { "tk_" + uid() }
    /// Cues are deliberately NOT in `studioPrefixes`: a cue never rides a collection id array,
    /// so the rip/realize guards must not treat `cue_` as a routable studio item.
    static func newCueId() -> String { "cue_" + uid() }
    /// Slices are audition-only MARKERS on a sample — like `cue_`, NEVER in `studioPrefixes` (a
    /// slice id never rides a collection array; "Make pad" bakes a real `smp_` sample instead).
    static func newSliceId() -> String { "slc_" + uid() }
    /// Sample folders are organizational metadata (F9). Like `cue_`/`slc_`, a folder id NEVER rides
    /// a collection's string array, so `sfld_` is deliberately NOT in `studioPrefixes` — adding it
    /// there would leak folder ids into the rip/realize guards.
    static func newSampleFolderId() -> String { "sfld_" + uid() }

    /// The id namespaces that ride collections' string arrays (spec §8) — the SINGLE source of
    /// truth for every guard that must fence studio ids out of money/infra paths (RipsStore
    /// rip/stemify, `songIds(forSetlist:)` CSV/rip exclusion, realize autofill, the rip server's
    /// id rejection mirrors this list).
    static let studioPrefixes = ["smp_", "lp_", "ptn_", "tk_"]

    /// True when `id` is a studio-namespaced id (sample/loop/pattern/take).
    static func isStudioId(_ id: String) -> Bool {
        studioPrefixes.contains { id.hasPrefix($0) }
    }
}
