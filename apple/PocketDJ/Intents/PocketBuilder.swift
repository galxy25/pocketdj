import Foundation
import NaturalLanguage
#if os(iOS)
import UIKit
#endif

// The "Create pocket" build pipeline (Siri: "Create a pocket in PocketDJ" → a brief
// like "optimistic soul, funk, r&b or disco songs from 1960–1989"):
//
//   1. MODEL   parse the brief into structured filters (moods / genres / year range)
//   2. SWIFT   deterministic candidate search over the whole catalog — EXACT year
//              range, FUZZY genre (substring or star-map category), and VECTOR
//              similarity between brief moods and each song's sentiment keywords
//              (NLEmbedding word vectors; token-overlap fallback) — ranked, top-K
//   3. MODEL   curate: pick + order songs from the candidate rows, name the pocket
//   4. SWIFT   validate ids, fit to the minute budget, persist via CollectionsStore
//
// Steps 2/4 are pure and unit-tested; the model steps hide behind `PocketBriefModel`
// so tests stub the LLM and the FoundationModels dependency stays in one
// availability-gated file (FoundationModelPocketBrief.swift).

/// Structured filters the model extracts from the natural-language brief.
struct ParsedPocketBrief: Equatable, Sendable {
    var moods: [String] = []
    var genres: [String] = []
    var yearFrom: Int?
    var yearTo: Int?
}

/// One catalog song, compacted for scoring + the model's candidate rows.
struct PocketCandidate: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let genre: String?
    let year: Int?
    let lengthMs: Int?
    let moods: [String]
}

/// The model's final curation: a pocket name + chosen song ids in play order.
struct PocketPlan: Equatable, Sendable {
    var name: String
    var songIds: [String]
}

/// The two LLM calls, abstracted for testability + OS-availability isolation.
protocol PocketBriefModel: Sendable {
    func parse(brief: String) async throws -> ParsedPocketBrief
    func curate(brief: String, candidates: [PocketCandidate], maxSongs: Int) async throws -> PocketPlan
}

// MARK: - Step 2: deterministic candidate search (pure, testable)

/// Scores every catalog song against the parsed brief and returns the top-K
/// candidates. `nonisolated` pure value logic — feed it snapshot arrays.
struct PocketCandidateSearch: Sendable {
    /// Word → vector, injectable so tests don't depend on on-device NLEmbedding
    /// assets. Multi-word keywords are averaged over their words' vectors.
    var embedding: @Sendable (String) -> [Double]?
    var limit: Int = 80

    static let mismatchScore = -1.0

    /// Production embedding: NLEmbedding English word vectors (on-device, iOS 13+).
    /// One shared instance — loading the asset per-keyword would dominate runtime.
    static func systemEmbedding() -> @Sendable (String) -> [Double]? {
        // NLEmbedding is not Sendable; confine one instance to a serial queue.
        let lock = NSLock()
        let embedder = NLEmbedding.wordEmbedding(for: .english)
        return { word in
            guard let embedder else { return nil }
            lock.lock(); defer { lock.unlock() }
            let tokens = word.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            let vectors = tokens.compactMap { embedder.vector(for: $0) }
            guard !vectors.isEmpty, let dim = vectors.first?.count else { return nil }
            var sum = [Double](repeating: 0, count: dim)
            for v in vectors where v.count == dim {
                for i in 0..<dim { sum[i] += v[i] }
            }
            return sum.map { $0 / Double(vectors.count) }
        }
    }

    /// Rank the catalog against the brief. Exclusions: a specified year range is EXACT
    /// (unknown year ⇒ out); specified genres must fuzzy-match (substring either way,
    /// or same star-map category). Moods only RANK (most of the catalog has no
    /// sentiment keywords — those songs stay eligible on genre+year, scored 0).
    func candidates(songs: [IndexSong], albumsById: [String: IndexAlbum],
                    brief: ParsedPocketBrief) -> [PocketCandidate] {
        struct Scored { let candidate: PocketCandidate; let score: Double; let order: Int }
        var scored: [Scored] = []
        scored.reserveCapacity(min(songs.count, limit * 4))
        let briefMoodVectors = brief.moods.map { (mood: $0.lowercased(), vector: embedding($0)) }

        for (i, song) in songs.enumerated() {
            let album = song.albumId.flatMap { albumsById[$0] }
            let year = song.year ?? album?.year
            if brief.yearFrom != nil || brief.yearTo != nil {
                guard let year,
                      year >= (brief.yearFrom ?? Int.min),
                      year <= (brief.yearTo ?? Int.max) else { continue }
            }
            let genre = album?.genre
            let genreScore = Self.genreScore(genre, briefGenres: brief.genres)
            if genreScore == Self.mismatchScore { continue }
            let moodScore = self.moodScore(song.sentimentKeywords ?? [], briefMoodVectors: briefMoodVectors)
            let candidate = PocketCandidate(id: song.id, title: song.name, artist: song.artist,
                                            genre: genre, year: year, lengthMs: song.length,
                                            moods: song.sentimentKeywords ?? [])
            scored.append(Scored(candidate: candidate, score: 2 * moodScore + genreScore, order: i))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .prefix(limit)
            .map(\.candidate)
    }

    /// Fuzzy genre match: 1.0 substring hit (either direction), 0.5 same star-map
    /// category, `mismatchScore` when the brief names genres and none match. No brief
    /// genres ⇒ neutral 0 (mood/year carry the search).
    static func genreScore(_ genre: String?, briefGenres: [String]) -> Double {
        guard !briefGenres.isEmpty else { return 0 }
        guard let genre = genre?.lowercased(), !genre.isEmpty else { return mismatchScore }
        var best = mismatchScore
        for wanted in briefGenres.map({ $0.lowercased() }) where !wanted.isEmpty {
            if genre.contains(wanted) || wanted.contains(genre) { return 1.0 }
            if Genre.category(genre) != Genre.other, Genre.category(genre) == Genre.category(wanted) {
                best = max(best, 0.5)
            }
        }
        return best
    }

    /// Mood relevance: for each brief mood take the BEST-matching song keyword
    /// (cosine similarity of word vectors; exact/substring overlap when either side
    /// has no vector), then average across brief moods. No brief moods ⇒ 0.
    private func moodScore(_ keywords: [String],
                           briefMoodVectors: [(mood: String, vector: [Double]?)]) -> Double {
        guard !briefMoodVectors.isEmpty, !keywords.isEmpty else { return 0 }
        let keywordPairs = keywords.map { (word: $0.lowercased(), vector: embedding($0)) }
        var total = 0.0
        for brief in briefMoodVectors {
            var best = 0.0
            for kw in keywordPairs {
                let sim: Double
                if let a = brief.vector, let b = kw.vector, a.count == b.count {
                    sim = max(0, Self.cosine(a, b))
                } else if kw.word == brief.mood {
                    sim = 1.0
                } else if kw.word.contains(brief.mood) || brief.mood.contains(kw.word) {
                    sim = 0.7
                } else {
                    sim = 0
                }
                best = max(best, sim)
            }
            total += best
        }
        return total / Double(briefMoodVectors.count)
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / ((na * nb).squareRoot())
    }
}

// MARK: - Step 4: minute-budget fitting (pure, testable)

enum PocketFitter {
    /// Mirrors RealizeEngine's unknown-length fallback (3:30).
    static let fallbackLengthMs = 210_000

