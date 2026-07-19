import Foundation
import Observation
import AVFoundation
#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

/// Owns the Demuxer's derived-metadata documents: one `DemuxDocument` JSON per analyzed source
/// under `Application Support/demux-cache/` (the LyricsStore disk-cache pattern — flat files,
/// memory tier above, injectable dir for tests), plus the copied-in audio for `.file` sources
/// under `demux-cache/audio/`. Analysis itself (chords + transcript) is kicked off here too, so
/// the view stays a pure renderer: `analyzeChords`/`analyzeTranscript` run detached off the main
/// actor and land their results (or failure) back on the persisted document.
@MainActor
@Observable
final class DemuxStore {
    private let cacheDir: URL?
    /// Source key → document (memory tier; disk is the durable tier).
    private var memory: [String: DemuxDocument] = [:]
    /// Keys with an analysis in flight (drives the running spinners; not persisted).
    private(set) var chordRuns: Set<String> = []
    private(set) var transcriptRuns: Set<String> = []

    init(cacheDir: URL? = DemuxStore.defaultCacheDir()) {
        self.cacheDir = cacheDir
    }

    /// `Application Support/demux-cache/`. A `dir` override is the unit-test seam.
    nonisolated static func defaultCacheDir(_ dir: URL? = nil) -> URL? {
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let d = base.appendingPathComponent("demux-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: - Documents

    private func fileURL(_ key: String) -> URL? {
        guard let cacheDir else { return nil }
        let safe = key.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        return cacheDir.appendingPathComponent("\(safe).json")
    }

    /// The document for a source key — memory → disk → nil (never analyzed).
    func document(for key: String) -> DemuxDocument? {
        if let hit = memory[key] { return hit }
        guard let f = fileURL(key), let data = try? Data(contentsOf: f),
              let doc = try? JSONDecoder().decode(DemuxDocument.self, from: data) else { return nil }
        memory[key] = doc
        return doc
    }

    /// The document for a source, created empty on first sight.
    func documentCreating(for source: DemuxSource) -> DemuxDocument {
        if let doc = document(for: source.key) { return doc }
        let doc = DemuxDocument(sourceKey: source.key, displayName: source.displayName)
        memory[source.key] = doc
        return doc
    }

    func save(_ doc: DemuxDocument) {
        memory[doc.sourceKey] = doc
        guard let f = fileURL(doc.sourceKey), let data = try? JSONEncoder().encode(doc) else { return }
        try? data.write(to: f, options: .atomic)
    }

    // MARK: - Imported audio (.file sources)

    /// Folder holding copied-in audio for imported-file sources.
    nonisolated static func audioDir(under cacheDir: URL?) -> URL? {
        guard let cacheDir else { return nil }
        let d = cacheDir.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Copy a picked file into the demux audio folder and mint its source. The copy makes the
    /// audio durable past the picker's security scope (the sample-import lesson).
    func importFile(from url: URL) -> DemuxSource? {
        guard let dir = Self.audioDir(under: cacheDir) else { return nil }
        let id = "dmx_\(UUID().uuidString.lowercased().prefix(8))"
        let name = "\(id).\(url.pathExtension.isEmpty ? "audio" : url.pathExtension)"
        let dest = dir.appendingPathComponent(name)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return nil }
        var doc = DemuxDocument(sourceKey: id, displayName: url.deletingPathExtension().lastPathComponent)
        doc.importedFileName = name
        save(doc)
        return .file(id: id, name: url.deletingPathExtension().lastPathComponent)
    }

    /// Local URL of a `.file` source's copied-in audio.
    func importedAudioURL(for key: String) -> URL? {
        guard let name = document(for: key)?.importedFileName,
              let dir = Self.audioDir(under: cacheDir) else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Imported-file sources whose audio is still on disk — the picker's "Imported audio"
    /// rows. Disk-scanned (not just the memory tier) so imports survive app restarts and
    /// stay reachable after leaving the tab (previously an import VANISHED from the picker
    /// once deselected — the only way back was re-importing).
    func importedSources() -> [(id: String, name: String)] {
        guard let cacheDir,
              let files = try? FileManager.default.contentsOfDirectory(
                at: cacheDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [(id: String, name: String)] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let doc = try? JSONDecoder().decode(DemuxDocument.self, from: data),
                  doc.importedFileName != nil,
                  importedAudioURL(for: doc.sourceKey) != nil else { continue }
            out.append((id: doc.sourceKey, name: doc.displayName))
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - Carved-song audio cache (analog shared-album sides)

    /// Where a song CARVED OUT of a shared analog album side lands (`audio/<songId>.m4a`).
    /// Digital rips and per-song cuts play their burned file directly and never use this; a
    /// shared side must be carved once so playback, analysis, and the timeline all start at
    /// the song's 0:00 (the analog-offset contract, demux edition).
    func carvedSongDestination(for songId: String) -> URL? {
        guard let dir = Self.audioDir(under: cacheDir) else { return nil }
        let safe = songId.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).m4a")
    }

    /// The already-carved audio for a song, or nil if never carved.
    func carvedSongURL(for songId: String) -> URL? {
        guard let url = carvedSongDestination(for: songId),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - Custom stems cache (uploaded-audio separation results)

    /// Folder for a CUSTOM source's downloaded stems (`stems/<key>/<stem>.<ext>`). Song
    /// sources never land here — their stems live in the BurnStore (`burnStems`); this cache
    /// is for audio the catalog has never seen (imported files, performance media), separated
    /// via the rip server's `/stemify-custom` upload path.
    nonisolated static func stemsDir(under cacheDir: URL?, key: String) -> URL? {
        guard let cacheDir else { return nil }
        let safe = key.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let d = cacheDir.appendingPathComponent("stems", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The four downloaded stem files for a custom source, or nil if any is missing.
    func localStemURLs(for key: String) -> [String: URL]? {
        guard let dir = Self.stemsDir(under: cacheDir, key: key),
              let listing = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        var urls: [String: URL] = [:]
        for name in StemPlayer.stems {
            guard let f = listing.first(where: { $0.deletingPathExtension().lastPathComponent == name }) else { return nil }
            urls[name] = f
        }
        return urls
    }

    /// Download the four remote stem files into the cache (all-or-nothing; a partial set is
    /// removed so `localStemURLs` never reports a half-downloaded source as ready).
    func downloadStems(for key: String, remote: [String: URL]) async -> [String: URL]? {
        guard let dir = Self.stemsDir(under: cacheDir, key: key) else { return nil }
        var urls: [String: URL] = [:]
        for name in StemPlayer.stems {
            guard let src = remote[name],
                  let (data, response) = try? await URLSession.shared.data(from: src),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: dir)
                return nil
            }
            let ext = src.pathExtension.isEmpty ? "mp3" : src.pathExtension
            let dest = dir.appendingPathComponent("\(name).\(ext)")
            guard (try? data.write(to: dest, options: .atomic)) != nil else {
                try? FileManager.default.removeItem(at: dir)
                return nil
            }
            urls[name] = dest
        }
        return urls
    }

    // MARK: - Fixture seeding (PDJ_SEED_DEMUX=1 — UI proof runs / demos)

    /// Seed a deterministic, FULLY-ANALYZED 3-minute source ("Demux Proof") for the
    /// simulator UI proof: synthesized audio in the demux cache, a chord every 2 s
    /// (stable `demux-chord-<startMs>` ids the test measures frames of), a word every
    /// second spanning the whole track, both `.done` so no analysis runs (the sim's
    /// speech daemon can't initialize — DemuxTranscriberFieldProbeTests). Idempotent.
    func seedFixtureIfRequested() {
        guard ProcessInfo.processInfo.environment["PDJ_SEED_DEMUX"] == "1" else { return }
        let id = "dmx_fixture"
        guard document(for: id) == nil else { return }
        guard let dir = Self.audioDir(under: cacheDir) else { return }
        let seconds = 180
        let name = "\(id).caf"
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard Self.writeSeedAudio(to: url, seconds: seconds) else { return }
        }
        var doc = DemuxDocument(sourceKey: id, displayName: "Demux Proof")
        doc.importedFileName = name
        doc.durationMs = seconds * 1_000
        let roots: [(pc: Int, minor: Bool)] = [(0, false), (7, false), (9, true), (5, false)]
        doc.chords = stride(from: 0, to: doc.durationMs, by: 2_000).map { start in
            let r = roots[(start / 2_000) % roots.count]
            return DemuxChordSegment(rootPC: r.pc, minor: r.minor, startMs: start,
                                     endMs: min(start + 2_000, doc.durationMs), confidence: 0.9)
        }
        doc.chordStatus = .done
        let cycle = ["let", "me", "see", "you", "go", "back"]
        doc.words = (0..<seconds).map { s in
            DemuxWord(text: cycle[s % cycle.count], startMs: s * 1_000, endMs: s * 1_000 + 400)
        }
        doc.transcriptStatus = .done
        doc.transcriptCoveredMs = doc.durationMs
        save(doc)
    }

    /// 3 minutes of LPCM CAF — a 220 Hz tone under a slow amplitude sweep, so the
    /// waveform lane shows real contour instead of a flat bar.
    nonisolated private static func writeSeedAudio(to url: URL, seconds: Int) -> Bool {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return false }
        for second in 0..<seconds {
            buf.frameLength = 44_100
            let amp = Float(0.05 + 0.25 * abs(sin(Double(second) / 7)))
            if let p = buf.floatChannelData?[0] {
                for i in 0..<44_100 {
                    p[i] = amp * sin(Float(i) * 2 * .pi * 220 / 44_100)
                }
            }
            guard (try? file.write(from: buf)) != nil else { return false }
        }
        return true
    }

    // MARK: - Analysis kickoff

    /// Detect the chord timeline of `url` and land it on the source's document. No-op while a
    /// run for the same key is already in flight. `force` re-analyzes over a done result.
    /// `release` (a held security scope on `url`) is invoked when the run finishes.
    func analyzeChords(source: DemuxSource, url: URL, durationMs: Int, force: Bool = false,
                       release: (() -> Void)? = nil) {
        let key = source.key
        guard !chordRuns.contains(key) else { release?(); return }
        if !force, documentCreating(for: source).chordStatus == .done { release?(); return }
        chordRuns.insert(key)
        var doc = documentCreating(for: source)
        doc.durationMs = max(doc.durationMs, durationMs)
        save(doc)
        Task {
            let segments = await Task.detached(priority: .utility) { ChordDetector.detect(url: url) }.value
            release?()
            var doc = self.documentCreating(for: source)
            doc.chords = segments
            doc.chordStatus = segments.isEmpty ? .failed : .done
            self.save(doc)
            self.chordRuns.remove(key)
        }
    }

    /// Test seam: stands in for `DemuxTranscriber.transcribe` (headless CI has no on-device
    /// speech models). Receives (url, resumeFromMs, onWindow); drives the same incremental
    /// persistence + status machine the real recognizer does.
    static var transcribeHook: ((URL, Int,
                                 (@MainActor @Sendable (DemuxTranscriber.WindowReport) -> Void)?)
                                async throws -> [DemuxWord])?

    /// Transcribe `url` (callers pass the VOCALS STEM when burned — far better than the full
    /// mix) and land the timed words on the source's document. `release` (a held security
    /// scope on `url`) is invoked when the run finishes.
    ///
    /// FULL-SONG robustness (the "lyrics stop after a snip" field bug): the doc is stamped
    /// `.running` and each finished window's words land IMMEDIATELY (`transcriptCoveredMs`
    /// advances with them) — lyrics fill in live, an app death loses nothing, and the next
    /// kickoff RESUMES from the coverage point instead of starting over. On iOS the run holds
    /// a background-task assertion so leaving the foreground grants a grace window instead of
    /// freezing recognition mid-song.
    func analyzeTranscript(source: DemuxSource, url: URL, durationMs: Int, force: Bool = false,
                           release: (() -> Void)? = nil) {
        let key = source.key
        guard !transcriptRuns.contains(key) else { release?(); return }
        var doc = documentCreating(for: source)
        if !force, doc.transcriptStatus == .done { release?(); return }
        guard DemuxTranscriber.isSupported || Self.transcribeHook != nil else {
            doc.transcriptStatus = .unavailable
            save(doc)
            release?()
            return
        }
        transcriptRuns.insert(key)
        doc.durationMs = max(doc.durationMs, durationMs)
        // Resume an interrupted run (status persisted `.running`, no task alive) from its
        // coverage point, keeping the words already heard; anything else starts clean.
        let resumeFrom = (!force && doc.transcriptStatus == .running) ? (doc.transcriptCoveredMs ?? 0) : 0
        if resumeFrom == 0 {
            doc.words = []
            doc.transcriptCoveredMs = 0
        }
        doc.transcriptStatus = .running
        doc.transcriptDiag = nil
        save(doc)
        let hold = BackgroundHold("demux-transcript")
        Task {
            var status = DemuxArtifactStatus.done
            var windowsFailed = 0
            var windowsTotal = 0
            var lastFailure: String?
            let onWindow: @MainActor @Sendable (DemuxTranscriber.WindowReport) -> Void = { report in
                windowsTotal = report.total
                if let f = report.failure { windowsFailed += 1; lastFailure = f }
                var doc = self.documentCreating(for: source)
                doc.words = (doc.words + report.words).sorted { $0.startMs < $1.startMs }
                doc.transcriptCoveredMs = max(doc.transcriptCoveredMs ?? 0, report.endMs)
                self.save(doc)
            }
            do {
                if let hook = Self.transcribeHook {
                    _ = try await hook(url, resumeFrom, onWindow)
                } else {
                    _ = try await DemuxTranscriber.transcribe(url: url, resumeFromMs: resumeFrom,
                                                              onWindow: onWindow)
                }
            } catch DemuxTranscriber.TranscribeError.unauthorized,
                    DemuxTranscriber.TranscribeError.unsupported {
                status = .unavailable
            } catch {
                status = .failed
            }
            release?()
            hold.end()
            var doc = self.documentCreating(for: source)
            // Words accumulated per window above — the final pass only settles status/diag.
            if status == .done, doc.words.isEmpty, windowsFailed > 0 {
                status = .failed        // nothing heard AND something broke → retryable
            }
            doc.transcriptStatus = status
            if status == .done, windowsFailed > 0, windowsTotal > 0 {
                doc.transcriptDiag = "\(windowsFailed) of \(windowsTotal) sections couldn’t be "
                    + "transcribed\(lastFailure.map { " (\($0))" } ?? "") — Regenerate to fill gaps."
            }
            self.save(doc)
            self.transcriptRuns.remove(key)
        }
    }
}

/// Holds a UIKit background-task assertion for the lifetime of an analysis run, so leaving
/// the foreground (lock, app switch) grants the run a grace window instead of freezing
/// recognition mid-song. Ending twice is guarded; system expiration self-ends. No-op off iOS.
@MainActor
private final class BackgroundHold {
    #if canImport(UIKit) && !os(macOS)
    private var id: UIBackgroundTaskIdentifier = .invalid
    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
    #else
    init(_ name: String) {}
    func end() {}
    #endif
}
