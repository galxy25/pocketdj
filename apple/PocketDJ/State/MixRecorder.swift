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

    // The in-flight take, captured at start so a Reset mid-capture still files it against its session.
    @ObservationIgnored private var recSessionId = ""
    @ObservationIgnored private var recFileName = ""
    @ObservationIgnored private var recWasUserFolder = false

    init(engine: MixEngine, sessions: MixSessionStore) {
        self.engine = engine
        self.sessions = sessions
    }

    /// Toggle capture (what the record button calls).
    func toggle() { if isRecording { stop() } else { start() } }

    /// The in-flight take (session id + file name) while recording — the storage manager's
    /// delete-all skips this open file. nil when idle.
    var activeTake: (sessionId: String, fileName: String)? {
        isRecording ? (recSessionId, recFileName) : nil
    }

    @ObservationIgnored private var didScanOrphans = false

    /// One-shot on launch: re-file any recording FILE on disk that isn't referenced by a session's
    /// `recordings[]` — e.g. a take interrupted by a crash (metadata is filed only on a clean stop, but
    /// the fragmented `.m4a` survives). Each session folder is named by its session id, so an orphan is
    /// re-homed to its own session (revived if that session is gone). Safe + idempotent (skips files
    /// already recorded), so repeated launches don't duplicate.
    func recoverOrphans() {
        guard !didScanOrphans else { return }
        didScanOrphans = true
        let fm = FileManager.default
        var roots: [(url: URL, isUser: Bool, release: (() -> Void)?)] = []
        if let app = try? SessionFolders.appRoot() { roots.append((app, false, nil)) }
        if let user = SessionFolders.resolveRoot(bookmark: settings?.sessionFolderBookmark, requireWritable: false),
           user.isUserFolder {
            roots.append((user.url, true, user.scoped ? { user.url.stopAccessingSecurityScopedResource() } : nil))
        }
        for root in roots {
            defer { root.release?() }
            let dirs = (try? fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let sessionId = dir.lastPathComponent
                let known = Set(sessions.recordings(forSession: sessionId).map { $0.fileName })
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
                for file in files where file.pathExtension.lowercased() == "m4a" && !known.contains(file.lastPathComponent) {
                    var durMs = 0
                    if let af = try? AVAudioFile(forReading: file) {
                        let sr = af.processingFormat.sampleRate
                        if sr > 0 { durMs = Int(Double(af.length) / sr * 1000) }
                    }
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
        // Human-readable, stable take name (next number in this session's folder).
        let seq = sessions.recordings(forSession: sessionId).count + 1
        let fileName = "recording-\(seq).m4a"
        let url = folder.url.appendingPathComponent(fileName)
        // `startRecording` OWNS `folder.release` (drops it on failure OR on stop) — never release here.
        guard engine.startRecording(to: url, release: folder.release) else { return false }
        recSessionId = sessionId
        recFileName = fileName
        recWasUserFolder = folder.isUserFolder
        startedAtMs = Date().timeIntervalSince1970 * 1000
        isRecording = true
        return true
    }

    /// Stop capture + file the take's metadata onto its session. No-op if not recording.
    func stop() {
        guard isRecording else { return }
        engine.stopRecording()
        isRecording = false
        let durationMs = max(0, Int(Date().timeIntervalSince1970 * 1000 - startedAtMs))
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
}
