import Foundation

// MARK: - Studio storage families + folder resolution

/// The five Studio artifact FAMILIES, each with its own on-disk root under
/// `Application Support/studio/<family>/` and (for all but instruments) an optional user-picked
/// folder held as a security-scoped bookmark in SettingsStore (spec §3). `rawValue` doubles as
/// the app-managed subdirectory name — never rename a case.
enum StudioFamily: String, CaseIterable, Sendable {
    case samples, loops, sequences, takes, instruments

    /// Samples/loops/sequences/takes are user-relocatable (each has its own folder setting in
    /// Settings ▸ Storage). Instrument packs are ALWAYS app-managed — no bookmark, no ambiguity
    /// about which root a bank resolves against, and the pack-downloader never races a folder
    /// setting change. Takes join the relocatable set by recording into app storage and MOVING to
    /// the user folder on clean finish (so the recorder never holds a scope for the whole take —
    /// `StudioStore.addTakeRelocating`).
    var supportsUserFolder: Bool {
        switch self {
        case .samples, .loops, .sequences, .takes: return true
        case .instruments: return false
        }
    }

    /// Deterministic file-name prefix for this family's artifacts (`sample-`, `loop-`, …).
    /// Families share folders with USER files (a user-picked folder holds whatever the user
    /// keeps there), so names are parsed back by the STRICT `StudioFolders.fileId` — never a
    /// loose prefix match.
    var filePrefix: String {
        switch self {
        case .samples: return "sample-"
        case .loops: return "loop-"
        case .sequences: return "pattern-"
        case .takes: return "take-"
        case .instruments: return "instrument-"
        }
    }

    /// The family's one file extension (loops are LPCM CAF so they loop seamlessly — spec §2;
    /// everything else audio is AAC m4a; instrument banks are SoundFonts).
    var fileExtension: String {
        switch self {
        case .loops: return "caf"
        case .instruments: return "sf2"
        case .samples, .sequences, .takes: return "m4a"
        }
    }

    /// The id namespace embedded in this family's file names (`sample-smp_….m4a`). nil for
    /// instruments, whose files embed a bank SLUG (`instrument-generaluser-gs-2.0.3.sf2`), not a
    /// minted id.
    var idPrefix: String? {
        switch self {
        case .samples: return "smp_"
        case .loops: return "lp_"
        case .sequences: return "ptn_"
        case .takes: return "tk_"
        case .instruments: return nil
        }
    }
}

/// Resolves the on-disk FOLDER for each Studio artifact family — `SessionFolders` generalized
/// (spec §3): the user-picked security-scoped folder when the family supports one and its
/// bookmark resolves, else the app-managed `Application Support/studio/<family>/` dir. Files
/// live FLAT in the family folder under deterministic names (`sample-<id>.m4a`, …).
///
/// Pure static helpers taking the bookmark `Data?` directly (not the whole SettingsStore), so
/// they can run without hopping the main actor. A stale-but-resolvable bookmark is used as-is
/// for THIS call, and a fresh bookmark is minted inside the live scope and handed to
/// `onStaleBookmark` so the app can re-persist it IMMEDIATELY (the S6 lesson: an un-persisted
/// re-mint silently orphans every user-folder artifact on quit).
enum StudioFolders {

    /// Stale-bookmark refresh seam: when a family's bookmark resolves but reports STALE, fresh
    /// bookmark data is minted inside the live security scope and handed here with its family;
    /// the app persists it back into the matching SettingsStore field AND calls
    /// `settings.persist()` immediately. Wired once at app init; nil in tests.
    nonisolated(unsafe) static var onStaleBookmark: ((StudioFamily, Data) -> Void)?

    /// TEST SEAM: overrides the BASE the app-managed family roots live under (tests point it at
    /// a temp dir so usage/delete/reconcile tests can never touch this machine's real studio
    /// content). nil in production; only tests set it (before any concurrent use).
    nonisolated(unsafe) static var appRootOverride: URL?

