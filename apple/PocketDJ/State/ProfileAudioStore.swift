import Foundation

/// Stage 3 — the DEVICE-LOCAL durable audio layer behind the "Pocket DJ" profile source.
///
/// A saved profile item keeps its ORIGINAL full-mix (the PRIMARY asset — always playable) plus,
/// when available, its 4 stems (progressive enhancement). All app-managed under Application
/// Support (never a user-picked folder, so playback resolves with NO security scope to hold), and
/// deliberately EXCLUDED from CloudKit — only the `ProfileSourceStore` metadata syncs. A record
/// therefore legitimately exists on a fresh device with no local file: that's not an orphan, it's
/// the sync design, so there is NO launch prune — the Browser device-local gate (Stage 6,
/// `hasLocalAsset`) hides an asset-absent item, and playback resolving to nil skips the row.
///
/// Layout (deterministic from the item's `pdj_` id):
///   profile-audio/<songId>.<ext>            — the original (bare name stored in SongEntry.fileName)
///   profile-audio/stems/<songId>/<stem>.<ext> — optional stems, one folder per item
///
/// The filesystem machinery lives in the stateless `ProfileAudioFolders` (mirroring `StudioFolders`
/// / `StudioStore.arrangementsDir`); the record-aware ingest/resolve methods are an
/// `extension ProfileSourceStore` (the store owns the records, exactly like `StudioStore`'s clip
/// resolvers). See [[profile-custom-audio-source-program]].
enum ProfileAudioFolders {
    /// Test seam — mirrors `StudioFolders.appRootOverride`; when set, everything lands under it so
    /// tests never touch this machine's real profile audio (PDJ_USE_FIXTURE-friendly).
    nonisolated(unsafe) static var rootOverride: URL?

