import Foundation
import Observation

/// Off-main, serialized, last-writer-wins JSON writer. Encoding + the atomic file write run on a
/// background executor (a long session can hold tens of thousands of events). A monotonic `version`
/// guard means a late-arriving stale snapshot can never clobber a newer one, regardless of Task
/// scheduling order.
private actor MixSessionWriter {
    private var written = 0
    func write(_ doc: MixSessionsDocument, version: Int, to url: URL) {
        guard version > written else { return }
        written = version
        guard let data = try? JSONEncoder().encode(doc) else { return }
        try? data.write(to: url, options: .atomic)
    }
    /// Advance the watermark for a write already performed synchronously (by `flush`), so a later
    /// async write carrying an older version can't regress it.
    func markWritten(_ version: Int) { written = max(written, version) }
}

/// App-side store for **mix sessions** — what songs you played + the full, time-stamped activity log
/// of a mixing sitting, kept until you hit Reset (which finalizes it and starts a new one). Owned by
/// `PocketDJApp` (env), wired as `MixEngine.recorder` so every deck action is logged. Persists to
/// `pocketdj-mix-sessions.json` (mirrors `CollectionsStore`).
///
/// PERF: the hot recording buffer (`recEvents`/`recPlayed`) is `@ObservationIgnored`, so the ~8 Hz
/// stream of fader events during a live mix invalidates NO SwiftUI view. Only low-frequency,
/// user-visible state is observed: the current session `name` (toolbar title), the `sessions` list
/// (only the Sessions screen reads it), and a `playedRevision` tick (the loader's checkmarks). The
/// hot buffer is folded into a `MixSession` value only when saving or finalizing.
@MainActor
@Observable
final class MixSessionStore: MixSessionRecorder {

    /// Finalized + current sessions, newest-relevant for the Sessions list. The CURRENT session's
    /// `events`/`playedSongIds` here are a periodically-folded snapshot — the live truth is the hot
    /// buffer below (read it via `events(forSession:)` / `hasPlayed`).
    private(set) var sessions: [MixSession] = []
    private(set) var currentId: String = ""
    /// The current session's display name — its OWN observed property so the toolbar title
    /// invalidates only on rename / new-session, never on a logged event.
    private(set) var currentName: String = "Session 1"
    /// Bumped whenever the played-set changes, so the loader's checkmarks/auto-hide refresh while
    /// open without observing the heavy `sessions` array.
    private(set) var playedRevision = 0

    // Hot buffer for the CURRENT session (NOT observed — fader events must not redraw the Mix UI).
    @ObservationIgnored private var recEvents: [MixSessionEvent] = []
    @ObservationIgnored private var recPlayed: [String] = []
    @ObservationIgnored private var recStartedAt: Double = 0   // epoch ms, re-anchored to first activity
    @ObservationIgnored private var recSeq = 0                 // monotonic event-id allocator
    @ObservationIgnored private var counter = 0                // "Session N" allocator
    @ObservationIgnored private var hasActivity = false        // current session has ≥1 real event
    @ObservationIgnored private var resumePendingReanchor = false   // resumed non-empty session awaiting rebase

