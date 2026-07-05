import Foundation
import Observation
import AVFoundation

/// App-scoped coordinator for mix AUDIO recording. Bridges the (catalog/settings-agnostic) `MixEngine`
/// audio tap to the session store + on-disk session folder: it resolves the current session's folder,
/// opens a recording file, drives `MixEngine.startRecording`/`stopRecording`, and files the finished
/// take's metadata onto the session that was current when capture BEGAN (so a Reset mid-capture still
/// files it correctly).
///
/// App-scoped (like `MixEngine`) so a recording keeps running across Mix-tab switches; the UI just
/// reads `isRecording` + `startedAtMs` (the elapsed time is computed view-side from `startedAtMs`).
@MainActor
@Observable
final class MixRecorder {
    @ObservationIgnored private let engine: MixEngine
    @ObservationIgnored private let sessions: MixSessionStore
    /// Source of the session-folder bookmark. Pushed in from the view layer (like the engine's cue /
    /// beat-pulse settings) so this never has to be wired at app-init time. Weak ⇒ no retain of the
    /// app graph.
    @ObservationIgnored weak var settings: SettingsStore?

    /// True while a capture is running (drives the pulsing record button + the in-content indicator).
    private(set) var isRecording = false
    /// Epoch ms when the current capture began (the view derives the elapsed clock from this).
    private(set) var startedAtMs: Double = 0
    /// True while a capture is running but no MEDIA has been appended for several seconds even
    /// though the mix is audible — the engine watchdogs are trying to bring audio back; the record
    /// UI shows a warning state instead of pulsing over a silently dead take.
    private(set) var captureStalled = false
    /// Set when a take was auto-stopped because its writer died (disk full / session folder
    /// vanished). The Mix view surfaces it once as an alert and clears it.
    var writerFailureMessage: String?

    // The in-flight take, captured at start so a Reset mid-capture still files it against its session.
    @ObservationIgnored private var recSessionId = ""
    @ObservationIgnored private var recFileName = ""
    @ObservationIgnored private var recWasUserFolder = false
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?

    init(engine: MixEngine, sessions: MixSessionStore) {
        self.engine = engine
        self.sessions = sessions
        // Writer death mid-take → auto-stop + FILE the partial take (its fragments up to the
        // failure are durable). Without this the sink drops every later buffer while the UI keeps
        // pulsing "recording" — the unbounded silent-loss hole.
        engine.onRecordingFailed = { [weak self] in self?.writerDidFail() }
    }

    /// The take's writer died permanently. Stop + file what was captured, and tell the UI why.
    private func writerDidFail() {
        guard isRecording else { return }
        writerFailureMessage = "Recording stopped: the take couldn't keep writing (low disk space "
            + "or the session folder became unavailable). The audio captured so far was saved."
        stop()
    }

    /// Toggle capture (what the record button calls).
    func toggle() { if isRecording { stop() } else { start() } }

    /// The in-flight take (session id + file name) while recording — the storage manager's
    /// delete-all skips this open file. nil when idle.
    var activeTake: (sessionId: String, fileName: String)? {
        isRecording ? (recSessionId, recFileName) : nil
    }

    // Per-ROOT scan latches: each root is scanned once per launch, but a root that FAILS TO
    // RESOLVE (user folder offline / stale bookmark / settings not wired yet) is retried on the
    // next call instead of being latched off for the whole launch — the old single latch silently
    // skipped a momentarily-offline user folder forever.
    @ObservationIgnored private var scannedAppRoot = false
    @ObservationIgnored private var scannedUserRoot = false

    /// Re-file any recording FILE on disk that isn't referenced by a session's `recordings[]` —
    /// e.g. a take interrupted by a crash (metadata is filed only on a clean stop, but the
    /// fragmented `.m4a` survives). Each session folder is named by its session id, so an orphan is
    /// re-homed to its own session (revived if that session is gone). Safe + idempotent (skips
    /// files already recorded), so repeated calls don't duplicate. Runs at LAUNCH (RootView's
    /// task — a crashed take must reappear no matter which tab the app restores into), again when
    /// the Mix tab opens, and before the Storage recordings sweep.
    func recoverOrphans() {
        let fm = FileManager.default
        var roots: [(url: URL, isUser: Bool, release: (() -> Void)?)] = []
        if !scannedAppRoot, let app = try? SessionFolders.appRoot() {
            scannedAppRoot = true
            roots.append((app, false, nil))
        }
        if !scannedUserRoot, let bookmark = settings?.sessionFolderBookmark,
           let user = SessionFolders.resolveRoot(bookmark: bookmark, requireWritable: false),
           user.isUserFolder {
            scannedUserRoot = true
            roots.append((user.url, true, user.scoped ? { user.url.stopAccessingSecurityScopedResource() } : nil))
        }
        for root in roots {
            defer { root.release?() }
            let dirs = (try? fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let sessionId = dir.lastPathComponent
                // Only app-named session folders (every real session id is "mses_…"). A
                // user-picked root may hold the user's OWN subfolders of audio — adopting
                // those as "recordings" would later mark them deletable in-app.
                guard sessionId.hasPrefix("mses_") else { continue }
                let known = Set(sessions.recordings(forSession: sessionId).map { $0.fileName })
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
                for file in files where file.pathExtension.lowercased() == "m4a" && !known.contains(file.lastPathComponent) {
                    // A take that died before its FIRST fragment (~2 s) is unreadable by every
                    // AVFoundation consumer — filing it would create a dead "0:00" row whose play
                    // button silently no-ops. Leave it on disk unfiled (the recordings sweep
                    // cleans such strays up).
                    guard let af = try? AVAudioFile(forReading: file),
                          af.processingFormat.sampleRate > 0, af.length > 0 else { continue }
                    let durMs = Int(Double(af.length) / af.processingFormat.sampleRate * 1000)
                    let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                    let started = (created?.timeIntervalSince1970 ?? 0) * 1000
                    sessions.recoverRecording(sessionId: sessionId, name: "Recovered recording",
                                              fileName: file.lastPathComponent, startedAt: started,
                                              durationMs: durMs, wasUserFolder: root.isUser)
                }
            }
        }
    }