    /// The app-managed root `…/profile-audio/` (created on demand). Mirrors `arrangementsDir()`.
    static func dir() throws -> URL {
        let base: URL
        if let o = rootOverride {
            base = o
        } else {
            base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        }
        let dir = base.appendingPathComponent("profile-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The per-item stems folder `…/profile-audio/stems/<songId>/` (path only — NOT created here;
    /// `ingest` creates it before writing). `songId` is sanitized defensively though `pdj_` ids
    /// carry no path separators.
    static func stemsDir(songId: String) throws -> URL {
        let safe = songId.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        return try dir().appendingPathComponent("stems", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
    }

    /// Resolve the ORIGINAL for reading/playback (nil when gone). Bare name only — a path separator
    /// or empty name means a corrupt/hostile (CloudKit-ridden) `fileName`, never one this app wrote.
    static func resolveOriginal(fileName: String) -> URL? {
        // Bare name only: reject empty, path separators, AND the "."/".." traversals (no "/" but they
        // resolve to the dir / its PARENT). A hostile/corrupt synced fileName must never let
        // resolve/hasLocalAsset/deleteAsset escape profile-audio/. The app only writes pdj_<uuid>.<ext>.
        guard !fileName.isEmpty, !fileName.contains("/"), fileName != ".", fileName != "..",
              let dir = try? dir() else { return nil }
        let url = dir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The four stem files for an item, or nil if ANY is missing (all-or-nothing, extension-agnostic
    /// basename match — the `DemuxStore.localStemURLs` contract, so mp3/caf/flac all resolve).
    static func resolveStems(songId: String) -> [String: URL]? {
        guard let sdir = try? stemsDir(songId: songId),
              let listing = try? FileManager.default.contentsOfDirectory(at: sdir, includingPropertiesForKeys: nil)
        else { return nil }
        var urls: [String: URL] = [:]
        for name in StemPlayer.stems {
            guard let f = listing.first(where: { $0.deletingPathExtension().lastPathComponent == name }) else { return nil }
            urls[name] = f
        }
        return urls
    }
}

extension ProfileSourceStore {

    /// The metadata record for a profile id (nil for a non-profile / unknown id).
    func entry(_ id: String) -> SongEntry? { songs.first { $0.songId == id } }

    /// Persist custom audio as a NEW profile item: WRITE-FILE-FIRST (own the bytes — the caller's
    /// source may be a purgeable Sampler/Demuxer cache), THEN file the record. The ORIGINAL is
    /// copied BYTE-EXACT (never transcoded — "keeps its original full-mix"). Stems are optional and
    /// all-or-nothing: any partial-copy failure removes the whole stems subdir so `resolveStems`
    /// never reports a half-set. The file work runs OFF the main actor. Returns nil on copy failure.
    func ingest(kind: Kind, title: String, originalURL: URL, durationMs: Int? = nil,
                stems: [String: URL]? = nil, bpm: Double? = nil,
                key: String? = nil, camelot: String? = nil) async -> SongEntry? {
        let id = ProfileSourceStore.songIdPrefix + UUID().uuidString.lowercased()
        let ext = originalURL.pathExtension.isEmpty ? "m4a" : originalURL.pathExtension
        let fileName = "\(id).\(ext)"
        let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let dir = try? ProfileAudioFolders.dir() else { return false }
            let dest = dir.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: originalURL, to: dest) } catch { return false }
            guard let stems else { return true }
            guard let sdir = try? ProfileAudioFolders.stemsDir(songId: id) else {
                try? FileManager.default.removeItem(at: dest); return false
            }
            do { try FileManager.default.createDirectory(at: sdir, withIntermediateDirectories: true) }
            catch { try? FileManager.default.removeItem(at: dest); return false }
            for name in StemPlayer.stems {
                let cleanup = { try? FileManager.default.removeItem(at: sdir); try? FileManager.default.removeItem(at: dest) }
                guard let src = stems[name] else { cleanup(); return false }
                let sext = src.pathExtension.isEmpty ? "m4a" : src.pathExtension
                let sdest = sdir.appendingPathComponent("\(name).\(sext)")
                do { try FileManager.default.copyItem(at: src, to: sdest) } catch { cleanup(); return false }
            }
            return true
        }.value
        guard ok else { return nil }
        let entry = SongEntry(songId: id, title: title, kind: kind, fileName: fileName,
                              durationMs: durationMs, bpm: bpm, key: key, camelot: camelot,
                              addedAtMs: Date().timeIntervalSince1970 * 1000)
        add([entry])
        return entry
    }

    /// The profileResolve seam's implementation: id → (local original URL, release, title, lengthMs).
    /// `release` is ALWAYS nil (app-managed audio holds no security scope). nil when not a profile
    /// id, unknown, or the local file is absent (accepted — playback skips forward, Browser hides).
    func localURLForPlayback(id: String) -> (url: URL, release: (() -> Void)?, title: String, lengthMs: Int)? {
        guard ProfileSourceStore.isProfileSongId(id), let e = entry(id),
              let url = ProfileAudioFolders.resolveOriginal(fileName: e.fileName) else { return nil }
        return (url, nil, e.title, e.durationMs ?? 0)
    }

    /// The item's 4 stems if all present on this device, else nil (Stage 7 gates the stem affordance
    /// on this).
    func stemURLs(id: String) -> [String: URL]? { ProfileAudioFolders.resolveStems(songId: id) }

    /// Whether the item's ORIGINAL asset is on THIS device (the Stage-6 Browser visibility gate).
    func hasLocalAsset(_ id: String) -> Bool {
        guard let e = entry(id) else { return false }
        return ProfileAudioFolders.resolveOriginal(fileName: e.fileName) != nil
    }

    /// Delete an item's on-disk audio (original + stems) AND its record.
    func deleteAsset(id: String) {
        if let e = entry(id), let url = ProfileAudioFolders.resolveOriginal(fileName: e.fileName) {
            try? FileManager.default.removeItem(at: url)
        }
        if let sdir = try? ProfileAudioFolders.stemsDir(songId: id) {
            try? FileManager.default.removeItem(at: sdir)
        }
        remove(songIds: [id])
    }
}
