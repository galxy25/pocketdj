import Foundation

/// Resolves the on-disk FOLDER for a mix session — one subfolder per session that holds its captured
/// audio (and future per-session data). Mirrors `BurnStore.resolveBurnFolder`: the user-picked
/// security-scoped folder (`settings.sessionFolderBookmark`) when set + writable, else the app-managed
/// Application Support `mix-sessions/` dir. Callers that keep the folder open for a WRITE (a recording
/// capture) or READ (playback) must call the returned `release` when done to drop the security scope.
///
/// Pure static helpers taking the bookmark `Data?` directly (not the whole SettingsStore), so they can
/// run without hopping the main actor. A stale-but-resolvable bookmark is used as-is (re-persist is
/// only an optimization; skipping it keeps this dependency-free).
enum SessionFolders {

    /// App-managed root: Application Support/mix-sessions/ (created on demand). Mirrors
    /// `RipsStore.burnsDirectory()` but under `mix-sessions/`.
    static func appRoot() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("mix-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolve the ACTIVE session-folder ROOT. Returns the dir, whether a security scope was started
    /// (caller must stop it via the folder's `release`), and whether it's the user-picked folder.
    /// Falls back to app storage on ANY problem (denied / unmounted / not writable) so a capture never
    /// targets an inaccessible path. `requireWritable` gates on writability (WRITE path only; a
    /// read/playback path passes false so an offline-but-readable provider folder still resolves).
    static func resolveRoot(bookmark: Data?, requireWritable: Bool)
        -> (url: URL, scoped: Bool, isUserFolder: Bool)? {
        if let data = bookmark {
            var stale = false
            #if os(macOS)
            let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let opts: URL.BookmarkResolutionOptions = []
            #endif
            if let url = try? URL(resolvingBookmarkData: data, options: opts,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let ok = url.startAccessingSecurityScopedResource()
                if ok && (!requireWritable || FileManager.default.isWritableFile(atPath: url.path)) {
                    return (url, true, true)
                }
                if ok { url.stopAccessingSecurityScopedResource() }   // resolved but unusable
            }
        }
        return (try? appRoot()).map { ($0, false, false) }
    }

    /// The folder for ONE session (`<root>/<sessionId>/`), created when `create`. Returns the folder,
    /// a scope-release closure to call when done (nil for app storage), and whether it's the user
    /// folder (⇒ persisted onto each recording so it later resolves from the same place). On a create
    /// failure the scope is dropped and nil is returned (so a capture never leaks a scope).
    static func sessionFolder(_ sessionId: String, bookmark: Data?, create: Bool = true)
        -> (url: URL, release: (() -> Void)?, isUserFolder: Bool)? {
        guard !sessionId.isEmpty,
              let root = resolveRoot(bookmark: bookmark, requireWritable: create) else { return nil }
        let dir = root.url.appendingPathComponent(sessionId, isDirectory: true)
        if create {
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch {
                if root.scoped { root.url.stopAccessingSecurityScopedResource() }
                return nil
            }
        }
        let release: (() -> Void)? = root.scoped ? { root.url.stopAccessingSecurityScopedResource() } : nil
        return (dir, release, root.isUserFolder)
    }

    /// Resolve a recording's file URL for PLAYBACK (read-only). `wasUserFolder` picks the root the file
    /// was actually written to (never assuming the current setting). Returns the url + a scope-release
    /// closure (nil for app storage / on any miss). nil when the file is gone or the user folder that
    /// held it is no longer available.
    static func recordingURL(sessionId: String, fileName: String, wasUserFolder: Bool, bookmark: Data?)
        -> (url: URL, release: (() -> Void)?)? {
        let root: (url: URL, scoped: Bool, isUserFolder: Bool)?
        if wasUserFolder {
            root = resolveRoot(bookmark: bookmark, requireWritable: false)
            guard root?.isUserFolder == true else { return nil }   // user folder gone → can't resolve
        } else {
            root = (try? appRoot()).map { ($0, false, false) }
        }
        guard let r = root else { return nil }
        let url = r.url.appendingPathComponent(sessionId, isDirectory: true).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if r.scoped { r.url.stopAccessingSecurityScopedResource() }   // missing → don't leak scope
            return nil
        }
        return (url, r.scoped ? { r.url.stopAccessingSecurityScopedResource() } : nil)
    }
}
