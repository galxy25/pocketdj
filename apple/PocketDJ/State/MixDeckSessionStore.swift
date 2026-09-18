import Foundation

/// Version stamp on the persisted mix-deck snapshot — bump on breaking shape changes. A
/// mismatched (older/newer) file simply doesn't restore (`load()` → nil); it is never migrated.
let mixDeckSessionSchemaVersion = 1

/// Off-main, serialized, last-writer-wins JSON writer (the `PlaybackSessionWriter` /
/// `MixSessionWriter` pattern): the atomic file write runs on a background executor, and a
/// monotonic `version` guard means a late-arriving stale snapshot can never clobber a newer
/// one — including the DELETE that `clear()` issues (a nil payload removes the file).
/// `markWritten` advances the watermark for a write `flush()` already performed synchronously.
private actor MixDeckSessionWriter {
    private var written = 0
    func write(_ data: Data?, version: Int, to url: URL) {
        guard version > written else { return }
        written = version
        if let data {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
    func markWritten(_ version: Int) { written = max(written, version) }
}

/// Durable Mix deck sessions (phase 2 of durable playback sessions) — the single
/// overwrite-in-place snapshot of the app-scoped `MixEngine`'s live state, written IN REAL TIME
/// as the mix happens (never at exit): both decks (loaded track + playhead + volume/tempo/
/// pitch/effects/stem state), the crossfader + lead deck, and the Auto-DJ machine (its queue —
/// jukebox `autoQueueInsert`s included — cursor, source label, and glide flags). Force-quit or
/// restart the phone, reopen, and `MixEngine.materializePendingRestoreIfNeeded()` rebuilds the
/// Mix tab exactly as it was — decks re-loaded and cued, Auto-DJ SUSPENDED — with no audio
/// until the user acts.
///
/// Each track ref snapshots title/artist/bpm/camelot/… so a restore is SELF-CONTAINED (no
/// catalog lookup at launch); only the audio FILE is re-resolved (BurnStore / studio store),
/// and a vanished file simply leaves that deck empty. The file is ~KBs
/// (`pocketdj-mix-decks.json` in Application Support). Structural changes write immediately;
/// slider-y control changes are DEBOUNCED (~1 s trailing edge, so a drag never writes at 60 Hz
/// but its final value always lands); playhead refreshes are throttled (~5 s) while running and
/// immediate on a run/pause transition. `load()` is deliberately lenient — ANY decode failure
/// returns nil so a corrupt/old file can never block or crash launch. NO disk I/O in init.
@MainActor
final class MixDeckSessionStore {

    /// A deck-loadable track's identity + display metadata — the exact inputs of
    /// `MixEngine.load(songId:title:…)` (≙ `MixLoadable`), so a restore re-loads through the
    /// SAME path a user tap does (BurnStore cut/analog resolution, studio-item seam, beat-grid
    /// hydration all included).
    struct TrackRef: Codable, Equatable {
        var songId: String
        var title: String
        var artist: String
        var bpm: Double?
        var camelot: String?
        var key: String?
        var albumId: String?
        /// Song length (ms) — bounds an analog shared-album fallback to its slice on re-load.
        var lengthMs: Int?
    }

    /// One deck's restorable state: the track plus every PLAIN-VALUE control (`DeckState`
    /// fields that are user intent, not runtime plumbing). Cue/PFL routing, the VU meter
    /// source, and the beat grid are deliberately NOT here (transient / derivable — see the
    /// engine's restore doc).
    struct DeckSnapshot: Codable, Equatable {
        var track: TrackRef
        /// Playhead, ms from the song's own 0:00 (the deck's source-seconds position).
        var positionMs: Int
        var volume: Double
        var rate: Double
        var pitch: Double
        var compressor: Bool
        var reverb: Bool
        var flanger: Bool
        var filter: Bool
        var compStrength: Double
        var reverbStrength: Double
        var flangerStrength: Double
        var filterStrength: Double
        var stemMode: Bool
        var stemMuted: [String]
        var stemVol: [String: Double]
        /// LOOP (∞) intent: engaged state + length in the deck's unit (beats when the track has a
        /// grid, else seconds). OPTIONAL deliberately — the loader demands an EXACT
        /// `schemaVersion` match (a bump would throw away every saved session), and Swift's
        /// synthesized decode has no default-value fallback for a missing key, so optionality is
        /// what lets pre-loop sessions keep restoring. Absent ⇒ no loop, default length.
        var loopOn: Bool? = nil
        var loopUnits: Double? = nil
        /// 3-band EQ gain in dB. OPTIONAL for the same reason as `loopOn`/`loopUnits` — absent ⇒
        /// flat (0 dB) on every band.
        var eqLow: Double? = nil
        var eqMid: Double? = nil
        var eqHigh: Double? = nil
        /// Filter FX mode rawValue ("lowPass"/"highPass"). OPTIONAL (schema-safe); absent ⇒ lowPass.
        /// SUPERSEDED by `fxSlots` (which carries a variant per slot) — still WRITTEN for rollback
        /// and still READ when migrating a pre-rack session.
        var filterMode: String? = nil
        /// The FX RACK, lossless: one entry per slot, in rack order. OPTIONAL for the same reason as
        /// `loopOn`/`eqLow` — the loader demands an EXACT `schemaVersion` match, so bumping would
        /// discard every saved session. Absent (a pre-rack session) ⇒ synthesized from the flat
        /// fields above in the default layout, which is exactly what those sessions meant.
        /// Read through `resolvedSlots`, never directly.
        var fxSlots: [FXSlotSnapshot]? = nil

        /// The rack layout a restore should apply: the lossless `fxSlots` when present and WELL-FORMED,
        /// else the pre-rack flat fields mapped onto the default layout. Never fails, never returns
        /// empty — a corrupt rack degrades to the legacy reading rather than to a dead deck.
        var resolvedSlots: [FXSlotSnapshot] {
            if let s = fxSlots, s.count == MixDeckSessionStore.fxSlotCount,
               s.allSatisfy({ $0.isWellFormed }) {
                return s
            }
            return [
                FXSlotSnapshot(effect: "compressor", variant: "punch", on: compressor, strength: compStrength),
                FXSlotSnapshot(effect: "reverb", variant: "hall", on: reverb, strength: reverbStrength),
                FXSlotSnapshot(effect: "flanger", variant: "flange", on: flanger, strength: flangerStrength),
                FXSlotSnapshot(effect: "filter",
                               variant: filterMode == "highPass" ? "highPass" : "lowPass",
                               on: filter, strength: filterStrength),
            ]
        }
    }

    /// One rack slot on disk. Strings (not the enums) so an unrecognised value from a NEWER build
    /// degrades to a default on load instead of throwing away the whole session.
    struct FXSlotSnapshot: Codable, Equatable {
        var effect: String
        var variant: String
        var on: Bool
        var strength: Double
        /// Both rawValues resolve AND the variant belongs to the effect's family.
        var isWellFormed: Bool {
            guard let e = MixEngine.Effect(rawValue: effect),
                  let v = EffectVariant(rawValue: variant) else { return false }
            return v.effect == e
        }
    }

    /// Mirrors `MixEngine.fxSlotCount` — a snapshot with a different count is treated as corrupt.
    /// `nonisolated` so the pure `resolvedSlots` migration can read it off the main actor.
    nonisolated static let fxSlotCount = 4

    /// One Auto-DJ queue row — a `MixEngine.AutoMixItem` (loadable + known length).
    struct AutoRow: Codable, Equatable {
        var track: TrackRef
        var durationMs: Int
        /// Provenance: the crate (pocket/set list) name this row came from — the TV queue
        /// surfaces show it. OPTIONAL (a schema bump discards sessions); nil for legacy rows.
        var sourceLabel: String? = nil
    }

    /// The Auto-DJ machine's restorable state. The queue is stored in its FINAL order (shuffle
    /// already applied), so restore never re-shuffles. There is deliberately no `paused` flag:
    /// a restored Auto-DJ is ALWAYS suspended (`autoPaused`) — audio never self-starts, and the
    /// existing Resume paths re-arm the machine against live playback. In-flight transition
    /// state (pre-roll/fade/post-roll timestamps, glide context) is runtime wall-clock state
    /// and is NOT persisted — a kill mid-crossfade restores in the suspended idle state.
    struct AutoSnapshot: Codable, Equatable {
        var queue: [AutoRow]
        /// `autoLivePos` — the queue index of the live track.
        var livePos: Int
        /// `autoNextToLoad` — first index no deck has committed to (jukebox insert low bound).
        var nextToLoad: Int
        /// `autoLiveDeck` rawValue ("A"/"B").
        var liveDeck: String
        var sourceLabel: String?
        var leadSeconds: Double
        var fadeSeconds: Double
        var fxGlide: Bool
        var mixGlide: Bool
        /// `MixEngine.AutoRepeatMode.rawValue` — OPTIONAL (absent/legacy ⇒ off).
        var repeatMode: String? = nil
    }

    struct Snapshot: Codable, Equatable {
        var schemaVersion: Int = mixDeckSessionSchemaVersion
        var deckA: DeckSnapshot?
        var deckB: DeckSnapshot?
        var crossfader: Double
        /// `leadDeck` rawValue ("A"/"B"), nil = none.
        var leadDeck: String?
        var auto: AutoSnapshot?
        /// Whether any deck was audibly playing at the last write (informational — a restore is
        /// always held — and the position-throttle's run/pause transition detector).
        var wasRunning: Bool
        /// Epoch ms of the last write (informational — a session never expires on its own).
        var updatedAt: Double

        /// A snapshot with nothing to restore (no deck, no auto queue) is meaningless.
        var isEmpty: Bool { deckA == nil && deckB == nil && (auto?.queue.isEmpty ?? true) }
    }

    /// Min seconds between position-only writes while running (injectable for tests).
    var positionWriteInterval: TimeInterval = 5
    /// Trailing-edge debounce for slider-y control writes (injectable for tests). A drag calls
    /// `saveDebounced` at 60 Hz; one write lands `controlDebounceInterval` after the LAST call.
    var controlDebounceInterval: TimeInterval = 1

    private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (registration reads the SAME URL the
    /// store was constructed with — never re-derives it, so fixture seams stay intact).
    var syncFileURL: URL { fileURL }
    private let writer = MixDeckSessionWriter()
    /// The in-memory truth of the current mix's snapshot (nil = no active mix).
    private var current: Snapshot?
    private var version = 0
    private var lastWriteAt: TimeInterval = 0
    private var debounceTask: Task<Void, Never>?

    /// NO disk read here — construction happens in `PocketDJApp.init()`, before the first
    /// frame (the visionOS first-frame lesson). The snapshot is READ later, by `load()`
    /// from RootView's launch task.
    init(fileURL: URL = MixDeckSessionStore.defaultURL()) {
        self.fileURL = fileURL
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-mix-decks.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (deterministic, never touches the
    /// user's real session — and existing Mix UI tests see no leftover decks). Mirrors
    /// `PlaybackSessionStore.launchURL`.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-mix-decks.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    // MARK: - Writes

    /// A STRUCTURAL change (deck load/eject, auto-mix start/stop/skip/insert/pause/resume,
    /// lead change, effect toggle) — persists immediately, superseding any pending debounce.
    func save(_ snapshot: Snapshot, now: TimeInterval = Date().timeIntervalSince1970) {
        debounceTask?.cancel(); debounceTask = nil   // this write carries the newest state
        current = snapshot
        current?.updatedAt = now * 1000
        writeNow(at: now)
    }

    /// A CONTROL change from a continuous surface (volume / crossfader / tempo / pitch /
    /// effect-strength / stem-gain slider): update memory now, land ONE write
    /// `controlDebounceInterval` after the burst ends (trailing edge — the drag's final value
    /// always persists; 60 Hz drags never hit disk per-tick).
    func saveDebounced(_ snapshot: Snapshot, now: TimeInterval = Date().timeIntervalSince1970) {
        current = snapshot
        current?.updatedAt = now * 1000
        guard debounceTask == nil else { return }    // an armed write picks up the latest state
        let interval = controlDebounceInterval
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.debounceTask = nil
            self.writeNow(at: Date().timeIntervalSince1970)
        }
    }

    /// A playhead refresh for the CURRENT mix. Throttled to one write per
    /// `positionWriteInterval` while running; a run/pause TRANSITION writes immediately (the
    /// position a restore cues must be the paused one, not up to 5 s stale). Steady paused
    /// state writes nothing (positions can't move). No-op when no mix is active.
    func updatePosition(aMs: Int?, bMs: Int?, isRunning: Bool,
                        now: TimeInterval = Date().timeIntervalSince1970) {
        guard var snap = current else { return }
        let wasRunning = snap.wasRunning
        if let aMs, snap.deckA != nil { snap.deckA?.positionMs = aMs }
        if let bMs, snap.deckB != nil { snap.deckB?.positionMs = bMs }
        snap.wasRunning = isRunning
        snap.updatedAt = now * 1000
        current = snap
        if isRunning != wasRunning {
            writeNow(at: now)
        } else if isRunning, now - lastWriteAt >= positionWriteInterval {
            writeNow(at: now)
        }
    }

    /// The mix is genuinely over (both decks ejected — deck clear, the Settings nuclear
    /// reset): forget it and delete the file — a finished mix must not rehydrate on the next
    /// launch. Cancels any pending debounced write (current = nil also makes it a no-op).
    func clear() {
        debounceTask?.cancel(); debounceTask = nil
        current = nil
        version += 1
        let v = version
        let url = fileURL
        let w = writer
        Task { await w.write(nil, version: v, to: url) }
    }

    // MARK: - Read

    /// The persisted snapshot, or nil. LENIENT: any read/decode failure, a schema-version
    /// mismatch, or an empty snapshot → nil — never throws, never blocks launch on repair.
    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
              snap.schemaVersion == mixDeckSessionSchemaVersion,
              !snap.isEmpty
        else { return nil }
        return snap
    }

    /// Force-persist now (scene → background). SYNCHRONOUS (encode + atomic write inline) so
    /// an OS suspension right after `.background` can't drop the latest positions — then the
    /// writer watermark advances so an in-flight async save carrying an older snapshot can't
    /// regress what was just written (the `PlaybackSessionStore.flush` doctrine).
    func flush(now: TimeInterval = Date().timeIntervalSince1970) {
        guard let current else { return }
        debounceTask?.cancel(); debounceTask = nil   // this synchronous write carries the latest
        version += 1
        let v = version
        lastWriteAt = now
        var snap = current
        snap.updatedAt = now * 1000
        self.current = snap
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: fileURL, options: .atomic)
        }
        let w = writer
        Task { await w.markWritten(v) }
    }

    // MARK: - Test seam

    /// UI-test seam: when `PDJ_SEED_MIX_DECK_SESSION` is set, write a canned mid-mix snapshot
    /// to the session file — both decks loaded with the `PDJ_SEED_STUDIO` fixture items (whose
    /// audio files the studio seed puts on disk, so materialization actually loads them) and a
    /// suspended two-track Auto-DJ — so a UI test can launch "as if" the app was killed
    /// mid-mix and assert the restored decks. Exercises the REAL load path (the file on disk
    /// is what restores). No-op outside the seam.
    func seedFixtureIfRequested() {
        guard ProcessInfo.processInfo.environment["PDJ_SEED_MIX_DECK_SESSION"] != nil else { return }
        let sample = TrackRef(songId: "smp_fixture", title: "Seeded Sample", artist: "PocketDJ",
                              bpm: 120, camelot: nil, key: nil, albumId: nil, lengthMs: 1_000)
        let loop = TrackRef(songId: "lp_fixture", title: "Seeded Loop", artist: "PocketDJ",
                            bpm: 120, camelot: nil, key: nil, albumId: nil, lengthMs: 500)
        func deck(_ t: TrackRef, positionMs: Int) -> DeckSnapshot {
            DeckSnapshot(track: t, positionMs: positionMs, volume: 1.0, rate: 1.0, pitch: 0,
                         compressor: false, reverb: false, flanger: false, filter: false,
                         compStrength: 0.5, reverbStrength: 0.5, flangerStrength: 0.5,
                         filterStrength: 0.5, stemMode: false, stemMuted: [], stemVol: [:])
        }
        let snap = Snapshot(deckA: deck(sample, positionMs: 250),
                            deckB: deck(loop, positionMs: 0),
                            crossfader: 0.35, leadDeck: nil,
                            auto: AutoSnapshot(queue: [AutoRow(track: sample, durationMs: 1_000),
                                                       AutoRow(track: loop, durationMs: 500)],
                                               livePos: 0, nextToLoad: 2, liveDeck: "A",
                                               sourceLabel: "Warmup", leadSeconds: 15,
                                               fadeSeconds: 3, fxGlide: false, mixGlide: false),
                            wasRunning: true,
                            updatedAt: Date().timeIntervalSince1970 * 1000)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Internals

    /// Immediate, versioned write of the in-memory snapshot; the actual I/O is off-main.
    private func writeNow(at now: TimeInterval) {
        guard let current else { return }
        version += 1
        let v = version
        lastWriteAt = now
        guard let data = try? JSONEncoder().encode(current) else { return }
        let url = fileURL
        let w = writer
        Task { await w.write(data, version: v, to: url) }
    }
}
