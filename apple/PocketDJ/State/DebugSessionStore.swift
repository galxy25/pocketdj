import Foundation

/// Persisted archive of captured debug sessions (Settings ▸ Debug). Each time a capture is
/// stopped, `DebugView` archives the frozen `MixDiag` buffer here so it survives relaunch and
/// several can accumulate — each individually exportable and deletable. Mirrors the
/// `PlayStatsStore` persistence convention: an Application Support directory, a JSON index of
/// metadata, and the full (potentially large) session text in a sibling `<id>.txt` file so
/// launch stays light and export reads on demand.
@MainActor
@Observable
final class DebugSessionStore {
    /// Singleton, like `MixDiag.shared` (the capture buffer it archives). Uses `launchDir()` so
    /// UI-test runs (PDJ_USE_FIXTURE) get an isolated, freshly-cleared directory.
    static let shared = DebugSessionStore(directory: DebugSessionStore.launchDir())

    /// Newest first.
    private(set) var sessions: [DebugSession] = []

    private let dir: URL
    private let indexURL: URL

    /// Metadata for one archived session; the full text lives in `<id>.txt` (see `fileName`).
    struct DebugSession: Identifiable, Codable, Equatable {
        let id: String
        let startedAt: Date
        let endedAt: Date?
        let lineCount: Int
        var fileName: String { "\(id).txt" }
    }

    private struct Document: Codable { var sessions: [DebugSession] }

    init(directory: URL = DebugSessionStore.defaultDir()) {
        self.dir = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            sessions = doc.sessions
        }
    }

    nonisolated static func defaultDir() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("pocketdj-debug-sessions", isDirectory: true)
    }

    /// Under UI tests use an isolated, freshly-cleared directory (deterministic, never touches
    /// the user's real archive). Mirrors `PlayStatsStore.launchURL`.
    nonisolated static func launchDir() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdj-uitest-debug-sessions", isDirectory: true)
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultDir()
    }

    /// Archive a just-frozen capture. Writes `text` to `<id>.txt` and prepends the metadata.
    /// No-ops (returns nil) on an empty capture so a stray toggle never litters the list.
    @discardableResult
    func archive(startedAt: Date, endedAt: Date?, lineCount: Int, text: String) -> DebugSession? {
        guard lineCount > 0 || !text.isEmpty else { return nil }
        // Stable, collision-free id: the end (or start) instant in ms, disambiguated by count.
        let stamp = Int((endedAt ?? startedAt).timeIntervalSince1970 * 1000)
        let session = DebugSession(id: "sess-\(stamp)-\(sessions.count)",
                                   startedAt: startedAt, endedAt: endedAt, lineCount: lineCount)
        do {
            try Data(text.utf8).write(to: dir.appendingPathComponent(session.fileName), options: .atomic)
        } catch {
            return nil   // couldn't write the body → don't record a dangling metadata row
        }
        sessions.insert(session, at: 0)
        save()
        return session
    }

    /// The full text of an archived session (read on demand for export). "" if the file is gone.
    func text(for session: DebugSession) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(session.fileName), encoding: .utf8)) ?? ""
    }

    func delete(_ session: DebugSession) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(session.fileName))
        sessions.removeAll { $0.id == session.id }
        save()
    }

    func deleteAll() {
        for s in sessions {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(s.fileName))
        }
        sessions = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Document(sessions: sessions)) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