    /// App-managed root for one family: `Application Support/studio/<family>/` (created on
    /// demand). Mirrors `SessionFolders.appRoot` with a per-family subdir.
    static func appRoot(_ family: StudioFamily) throws -> URL {
        let base: URL
        if let dir = appRootOverride {
            base = dir
        } else {
            let sup = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            base = sup.appendingPathComponent("studio", isDirectory: true)
        }
        let dir = base.appendingPathComponent(family.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolve a family's ACTIVE root. Returns the dir, whether a security scope was started
    /// (caller must stop it), and whether it's the user-picked folder. Falls back to the
    /// app-managed root on ANY problem (denied / unmounted / not writable / bad bookmark) so a
    /// write never targets an inaccessible path. `requireWritable` gates on writability on the
    /// WRITE path ONLY — read/playback paths pass false, because an offline-but-readable
    /// provider folder (e.g. offline iCloud Drive) must still satisfy a read (gating reads on
    /// writability was a real "burned songs won't play" bug — BurnStore's lesson).
    /// Instruments are always app-managed: a bookmark passed for them is a caller bug (asserted)
    /// and ignored.
    static func resolveRoot(family: StudioFamily, bookmark: Data?, requireWritable: Bool)
        -> (url: URL, scoped: Bool, isUserFolder: Bool)? {
        assert(bookmark == nil || family.supportsUserFolder,
               "instrument packs are always app-managed — no bookmark applies")
        if family.supportsUserFolder, let data = bookmark {
            var stale = false
            #if os(macOS)
            let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let opts: URL.BookmarkResolutionOptions = []
            #endif
            if let url = try? URL(resolvingBookmarkData: data, options: opts,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let ok = url.startAccessingSecurityScopedResource()
                if ok, stale {
                    // Mint the replacement INSIDE the live scope (bookmark creation needs
                    // access); BurnStore.makeBookmark owns the per-platform options.
                    if let fresh = BurnStore.makeBookmark(for: url) {
                        onStaleBookmark?(family, fresh)
                    }
                }
                if ok && (!requireWritable || FileManager.default.isWritableFile(atPath: url.path)) {
                    return (url, true, true)
                }
                if ok { url.stopAccessingSecurityScopedResource() }   // resolved but unusable
            }
        }
        return (try? appRoot(family)).map { ($0, false, false) }
    }

    /// A family's ACTIVE folder for a WRITE (or a read when `requireWritable: false`), with the
    /// scope-release closure convention every caller pairs (nil for app storage). The writer
    /// stamps the returned `isUserFolder` onto its artifact record (`wasUserFolder`) so the file
    /// forever resolves against the root it was actually written to.
    static func folder(_ family: StudioFamily, bookmark: Data?, requireWritable: Bool = true)
        -> (url: URL, release: (() -> Void)?, isUserFolder: Bool)? {
        guard let root = resolveRoot(family: family, bookmark: bookmark,
                                     requireWritable: requireWritable) else { return nil }
        let release: (() -> Void)? = root.scoped ? { root.url.stopAccessingSecurityScopedResource() } : nil
        return (root.url, release, root.isUserFolder)
    }

    /// Resolve an artifact file for READING/PLAYBACK. `wasUserFolder` picks the root the file
    /// was actually WRITTEN to (never assuming the current setting). Returns the url + a
    /// scope-release closure the consumer calls when done (nil for app storage) — the scope is
    /// KEPT OPEN because releasing before playback yields a silent 0:00/no-audio (the
    /// `localURLForPlayback` lesson). nil when the file is gone or the user folder that held it
    /// is currently unreachable.
    static func fileURL(family: StudioFamily, fileName: String, wasUserFolder: Bool, bookmark: Data?)
        -> (url: URL, release: (() -> Void)?)? {
        // A persisted file name is a bare name inside the family folder — a path separator means
        // a corrupt/hostile document, never a file this app wrote.
        guard !fileName.isEmpty, !fileName.contains("/") else { return nil }
        let root: (url: URL, scoped: Bool, isUserFolder: Bool)?
        if wasUserFolder {
            root = resolveRoot(family: family, bookmark: bookmark, requireWritable: false)
            guard root?.isUserFolder == true else { return nil }   // user folder gone → can't resolve
        } else {
            root = (try? appRoot(family)).map { ($0, false, false) }
        }
        guard let r = root else { return nil }
        let url = r.url.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if r.scoped { r.url.stopAccessingSecurityScopedResource() }   // missing → don't leak scope
            return nil
        }
        return (url, r.scoped ? { r.url.stopAccessingSecurityScopedResource() } : nil)
    }

    /// Visit each possible root for a family once — the app-managed dir, then the user-picked
    /// folder (when the family supports one and its bookmark resolves) with `isUserFolder: true`
    /// — holding the security scope around the visit. The usage/delete-all seam (mirrors
    /// `BurnStore.forEachBurnRoot`).
    static func forEachRoot(family: StudioFamily, bookmark: Data?,
                            _ body: (URL, _ isUserFolder: Bool) -> Void) {
        var visited = Set<String>()
        if let app = try? appRoot(family), visited.insert(app.path).inserted { body(app, false) }
        guard family.supportsUserFolder, bookmark != nil,
              let user = resolveRoot(family: family, bookmark: bookmark, requireWritable: false),
              user.isUserFolder else { return }
        defer { if user.scoped { user.url.stopAccessingSecurityScopedResource() } }
        if visited.insert(user.url.path).inserted { body(user.url, true) }
    }

    // MARK: Deterministic names (mint + STRICT parse)

    /// The canonical file name for one artifact: `<prefix><id>.<ext>` (`sample-smp_….m4a`,
    /// `loop-lp_….caf`, `pattern-ptn_….m4a`, `take-tk_….m4a`, `instrument-<slug>.sf2`). The ONE
    /// minting point, so writer agents and the parser below can never drift.
    static func fileName(_ family: StudioFamily, id: String) -> String {
        family.filePrefix + id + "." + family.fileExtension
    }

    /// The RENDER-CACHE name for a sample (edits baked): the raw name plus a `-r<revision>`
    /// stamp, so freshness is literal (the cache for revision N is a different file than for
    /// N+1, and a crashed re-render can never leave a fresh-looking stale file). Parsed back by
    /// `fileId` — `r` is not a hex digit, so the stamp can never be confused with uuid content.
    static func renderedSampleFileName(id: String, revision: Int) -> String {
        "sample-\(id)-r\(revision).m4a"
    }

    /// STRICT parser: the id embedded in a family artifact's file name, or nil when `name` is
    /// not EXACTLY this family's deterministic shape. Loose prefix matches are forbidden —
    /// user files share these folders (spec §3), so `sample-of-my-mix.m4a` in a user's samples
    /// folder must never parse. Rules:
    ///   • `<prefix><id>.<ext>` with the family's exact prefix + extension;
    ///   • the embedded id must carry the family's minted id namespace (`smp_`/`lp_`/…) and be
    ///     non-empty past it — for instruments (no namespace) any non-empty slug parses, which
    ///     is safe because that family is ALWAYS app-managed (the dir is app-private);
    ///   • a samples name may carry the render-cache `-r<digits>` stamp, which is stripped
    ///     (both the raw file and its caches attribute to the same sample id).
    static func fileId(family: StudioFamily, name: String) -> String? {
        let suffix = "." + family.fileExtension
        guard name.hasPrefix(family.filePrefix), name.hasSuffix(suffix), !name.contains("/") else { return nil }
        var core = String(name.dropFirst(family.filePrefix.count).dropLast(suffix.count))
        guard let idPrefix = family.idPrefix else {
            return core.isEmpty ? nil : core          // instruments: the bank slug
        }
        if family == .samples,
           let r = core.range(of: "-r", options: .backwards),
           r.upperBound < core.endIndex,
           core[r.upperBound...].allSatisfy({ $0.isNumber }) {
            core = String(core[..<r.lowerBound])      // strip the render-cache revision stamp
        }
        guard core.hasPrefix(idPrefix), core.count > idPrefix.count else { return nil }
        return core
    }

    // MARK: Usage

    /// Total on-disk bytes of one family's artifacts across both roots. Counts ONLY files whose
    /// name parses under the STRICT `fileId` shape; in the USER root the parsed id must
    /// additionally be document-known when `knownIds` is provided (the `BurnStore.ownsAuxFile`
    /// discipline — a user's own coincidentally-shaped file is never counted; the app root is
    /// app-private, so shape alone suffices there).
    static func usageBytes(family: StudioFamily, bookmark: Data?, knownIds: Set<String>? = nil) -> Int {
        var total = 0
        let fm = FileManager.default
        forEachRoot(family: family, bookmark: bookmark) { root, isUserFolder in
            let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            for n in names {
                guard let id = fileId(family: family, name: n) else { continue }
                if isUserFolder, let known = knownIds, !known.contains(id) { continue }
                let path = root.appendingPathComponent(n).path
                if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int {
                    total += size
                }
            }
        }
        return total
    }
}
