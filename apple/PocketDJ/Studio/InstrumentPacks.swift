import Foundation
import Observation
import CryptoKit          // SHA-256 verify of downloaded banks (spec §6: mismatch deletes + fails)
import os                 // mixdiag Logger — pack download diagnostics ride the same subsystem

// MARK: - Instrument-pack manifest (rips/instruments/index.json — spec §6)
//
// {version, attribution, sharedBanks: [{key, bytes, sha256}],
//  packs: [{id, name, instrument, program, bankKey, bytes}]}
//
// v1 ships seven packs (one per `InstrumentKey`) all referencing ONE shared 32 MB GM bank
// (GeneralUser GS); the manifest supports per-pack banks later. Decoding follows the studio
// schema doctrine (StudioModels.swift header): every FIELD decodes leniently, every LIST decodes
// per-element lossily — a future manifest's unknown instrument drops that PACK only, never the
// list or the document, so an old build keeps listing the packs it understands.

/// Decodes ONE list element, swallowing its failure (the StudioModels lossy-box shape, private
/// there so re-declared here). An unknown-instrument pack throws in its own `init` and lands
/// here as `nil` — dropped by the compactMap, exactly the "unknown ⇒ skip pack" rule.
private struct PackLossyBox<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// One downloadable SoundFont bank on S3. `key` is relative to `Config.instrumentsBase`
/// (e.g. `banks/generaluser-gs-2.0.3.sf2`) — the same manifest-carries-keys convention as the
/// rips manifest, so the client never invents S3 paths.
struct InstrumentBank: Decodable, Hashable, Sendable {
    /// S3 key relative to the instruments base — also the seed of the LOCAL file name
    /// (`InstrumentPackStore.bankSlug`). Load-bearing: a bank without it is unaddressable.
    var key: String
    /// Advertised size (download UI); 0 when the manifest omits it.
    var bytes: Int
    /// Hex SHA-256 of the bank file — verified after download so a truncated/corrupted 32 MB
    /// transfer can never be handed to the sampler. Empty ⇒ an older manifest without digests;
    /// the install then skips verification (logged) rather than bricking downloads.
    var sha256: String

    enum CodingKeys: String, CodingKey { case key, bytes, sha256 }
    init(key: String, bytes: Int = 0, sha256: String = "") {
        self.key = key; self.bytes = bytes; self.sha256 = sha256
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let key = (try? c.decode(String.self, forKey: .key)) ?? ""
        // No key ⇒ nothing to download or name — throw so the lossy box drops JUST this entry.
        guard !key.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "bank without key"))
        }
        self.key = key
        bytes = (try? c.decode(Int.self, forKey: .bytes)) ?? 0
        sha256 = (try? c.decode(String.self, forKey: .sha256)) ?? ""
    }
}

/// One virtual-instrument pack: an `InstrumentKey` + the GM program to address inside the bank
/// it references. The pack itself is metadata only — downloading a pack downloads its BANK,
/// deduped by `bankKey` (the second pack referencing an already-downloaded bank is instantly
/// "downloaded", spec §6).
struct InstrumentPack: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// Matched to `InstrumentKey.rawValue` at decode; an unknown instrument (a future pack this
    /// build can't play) throws so the lossy list drops the pack — never the manifest.
    var instrument: InstrumentKey
    /// GM program number (0-based) the sampler addresses within the bank. Defaults to the
    /// instrument's locked-in `gmProgram` when the manifest omits it (they agree in v1).
    var program: Int
    /// The shared bank this pack rides (`InstrumentBank.key`). Empty ⇒ listable but not
    /// downloadable (a degraded future manifest) — surfaced as a download error, never a crash.
    var bankKey: String
    /// Advertised download size shown on the pack row (the BANK's size for shared banks).
    var bytes: Int

    enum CodingKeys: String, CodingKey { case id, name, instrument, program, bankKey, bytes }
    init(id: String, name: String, instrument: InstrumentKey, program: Int,
         bankKey: String, bytes: Int = 0) {
        self.id = id; self.name = name; self.instrument = instrument
        self.program = program; self.bankKey = bankKey; self.bytes = bytes
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = (try? c.decode(String.self, forKey: .id)) ?? ""
        let raw = (try? c.decode(String.self, forKey: .instrument)) ?? ""
        // id anchors progress/rows; instrument must be one this build can play. Either missing ⇒
        // skip THIS pack (the reviewed "unknown instrument ⇒ skip pack" rule).
        guard !id.isEmpty, let inst = InstrumentKey(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown/invalid pack"))
        }
        self.id = id
        instrument = inst
        let n = (try? c.decode(String.self, forKey: .name)) ?? ""
        name = n.isEmpty ? inst.displayName : n
        program = (try? c.decode(Int.self, forKey: .program)) ?? Int(inst.gmProgram)
        bankKey = (try? c.decode(String.self, forKey: .bankKey)) ?? ""
        bytes = (try? c.decode(Int.self, forKey: .bytes)) ?? 0
    }
}