    /// Greedy fit of the model's ordered picks into the minute budget: keep order,
    /// skip anything that would overflow (a later shorter song may still fit), and
    /// always keep at least the first pick so a valid plan never fits to zero.
    static func fit(ids: [String], lengthMs: (String) -> Int?, budgetMs: Int) -> [String] {
        var kept: [String] = []
        var total = 0
        for id in ids {
            let len = lengthMs(id) ?? fallbackLengthMs
            if total + len <= budgetMs || kept.isEmpty {
                kept.append(id)
                total += len
            }
        }
        return kept
    }
}

// MARK: - The async build service

/// Runs the 4-step pipeline off the intent's critical path: `CreatePocketIntent`
/// validates availability, calls `kickOff`, and returns its dialog immediately —
/// the pocket appears in Pockets when the build lands. Observable so UI can show
/// progress/failure later. App-scoped (owned by IntentServices).
@MainActor
@Observable
final class PocketBuilderService {
    enum Phase: Equatable {
        case idle
        case building(brief: String)
        case done(pocketId: String, name: String, songCount: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private let app: AppModel
    private let collections: CollectionsStore
    /// Injectable so tests can swap the embedding; production uses NLEmbedding.
    var makeSearch: @Sendable () -> PocketCandidateSearch = {
        PocketCandidateSearch(embedding: PocketCandidateSearch.systemEmbedding())
    }

    init(app: AppModel, collections: CollectionsStore) {
        self.app = app
        self.collections = collections
    }

    /// Dismiss a terminal phase (the Playlists-tab banner's OK/✕). Building is not
    /// dismissable — the build owns the phase until it lands.
    func acknowledge() {
        if case .building = phase { return }
        phase = .idle
    }

    /// Fire-and-return: the intent has already checked model availability. On iOS a
    /// background-task assertion keeps the process alive long enough for the two
    /// model calls when the intent ran without foregrounding the app.
    func kickOff(brief: String, targetMinutes: Int, model: any PocketBriefModel) {
        #if os(iOS)
        var assertion = UIBackgroundTaskIdentifier.invalid
        assertion = UIApplication.shared.beginBackgroundTask(withName: "pocketdj-create-pocket") {
            UIApplication.shared.endBackgroundTask(assertion)
            assertion = .invalid
        }
        #endif
        Task {
            await build(brief: brief, targetMinutes: targetMinutes, model: model)
            #if os(iOS)
            if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
            #endif
        }
    }

    /// The full pipeline. Errors land on `phase` (the intent already returned).
    func build(brief: String, targetMinutes: Int, model: any PocketBriefModel) async {
        phase = .building(brief: brief)
        do {
            await app.loadIfNeeded()
            let parsed = try await model.parse(brief: brief)

            // Score the (possibly ~100k-song) catalog off the main actor.
            let songs = app.songs
            let albumsById = app.albumsById
            let search = makeSearch()
            let candidates = await Task.detached(priority: .userInitiated) {
                search.candidates(songs: songs, albumsById: albumsById, brief: parsed)
            }.value
            guard !candidates.isEmpty else {
                phase = .failed("No songs in your sources match “\(brief)”.")
                return
            }

            let plan = try await model.curate(brief: brief, candidates: candidates, maxSongs: 40)

            // Only ids the model was actually shown count; order-preserving dedup.
            let byId = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var seen = Set<String>()
            let valid = plan.songIds.filter { byId[$0] != nil && seen.insert($0).inserted }
            let fitted = PocketFitter.fit(ids: valid, lengthMs: { byId[$0]?.lengthMs },
                                          budgetMs: max(1, targetMinutes) * 60_000)
            guard !fitted.isEmpty else {
                phase = .failed("The model picked no usable songs for “\(brief)”.")
                return
            }

            let name = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let pocket = collections.createPocket(name.isEmpty ? brief : name,
                                                  songIds: fitted,
                                                  description: "Created by Siri from: “\(brief)”")
            phase = .done(pocketId: pocket.id, name: pocket.name, songCount: fitted.count)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