    /// Begin capturing the mixed output into the current session's folder. No-op (returns false) if
    /// already recording or the folder / file can't be opened.
    @discardableResult
    func start() -> Bool {
        guard !isRecording else { return false }
        let sessionId = sessions.currentId
        guard !sessionId.isEmpty,
              let folder = SessionFolders.sessionFolder(sessionId, bookmark: settings?.sessionFolderBookmark)
        else { return false }
        // Human-readable, stable take name (next number in this session's folder) —
        // bumped past any file already on disk: a take kept while its metadata was
        // cleared (Storage ▸ delete recordings during a capture) or a crash orphan
        // would otherwise be TRUNCATED by an AVAudioFile open at the same name.
        var seq = sessions.recordings(forSession: sessionId).count + 1
        while FileManager.default.fileExists(
            atPath: folder.url.appendingPathComponent("recording-\(seq).m4a").path) {
            seq += 1
        }
        let fileName = "recording-\(seq).m4a"
        let url = folder.url.appendingPathComponent(fileName)
        // `startRecording` OWNS `folder.release` (drops it on failure OR on stop) — never release here.
        guard engine.startRecording(to: url, release: folder.release) else { return false }
        recSessionId = sessionId
        recFileName = fileName
        recWasUserFolder = folder.isUserFolder
        startedAtMs = Date().timeIntervalSince1970 * 1000
        isRecording = true
        captureStalled = false
        startWatchdog()
        return true
    }

    /// Stop capture + file the take's metadata onto its session. No-op if not recording.
    func stop() {
        guard isRecording else { return }
        // The take's CONTENT clock, read BEFORE finalize: media seconds actually appended. Wall
        // clock would overstate the take after any stall or drop (frozen tap during a route
        // change, dropped buffers) — the file is the truth. Wall clock stays as the fallback for
        // the degenerate no-media case.
        let contentMs = Int(engine.recordingAppendedSeconds * 1000)
        engine.stopRecording()
        isRecording = false
        captureStalled = false
        watchdogTask?.cancel(); watchdogTask = nil
        let wallMs = max(0, Int(Date().timeIntervalSince1970 * 1000 - startedAtMs))
        let durationMs = contentMs > 0 ? contentMs : wallMs
        // Normal case: the originating session still exists → attach the take.
        if sessions.addRecording(toSession: recSessionId, fileName: recFileName, startedAt: startedAtMs,
                                 durationMs: durationMs, wasUserFolder: recWasUserFolder) != nil {
            return
        }
        // The originating session was DELETED mid-capture — the audio still lives on disk under its
        // folder, so revive that session id (no file move) to keep the take instead of orphaning it.
        sessions.recoverRecording(sessionId: recSessionId, name: "Recovered recording",
                                  fileName: recFileName, startedAt: startedAtMs,
                                  durationMs: durationMs, wasUserFolder: recWasUserFolder)
    }

    /// Capture-liveness watchdog: while recording, appended MEDIA time must keep advancing whenever
    /// the mix is audible. A ≥5 s freeze (engine stalled and unrecovered, tap detached) flips
    /// `captureStalled` so the record UI warns instead of silently pulsing over a dead take. Clears
    /// itself the moment media flows again. Deliberately does NOT auto-stop: a stall during an
    /// interruption pause is a take the user wants to continue, and definitive writer death already
    /// auto-stops via `onRecordingFailed`.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            var lastAppended = -1.0
            var stagnantSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.isRecording else { break }
                let appended = self.engine.recordingAppendedSeconds
                let mixAudible = self.engine.isRunning          // any deck playing
                if appended > lastAppended + 0.01 || !mixAudible {
                    stagnantSince = nil
                    self.captureStalled = false
                } else if let since = stagnantSince {
                    if Date().timeIntervalSince(since) >= 5 { self.captureStalled = true }
                } else {
                    stagnantSince = Date()
                }
                lastAppended = appended
            }
        }
    }
}