/// The whole index document. Lenient + lossy throughout — garbage never throws past here,
/// which also makes "did it decode?" the cache-validation gate (CatalogService discipline:
/// never cache a body that didn't decode).
struct InstrumentPackIndex: Decodable, Sendable {
    var version: Int
    /// Shown on the packs screen — the GeneralUser GS license asks for attribution (spec §6).
    var attribution: String
    var sharedBanks: [InstrumentBank]
    var packs: [InstrumentPack]

    enum CodingKeys: String, CodingKey { case version, attribution, sharedBanks, packs }
    init(version: Int = 0, attribution: String = "", sharedBanks: [InstrumentBank] = [],
         packs: [InstrumentPack] = []) {
        self.version = version; self.attribution = attribution
        self.sharedBanks = sharedBanks; self.packs = packs
    }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        version = (try? c?.decode(Int.self, forKey: .version)) ?? 0
        attribution = (try? c?.decode(String.self, forKey: .attribution)) ?? ""
        sharedBanks = ((try? c?.decode([PackLossyBox<InstrumentBank>].self, forKey: .sharedBanks)) ?? [])
            .compactMap(\.value)
        packs = ((try? c?.decode([PackLossyBox<InstrumentPack>].self, forKey: .packs)) ?? [])
            .compactMap(\.value)
    }
}

/// Pack download failures, surfaced per bank on the pack row.
enum InstrumentPackError: LocalizedError {
    case badResponse          // non-2xx / transport error
    case shaMismatch          // digest didn't match the manifest — corrupt/truncated transfer
    case fileSystem           // couldn't stage/move into the instruments root
    case notDownloadable      // pack has no bankKey (degraded future manifest)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Download failed"
        case .shaMismatch: return "Downloaded file failed verification"
        case .fileSystem: return "Couldn't save the sound bank"
        case .notDownloadable: return "This pack can't be downloaded by this version"
        }
    }
}

// MARK: - Store

/// Instrument-pack client (spec §6): fetches the index like `CatalogService` (network first,
/// explicit Application-Support file cache as the offline fallback — packs stay LISTABLE
/// offline), downloads banks with a file-based `URLSession.downloadTask` (a 32 MB SoundFont
/// must NEVER transit memory as `Data` — the reviewed defect the download shape closes),
/// verifies SHA-256 with CryptoKit, and atomically installs into the ALWAYS-app-managed
/// `studio/instruments/` root (`StudioFolders`, no bookmark — spec §3) under the deterministic
/// name `instrument-<slug>.sf2`. Dedupe is by `bankKey`: two packs sharing a bank share one
/// file, one download, one delete.
///
/// Owned by `PocketDJApp` (env). This store owns the pack LEDGER (what's downloaded is the
/// disk itself — no JSON document: the file's existence under its deterministic name is the
/// record, the `BurnStore` stems-trio idempotency shape). `StudioStore.deleteAll(.instruments)`
/// sweeps the same files; callers re-sync this store's view via `rescanDownloads()`.
@MainActor
@Observable
final class InstrumentPackStore {

    // MARK: Published state (pack rows render straight off these)