    @ObservationIgnored private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (registration reads the SAME URL the
    /// store was constructed with — never re-derives it, so fixture seams stay intact).
    var syncFileURL: URL { fileURL }
    @ObservationIgnored private let writer = MixSessionWriter()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveVersion = 0

    /// Coalesce continuous events into ≤1 per 120 ms bucket; a soft cap bounds a runaway session.
    private static let coalesceWindowMs = 120
    private static let maxEvents = 100_000

    // MARK: Init / persistence location

    init(fileURL: URL = MixSessionStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(MixSessionsDocument.self, from: data) {
            sessions = doc.sessions
            counter = doc.counter
            // Resume the previously-current session (a session lasts until Reset, across relaunches).
            if let cid = doc.currentId, let cur = sessions.first(where: { $0.id == cid }) {
                currentId = cur.id
                currentName = cur.name
                recEvents = cur.events
                recPlayed = cur.playedSongIds
                recStartedAt = cur.startedAt
                recSeq = cur.events.count
                hasActivity = !cur.events.isEmpty
                resumePendingReanchor = hasActivity   // rebase t0 on the first NEW action (skip the offline gap)
            }
        }
        if currentId.isEmpty { startNewSession(save: false) }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-mix-sessions.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (deterministic, never touches real data).
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-mix-sessions.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    private var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    /// Anchor the timeline t0 on the FIRST activity of a session. For a fresh/empty session that's
    /// "now" (tMs starts at 0). For a session RESUMED across relaunch, rebase so this event lands just
    /// after the last saved event's tMs — never embedding the (possibly huge) app-closed wall-clock gap.
    private func anchorOnFirstActivity() {
        if !hasActivity {
            recStartedAt = nowMs; hasActivity = true
        } else if resumePendingReanchor {
            // Land the first new event just PAST the coalesce window after the last saved event:
            // contiguous (the offline gap is dropped) but a DISTINCT event, so a same-kind continuous
            // gesture doesn't merge into the pre-relaunch one.
            recStartedAt = nowMs - Double((recEvents.last?.tMs ?? 0) + Self.coalesceWindowMs)
            resumePendingReanchor = false
        }
    }

    // MARK: - Recorder (MixSessionRecorder) — the engine emits here

    func logEvent(_ kind: MixEventKind, deck: String?, songId: String?, title: String?,
                  artist: String?, bpm: Double?, camelot: String?, param: String?,
                  value: Double?, flag: Bool?, posMs: Int?) {
        anchorOnFirstActivity()
        let tMs = max(0, Int(nowMs - recStartedAt))

        // Coalesce a continuous run: if the LAST event is the same (kind, deck, param) and still
        // inside this 120 ms bucket, update its value/position in place (keep its bucket-start tMs)
        // instead of appending — downsamples a drag to ~8 Hz while preserving the trajectory.
        if kind.isContinuous, let i = recEvents.indices.last,
           recEvents[i].kind == kind, recEvents[i].deck == deck, recEvents[i].param == param,
           tMs - recEvents[i].tMs < Self.coalesceWindowMs {
            recEvents[i].value = value
            recEvents[i].posMs = posMs
            scheduleSave()
            return
        }

        guard recEvents.count < Self.maxEvents else { return }   // soft cap — bound a runaway session
        recSeq += 1
        recEvents.append(MixSessionEvent(id: "e\(recSeq)", tMs: tMs, kind: kind, deck: deck,
                                         songId: songId, title: title, artist: artist, bpm: bpm,
                                         camelot: camelot, param: param, value: value, flag: flag,
                                         posMs: posMs))
        // Discrete, high-value events persist immediately; continuous ones ride the debounce.
        kind.isContinuous ? scheduleSave() : saveNow()
    }

    func logGlide(deck: String?, param: String, songId: String?, title: String?, artist: String?,
                  from: Double, to: Double, rate: Double, posMs: Int?) {
        anchorOnFirstActivity()
        let tMs = max(0, Int(nowMs - recStartedAt))
        guard recEvents.count < Self.maxEvents else { return }
        recSeq += 1
        recEvents.append(MixSessionEvent(id: "e\(recSeq)", tMs: tMs, kind: .glide, deck: deck,
                                         songId: songId, title: title, artist: artist, bpm: nil,
                                         camelot: nil, param: param, value: to, flag: nil, posMs: posMs,
                                         fromValue: from, rate: rate))
        saveNow()   // discrete + high-value → persist immediately
    }

    func notePlayed(songId: String) {
        guard !songId.isEmpty else { return }
        anchorOnFirstActivity()
        guard !recPlayed.contains(songId) else { return }
        recPlayed.append(songId)
        playedRevision &+= 1     // observed → loader checkmarks/auto-hide refresh
        saveNow()
    }

    /// Whether `songId` has been played in the CURRENT session (drives loader checkmark + auto-hide).
    func hasPlayed(_ songId: String) -> Bool { recPlayed.contains(songId) }

    // MARK: - Recordings (captured mix audio)

    /// Attach a finished audio recording's metadata to a session (the one that was current when
    /// capture began — passed explicitly so a Reset mid-recording still files the take correctly).
    /// The audio file itself already lives in the session folder; this just records where + how long.
    /// Returns the allocated recording id (nil if the session no longer exists).
    @discardableResult
    func addRecording(toSession id: String, fileName: String, startedAt: Double,
                      durationMs: Int, wasUserFolder: Bool) -> String? {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        let seq = (sessions[i].recordings?.count ?? 0) + 1
        let rec = MixRecording(id: "rec\(seq)", fileName: fileName, startedAt: startedAt,
                               durationMs: durationMs, wasUserFolder: wasUserFolder)
        sessions[i].recordings = (sessions[i].recordings ?? []) + [rec]
        saveNow()
        return rec.id
    }

    /// The recordings attached to a session (newest last), for the Sessions detail screen.
    func recordings(forSession id: String) -> [MixRecording] { session(id)?.recordingsList ?? [] }

    /// Re-file a recording whose originating session was DELETED mid-capture, so the finished take
    /// isn't lost. Reuses the ORIGINAL session id — which still matches the on-disk folder the audio
    /// was written into — reviving it as a minimal finalized session if it's gone, then attaching the
    /// recording. No file move (the audio already lives in `mix-sessions/<sessionId>/`).
    func recoverRecording(sessionId: String, name: String, fileName: String, startedAt: Double,
                          durationMs: Int, wasUserFolder: Bool) {
        guard !sessionId.isEmpty else { return }
        if sessions.firstIndex(where: { $0.id == sessionId }) == nil {
            var s = MixSession(id: sessionId, name: name, startedAt: startedAt,
                               endedAt: startedAt + Double(durationMs), events: [], playedSongIds: [])
            s.recordings = []
            sessions.append(s)
        }
        addRecording(toSession: sessionId, fileName: fileName, startedAt: startedAt,
                     durationMs: durationMs, wasUserFolder: wasUserFolder)
    }

    /// Storage manager: delete EVERY captured recording's audio file and clear those
    /// takes' metadata, leaving the sessions/events themselves intact (tiny JSON — the
    /// auto-mix corpus). Sweeps BOTH roots for stray takes (a crash-orphaned `.m4a` the
    /// next orphan scan would otherwise revive) and removes emptied per-session
    /// subfolders. `skippingSessionId`/`skippingFileName` protect an in-flight capture's
    /// open file (pass `MixRecorder.activeTake` while recording).
    ///
    /// Data-safety rules (a user-picked session folder may hold the user's OWN folders +
    /// audio, and a burn folder on another device may be unreachable right now):
    ///   • only SESSION folders are swept — subfolders this app named (`mses_…` / a known
    ///     session id); anything else in a user-picked folder is never touched;
    ///   • metadata is dropped only for takes whose file is PROVABLY gone — a recording
    ///     in a currently-unresolvable user folder keeps its record (nothing was deleted).
    func deleteAllRecordings(bookmark: Data?, skippingSessionId: String? = nil,
                             skippingFileName: String? = nil) {
        let fm = FileManager.default
        let knownIds = Set(sessions.map(\.id))
        SessionFolders.forEachRoot(bookmark: bookmark) { root in
            let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let sessionId = dir.lastPathComponent
                // Only app-named session folders — never a user's own subfolder.
                guard sessionId.hasPrefix("mses_") || knownIds.contains(sessionId) else { continue }
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                for f in files where f.pathExtension.lowercased() == "m4a" {
                    if sessionId == skippingSessionId && f.lastPathComponent == skippingFileName { continue }
                    try? fm.removeItem(at: f)
                }
                if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty {
                    try? fm.removeItem(at: dir)
                }
            }
        }
        // Is the user root reachable right now? (Resolve read-only; release the scope.)
        var userRootReachable = false
        if bookmark != nil,
           let user = SessionFolders.resolveRoot(bookmark: bookmark, requireWritable: false),
           user.isUserFolder {
            userRootReachable = true
            if user.scoped { user.url.stopAccessingSecurityScopedResource() }
        }
        for i in sessions.indices {
            guard var recs = sessions[i].recordings, !recs.isEmpty else { continue }
            let sid = sessions[i].id
            recs.removeAll { rec in
                if sid == skippingSessionId && rec.fileName == skippingFileName { return false }
                // Keep the record when its root can't even be checked — nothing was deleted.
                if rec.wasUserFolder && !userRootReachable { return false }
                let resolved = SessionFolders.recordingURL(sessionId: sid, fileName: rec.fileName,
                                                           wasUserFolder: rec.wasUserFolder,
                                                           bookmark: bookmark)
                resolved?.release?()
                return resolved == nil   // provably gone → drop the metadata
            }
            sessions[i].recordings = recs
        }
        saveNow()
    }

    /// Session view / storage manager: delete ONE captured take — its audio file and its
    /// metadata (the session itself, with its events/played log, is untouched). Same
    /// data-safety rule as `deleteAllRecordings`: when the take's root is UNREACHABLE
    /// right now (a user folder on an unplugged drive / offline provider), nothing is
    /// deleted and the metadata is KEPT — no silent orphaning. A take whose file is
    /// already gone (reachable root, missing file) just drops its stale record. The
    /// emptied app-named session folder is pruned. Returns true when the take's record
    /// was removed.
    @discardableResult
    func deleteRecording(sessionId: String, recordingId: String, bookmark: Data?) -> Bool {
        guard let si = sessions.firstIndex(where: { $0.id == sessionId }),
              let rec = sessions[si].recordings?.first(where: { $0.id == recordingId }) else { return false }
        let fm = FileManager.default
        if let resolved = SessionFolders.recordingURL(sessionId: sessionId, fileName: rec.fileName,
                                                      wasUserFolder: rec.wasUserFolder, bookmark: bookmark) {
            let dir = resolved.url.deletingLastPathComponent()
            try? fm.removeItem(at: resolved.url)
            // Tidy an emptied session folder (app-named `mses_…`/session-id dir — never a
            // user's own folder, recordingURL only resolves inside session folders).
            if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty {
                try? fm.removeItem(at: dir)
            }
            resolved.release?()
        } else if rec.wasUserFolder {
            // The file didn't resolve: distinguish "root unreachable" (keep everything)
            // from "root reachable, file already gone" (stale record → drop it).
            var reachable = false
            if bookmark != nil,
               let root = SessionFolders.resolveRoot(bookmark: bookmark, requireWritable: false),
               root.isUserFolder {
                reachable = true
                if root.scoped { root.url.stopAccessingSecurityScopedResource() }
            }
            if !reachable { return false }
        }
        sessions[si].recordings?.removeAll { $0.id == recordingId }
        saveNow()
        return true
    }

    // MARK: - Readers (Sessions screen)

    func session(_ id: String) -> MixSession? { sessions.first { $0.id == id } }
    var current: MixSession? { session(currentId) }

    /// Sessions newest-first for the list (by start time).
    var sessionsNewestFirst: [MixSession] { sessions.sorted { $0.startedAt > $1.startedAt } }

    /// The live events for a session — the hot buffer for the CURRENT one, else the saved snapshot.
    func events(forSession id: String) -> [MixSessionEvent] {
        id == currentId ? recEvents : (session(id)?.events ?? [])
    }
    func playedSongIds(forSession id: String) -> [String] {
        id == currentId ? recPlayed : (session(id)?.playedSongIds ?? [])
    }
    func durationMs(forSession id: String) -> Int {
        if id == currentId { return recEvents.last?.tMs ?? 0 }
        return session(id)?.durationMs ?? 0
    }
    func startedAt(forSession id: String) -> Double {
        id == currentId ? recStartedAt : (session(id)?.startedAt ?? 0)
    }

    // MARK: - Lifecycle (reset / rename / delete)

    /// The Reset (X) action: finalize the current session and start a fresh one. A no-op when the
    /// current session has no activity yet (so repeated resets never pile up empty sessions).
    func reset() {
        guard hasActivity else { return }
        foldCurrentIntoSessions(endedAt: nowMs)
        startNewSession(save: true)
    }

    func rename(_ id: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].name = n
        if id == currentId { currentName = n }
        saveNow()
    }