    /// The decoded index — nil until the first successful fetch OR cache load (init tries the
    /// cache synchronously so packs list instantly offline, the CatalogService/AppModel shape).
    private(set) var index: InstrumentPackIndex?
    private(set) var isRefreshing = false
    /// Slugs (`bankSlug(forKey:)`) of banks present on disk — the observable mirror of the
    /// instruments folder, updated on install/delete/rescan (a plain disk check couldn't
    /// invalidate SwiftUI).
    private(set) var downloadedSlugs: Set<String> = []
    /// In-flight download progress per BANK key, 0…1. Keyed by bank (not pack) because the bank
    /// is the download unit — every pack sharing it shows the same bar.
    private(set) var progressByBank: [String: Double] = [:]
    /// Last failure per bank key (cleared on retry). Rendered inline on the pack row.
    private(set) var errorByBank: [String: String] = [:]

    // MARK: Internals

    @ObservationIgnored private let indexURL: URL
    @ObservationIgnored private let session: URLSession
    /// Cache-directory override (tests point it at a temp dir); nil ⇒ CatalogService's
    /// `Application Support/catalog-cache/` — the pack index rides the same explicit file-cache
    /// machinery (deterministic per-URL name, atomic write) as the catalog documents.
    @ObservationIgnored private let cacheDir: URL?
    @ObservationIgnored private var tasksByBank: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var progressObsByBank: [String: NSKeyValueObservation] = [:]

    /// Same diagnostics pipe as MixEngine (`mixdiag` subsystem/category): os_log always, plus
    /// the Settings ▸ Debug capture buffer while a session runs.
    @ObservationIgnored private static let diag = Logger(subsystem: "com.levi.pocketdj",
                                                         category: "mixdiag")
    private func dlog(_ s: String) {
        Self.diag.info("\(s, privacy: .public)")
        MixDiag.shared.append(s)
    }

    init(indexURL: URL = Config.instrumentsIndexURL, session: URLSession = .shared,
         cacheDir: URL? = nil) {
        self.indexURL = indexURL
        self.session = session
        self.cacheDir = cacheDir
        // OFFLINE-FIRST: serve the last good index from disk immediately (a few KB — cheap at
        // init), so the Instruments tab lists packs with no network; `refreshIndex` upgrades it.
        if let cached = loadCachedIndex() { index = cached }
        rescanDownloads()
    }

    // MARK: Index (fetch + explicit file cache — CatalogService pattern)

    /// Fetch the pack index. Network first; on ANY failure the last-good disk cache stands in
    /// (kept from init or a previous success), so this can never blank an already-listed screen.
    /// Only a VALIDATED body (decodes + non-empty packs) is served or cached — an error page or
    /// a gutted future document must not replace a good cache.
    func refreshIndex() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var request = URLRequest(url: indexURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData   // we drive caching ourselves
        request.timeoutInterval = 30
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw InstrumentPackError.badResponse
            }
            guard let idx = Self.decodeIndex(data), !idx.packs.isEmpty else {
                throw InstrumentPackError.badResponse   // undecodable/empty — keep the cache
            }
            index = idx
            CatalogService.writeCache(data, for: indexURL, in: cacheDir)   // validated-decode-first
            dlog("packs: index v\(idx.version) — \(idx.packs.count) packs, \(idx.sharedBanks.count) banks")
        } catch {
            if index == nil, let cached = loadCachedIndex() {
                index = cached
                dlog("packs: index fetch failed — serving disk cache (\(cached.packs.count) packs)")
            } else {
                dlog("packs: index fetch failed — \(error.localizedDescription)")
            }
        }
    }

    /// Decode + validate an index body. Everything decodes leniently, so "decoded" alone is a
    /// weak gate — nil on throw is still the contract the cache write keys off.
    nonisolated static func decodeIndex(_ data: Data) -> InstrumentPackIndex? {
        try? JSONDecoder().decode(InstrumentPackIndex.self, from: data)
    }

    /// Last good cached index from disk (nil when absent or invalid — a bad cache is never
    /// served). Rides `CatalogService.cacheFileURL` so the on-disk name/location conventions
    /// stay single-sourced.
    private func loadCachedIndex() -> InstrumentPackIndex? {
        guard let src = CatalogService.cacheFileURL(for: indexURL, in: cacheDir),
              let data = try? Data(contentsOf: src),
              let idx = Self.decodeIndex(data), !idx.packs.isEmpty else { return nil }
        return idx
    }

    // MARK: Lookup

    var packs: [InstrumentPack] { index?.packs ?? [] }
    /// Attribution string for the packs screen (GeneralUser GS license requirement, spec §6).
    var attribution: String? {
        let a = index?.attribution ?? ""
        return a.isEmpty ? nil : a
    }

    func bank(forKey key: String) -> InstrumentBank? {
        index?.sharedBanks.first { $0.key == key }
    }

    // MARK: Downloaded-state (dedupe by bankKey; disk is the ledger)

    /// A pack is downloaded iff its BANK's file exists — so the second pack referencing an
    /// already-downloaded bank is instantly downloaded (spec §6's dedupe rule).
    func isDownloaded(_ pack: InstrumentPack) -> Bool {
        !pack.bankKey.isEmpty && downloadedSlugs.contains(Self.bankSlug(forKey: pack.bankKey))
    }

    func isDownloading(_ pack: InstrumentPack) -> Bool {
        tasksByBank[pack.bankKey] != nil
    }

    /// In-flight progress for the pack's bank (nil when idle).
    func progress(for pack: InstrumentPack) -> Double? {
        progressByBank[pack.bankKey]
    }

    /// Last download failure for the pack's bank (nil when none).
    func error(for pack: InstrumentPack) -> String? {
        errorByBank[pack.bankKey]
    }

    /// The LOCAL SoundFont file for a pack's bank, or nil until downloaded. Instruments are
    /// always app-managed (no bookmark, no security scope) — the returned URL is directly
    /// loadable by `InstrumentEngine.loadInstrument`.
    func localBankURL(_ pack: InstrumentPack) -> URL? {
        guard !pack.bankKey.isEmpty else { return nil }
        let name = Self.localBankFileName(forKey: pack.bankKey)
        guard let got = StudioFolders.fileURL(family: .instruments, fileName: name,
                                              wasUserFolder: false, bookmark: nil) else { return nil }
        got.release?()   // always nil for app storage — kept for the resolver's contract symmetry
        return got.url
    }

    /// The local SoundFont URL for an INSTRUMENT (its covering pack's downloaded bank), or nil
    /// when no pack covers the instrument or its bank isn't downloaded. The one resolver the
    /// instrumental render (`StudioRender.renderTake`) uses for export / "Use as sample" /
    /// "Sample from instrumental"; a nil is the "download the pack first" prompt.
    func localBankURL(forInstrument instrument: InstrumentKey) -> URL? {
        guard let pack = packs.first(where: { $0.instrument == instrument }) else { return nil }
        return localBankURL(pack)
    }

    /// Re-scan the instruments root and rebuild the downloaded set (init; and after
    /// `StudioStore.deleteAll(.instruments)` swept the same files out from under us). Only
    /// exact-shape names count (the STRICT `StudioFolders.fileId` parser).
    func rescanDownloads() {
        var slugs = Set<String>()
        if let dir = try? StudioFolders.appRoot(.instruments),
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for n in names {
                if let slug = StudioFolders.fileId(family: .instruments, name: n) { slugs.insert(slug) }
            }
        }
        downloadedSlugs = slugs
    }

    // MARK: Download (file-based, verified, atomic)

    /// Download a pack — i.e. its BANK. Idempotent + deduped: already-downloaded returns
    /// immediately, an in-flight download of the same bank is joined (both packs' rows watch the
    /// same `progressByBank` entry). The transfer is a `downloadTask` writing straight to a temp
    /// FILE (never `Data` — 32 MB in memory was the reviewed defect); the completion handler
    /// stages, SHA-256-verifies, and atomically renames into the instruments root synchronously
    /// (the URLSession temp file vanishes when the handler returns — TransferCoordinator's
    /// lesson). Foreground-only by design: TransferCoordinator-managed pack downloads are
    /// explicitly out of scope for v1 (spec §12).
    func download(_ pack: InstrumentPack) {
        let key = pack.bankKey
        guard !key.isEmpty else {
            errorByBank[key] = InstrumentPackError.notDownloadable.errorDescription
            return
        }
        let slug = Self.bankSlug(forKey: key)
        if downloadedSlugs.contains(slug) { return }         // dedupe: bank already on disk
        guard tasksByBank[key] == nil else { return }        // join the in-flight download
        guard let destDir = try? StudioFolders.appRoot(.instruments) else {
            errorByBank[key] = InstrumentPackError.fileSystem.errorDescription
            return
        }
        let dest = destDir.appendingPathComponent(Self.localBankFileName(forKey: key))
        if FileManager.default.fileExists(atPath: dest.path) {   // disk beat the mirror — resync
            downloadedSlugs.insert(slug)
            return
        }
        // The digest to verify against comes from the manifest's bank entry. Empty ⇒ an older
        // manifest without digests: install unverified (logged) rather than making every pack
        // undownloadable — lenient-decode doctrine applied to integrity metadata.
        let expectedSha = bank(forKey: key)?.sha256 ?? ""
        if expectedSha.isEmpty { dlog("packs: WARNING no sha256 for \(key) — installing unverified") }

        errorByBank[key] = nil
        progressByBank[key] = 0
        let url = Config.instrumentsBase.appendingPathComponent(key)
        dlog("packs: download start \(key) → \(dest.lastPathComponent)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 60   // per-idle-interval — a slow 32 MB transfer won't trip it
        let task = session.downloadTask(with: request) { [weak self] temp, response, error in
            // BACKGROUND (session) thread. Stage/verify/install synchronously HERE — the temp
            // file is only valid inside this handler — then hop to main with the outcome.
            let outcome: Result<Void, Error>
            if let error {
                outcome = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                outcome = .failure(InstrumentPackError.badResponse)
            } else if let temp {
                outcome = Result { try Self.installBank(fromTemp: temp, dest: dest,
                                                        expectedSha256: expectedSha) }
            } else {
                outcome = .failure(InstrumentPackError.badResponse)
            }
            Task { @MainActor [weak self] in
                self?.finishDownload(bankKey: key, slug: slug, outcome: outcome)
            }
        }
        // Published progress via KVO on the task's Progress (the spec's prescribed seam).
        // Coalesced to ≥1% steps so a 32 MB transfer doesn't flood the main actor with hops.
        let relay = ProgressRelay()
        progressObsByBank[key] = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            guard f >= relay.last + 0.01 || f >= 1 else { return }
            relay.last = f
            Task { @MainActor [weak self] in
                guard let self, self.tasksByBank[key] != nil else { return }   // finished/cancelled
                self.progressByBank[key] = f
            }
        }
        tasksByBank[key] = task
        task.resume()
    }

    /// Cancel a pack's in-flight bank download (no error surfaced — a cancel is a user action).
    func cancelDownload(_ pack: InstrumentPack) {
        tasksByBank[pack.bankKey]?.cancel()   // completion fires with URLError.cancelled → cleanup
    }

    /// Main-actor tail of a finished (or failed/cancelled) bank download.
    private func finishDownload(bankKey key: String, slug: String, outcome: Result<Void, Error>) {
        progressObsByBank[key]?.invalidate()
        progressObsByBank[key] = nil
        tasksByBank[key] = nil
        progressByBank[key] = nil
        switch outcome {
        case .success:
            downloadedSlugs.insert(slug)
            dlog("packs: download OK \(key)")
        case .failure(let error):
            if (error as? URLError)?.code == .cancelled {
                dlog("packs: download cancelled \(key)")
            } else {
                errorByBank[key] = (error as? InstrumentPackError)?.errorDescription
                    ?? error.localizedDescription
                dlog("packs: download FAILED \(key) — \(error.localizedDescription)")
            }
        }
    }

    /// Stage → verify → atomically install a downloaded bank. `nonisolated static` (pure file
    /// work) so the URLSession completion handler can run it off-main and tests can drive it
    /// directly. Staging lives NEXT TO the destination (same volume ⇒ `moveItem` is an atomic
    /// rename) under a dot-name the STRICT family parser ignores, so a crash mid-install can
    /// never leave a half-written file that counts as a downloaded bank. A digest mismatch
    /// deletes the bytes and throws (spec §6) — unverified data never lands under a real name.
    nonisolated static func installBank(fromTemp temp: URL, dest: URL,
                                        expectedSha256: String) throws {
        let fm = FileManager.default
        let staging = dest.deletingLastPathComponent()
            .appendingPathComponent(".pack-staging-\(UUID().uuidString).tmp")
        do { try fm.moveItem(at: temp, to: staging) } catch { throw InstrumentPackError.fileSystem }
        do {
            if !expectedSha256.isEmpty {
                let got = try sha256Hex(ofFileAt: staging)
                guard got == expectedSha256.lowercased() else { throw InstrumentPackError.shaMismatch }
            }
            if fm.fileExists(atPath: dest.path) {
                // Another pack sharing this bank won the race — the winner is verified; ours
                // is a duplicate. Success, not an error.
                try? fm.removeItem(at: staging)
                return
            }
            do { try fm.moveItem(at: staging, to: dest) } catch { throw InstrumentPackError.fileSystem }
        } catch {
            try? fm.removeItem(at: staging)   // never leave unverified bytes behind
            throw error
        }
    }

    /// Streaming SHA-256 (lowercase hex) of a file — 1 MB chunks so verifying a 32 MB bank never
    /// materializes it in memory (the same rule as the download itself).
    nonisolated static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Delete + usage (Storage manager + Instruments UI)

    /// Delete a bank's local file (packs referencing it flip back to downloadable — banks are
    /// re-downloadable, which is why deletion is allowed at all; user-created studio content
    /// never is). App-managed root ⇒ always reachable, no keep-record dance needed.
    func deleteBank(bankKey: String) {
        guard !bankKey.isEmpty else { return }
        let name = Self.localBankFileName(forKey: bankKey)
        if let got = StudioFolders.fileURL(family: .instruments, fileName: name,
                                           wasUserFolder: false, bookmark: nil) {
            try? FileManager.default.removeItem(at: got.url)
            got.release?()
        }
        downloadedSlugs.remove(Self.bankSlug(forKey: bankKey))
        dlog("packs: deleted bank \(bankKey)")
    }

    /// On-disk bytes of downloaded banks (Settings ▸ Storage row). Strict-shape scan via
    /// `StudioFolders` — co-located foreign files never count.
    var usageBytes: Int {
        StudioFolders.usageBytes(family: .instruments, bookmark: nil)
    }

    // MARK: Deterministic local naming (pure, testable)

    /// Slug for a bank key: the file name minus its extension, lowercased, with anything outside
    /// `[a-z0-9._-]` collapsed to `-`. `banks/GeneralUser GS 2.0.3.sf2` → `generaluser-gs-2.0.3`
    /// — dots survive (the version stays readable) and the result satisfies the STRICT
    /// instruments-family parser (non-empty, no separators).
    nonisolated static func bankSlug(forKey key: String) -> String {
        var base = (key as NSString).lastPathComponent
        if base.lowercased().hasSuffix(".sf2") { base = String(base.dropLast(4)) }
        var out = ""
        var lastWasDash = false
        for ch in base.lowercased() {
            let keep = (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9")
                || ch == "." || ch == "_" || ch == "-"
            if keep {
                out.append(ch)
                lastWasDash = (ch == "-")
            } else if !lastWasDash {
                out.append("-")             // collapse runs of junk to one dash
                lastWasDash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "bank" : out
    }

    /// The bank's LOCAL file name: `instrument-<slug>.sf2` — minted through `StudioFolders` so
    /// the writer and the strict parser can never drift (spec §3's one-minting-point rule).
    nonisolated static func localBankFileName(forKey key: String) -> String {
        StudioFolders.fileName(.instruments, id: bankSlug(forKey: key))
    }
}

/// Tiny cross-thread throttle box for the KVO progress relay (`@unchecked Sendable`: a torn
/// read/write races at most one coalescing decision — same contract as `MixTapPulse`).
private final class ProgressRelay: @unchecked Sendable {
    var last: Double = -1
}