    func delete(_ id: String) {
        sessions.removeAll { $0.id == id }
        if id == currentId {
            // The current session was deleted — re-establish one so the invariant (always a current)
            // holds and `logEvent`/`notePlayed` keep working.
            currentId = ""
            startNewSession(save: false)
        }
        saveNow()
    }

    // MARK: - Internals

    /// Snapshot the live hot buffer back into the current session's value in `sessions`, optionally
    /// finalizing it. Used on Reset and inside every `saveNow` snapshot.
    private func foldCurrentIntoSessions(endedAt: Double?) {
        guard let i = sessions.firstIndex(where: { $0.id == currentId }) else { return }
        sessions[i].events = recEvents
        sessions[i].playedSongIds = recPlayed
        sessions[i].startedAt = recStartedAt
        if let endedAt { sessions[i].endedAt = endedAt }
    }

    private func startNewSession(save: Bool) {
        counter += 1
        let s = MixSession(id: "mses_\(UUID().uuidString.prefix(12))", name: "Session \(counter)",
                           startedAt: nowMs, endedAt: nil, events: [], playedSongIds: [])
        sessions.append(s)
        currentId = s.id
        currentName = s.name
        recEvents = []
        recPlayed = []
        recStartedAt = s.startedAt
        recSeq = 0
        hasActivity = false
        resumePendingReanchor = false   // a fresh session never carries the resume rebase flag
        if save { saveNow() }
    }

    /// A document snapshot with the live current-session buffer folded in (without mutating the
    /// observed `sessions` array — so saving never invalidates the live Mix UI).
    private func snapshotDocument() -> MixSessionsDocument {
        let folded = sessions.map { s -> MixSession in
            guard s.id == currentId else { return s }
            var c = s
            c.events = recEvents
            c.playedSongIds = recPlayed
            c.startedAt = recStartedAt
            return c
        }
        return MixSessionsDocument(schemaVersion: mixSessionsSchemaVersion,
                                   sessions: folded, currentId: currentId, counter: counter)
    }

    /// Debounced save for the high-frequency continuous stream (~0.6 s of quiescence).
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Re-decode the on-disk document after CloudSyncService pulled a newer cloud copy
    /// (whole-document LWW). Mirrors init's resume logic — the pass runs at launch /
    /// foreground, when the pulled current session should resume exactly as init would
    /// have. Guarded: an actively-recording session is never clobbered mid-take (the
    /// local file would be newer than the cloud copy in that case anyway).
    func reloadFromDisk() {
        guard !hasActivity || recEvents.isEmpty else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(MixSessionsDocument.self, from: data) else { return }
        sessions = doc.sessions
        counter = doc.counter
        if let cid = doc.currentId, let cur = sessions.first(where: { $0.id == cid }) {
            currentId = cur.id
            currentName = cur.name
            recEvents = cur.events
            recPlayed = cur.playedSongIds
            recStartedAt = cur.startedAt
            recSeq = cur.events.count
            hasActivity = !cur.events.isEmpty
            resumePendingReanchor = hasActivity
        } else if currentId.isEmpty || !sessions.contains(where: { $0.id == currentId }) {
            startNewSession(save: false)
        }
        playedRevision &+= 1
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

    /// Force-persist now (scene → background). Writes SYNCHRONOUSLY (encode + atomic write inline) so
    /// an OS suspension right after `.background` can't drop the latest events — then advances the
    /// writer's version watermark so any in-flight async save carrying an older snapshot can't regress
    /// what we just wrote.
    func flush() {
        // ONBOARDING PULL INVARIANT (R2): never MATERIALIZE the synced document for a
        // virgin state. Init always mints an empty "Session 1" in memory, so a fresh
        // install backgrounded mid-onboarding would otherwise write an empty doc whose
        // fresh mtime out-LWWs the user's real cloud copy on the next push pass (the
        // sibling PlaybackSession/MixDeckSession flushes guard on `current != nil` — this
        // is their equivalent). Once the file exists, or anything is worth keeping,
        // flush exactly as before.
        let virgin = recEvents.isEmpty && recPlayed.isEmpty
            && sessions.allSatisfy { $0.events.isEmpty && $0.playedSongIds.isEmpty }
        if virgin && !FileManager.default.fileExists(atPath: fileURL.path) { return }
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
