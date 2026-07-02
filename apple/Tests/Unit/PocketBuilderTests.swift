import XCTest
@testable import PocketDJ

/// The Create-Pocket pipeline's DETERMINISTIC layers + the end-to-end build with a
/// stubbed LLM: candidate search (exact year range, fuzzy genre, mood-vector
/// ranking), the minute-budget fitter, and `PocketBuilderService.build` persisting a
/// pocket whose songs are exactly the model's valid, budget-fitted picks.
@MainActor
final class PocketBuilderTests: XCTestCase {

    // MARK: Fixtures

    /// A tiny word-vector space where "optimistic"≈"upbeat"≈"happy" ⟂ "dark"≈"gloomy".
    private static let vectors: [String: [Double]] = [
        "optimistic": [1, 0], "upbeat": [0.9, 0.1], "happy": [0.95, 0.05],
        "dark": [0, 1], "gloomy": [0.1, 0.9],
    ]
    private static let stubEmbedding: @Sendable (String) -> [Double]? = { word in
        vectors[word.lowercased()]
    }

    private func song(_ id: String, name: String = "Song", artist: String = "Artist",
                      albumId: String? = nil, year: Int? = nil, keywords: [String]? = nil,
                      lengthMs: Int? = nil) -> IndexSong {
        var json = "{\"id\":\"\(id)\",\"name\":\"\(name)\",\"artist\":\"\(artist)\""
        if let albumId { json += ",\"albumId\":\"\(albumId)\"" }
        if let year { json += ",\"year\":\(year)" }
        if let keywords { json += ",\"sentimentKeywords\":[\(keywords.map { "\"\($0)\"" }.joined(separator: ","))]" }
        if let lengthMs { json += ",\"length\":\(lengthMs)" }
        json += "}"
        return try! JSONDecoder().decode(IndexSong.self, from: Data(json.utf8))
    }

    private func album(_ id: String, genre: String?, year: Int? = nil) -> IndexAlbum {
        var json = "{\"id\":\"\(id)\",\"name\":\"Album\",\"artist\":\"Artist\",\"trackList\":[]"
        if let genre { json += ",\"genre\":\"\(genre)\"" }
        if let year { json += ",\"year\":\(year)" }
        json += "}"
        return try! JSONDecoder().decode(IndexAlbum.self, from: Data(json.utf8))
    }

    private var search: PocketCandidateSearch {
        PocketCandidateSearch(embedding: Self.stubEmbedding)
    }

    // MARK: Candidate search — year (exact), genre (fuzzy), moods (vector rank)

    func testYearRangeIsExactAndUnknownYearIsExcluded() {
        let albums = ["alb_soul": album("alb_soul", genre: "Soul")]
        let songs = [
            song("in", albumId: "alb_soul", year: 1975),
            song("early", albumId: "alb_soul", year: 1959),
            song("late", albumId: "alb_soul", year: 1990),
            song("unknown", albumId: "alb_soul", year: nil),
        ]
        let brief = ParsedPocketBrief(genres: ["soul"], yearFrom: 1960, yearTo: 1989)
        let ids = search.candidates(songs: songs, albumsById: albums, brief: brief).map(\.id)
        XCTAssertEqual(ids, ["in"])
    }

    func testYearFallsBackToAlbumYear() {
        let albums = ["alb": album("alb", genre: "Funk", year: 1978)]
        let songs = [song("s", albumId: "alb", year: nil)]
        let brief = ParsedPocketBrief(yearFrom: 1970, yearTo: 1979)
        XCTAssertEqual(search.candidates(songs: songs, albumsById: albums, brief: brief).map(\.id), ["s"])
    }

    func testGenreFuzzyMatchSubstringAndCategory() {
        // Substring either way ⇒ 1.0.
        XCTAssertEqual(PocketCandidateSearch.genreScore("Philly Soul", briefGenres: ["soul"]), 1.0)
        XCTAssertEqual(PocketCandidateSearch.genreScore("Soul", briefGenres: ["philly soul"]), 1.0)
        // Same star-map category (disco ↔ post-disco boogie) ⇒ 0.5.
        XCTAssertEqual(PocketCandidateSearch.genreScore("Boogie", briefGenres: ["disco"]), 0.5)
        // Named genres but no match ⇒ excluded.
        XCTAssertEqual(PocketCandidateSearch.genreScore("Death Metal", briefGenres: ["disco"]),
                       PocketCandidateSearch.mismatchScore)
        // Genre-less song can't match a genre-constrained brief.
        XCTAssertEqual(PocketCandidateSearch.genreScore(nil, briefGenres: ["disco"]),
                       PocketCandidateSearch.mismatchScore)
        // Brief without genres is genre-neutral.
        XCTAssertEqual(PocketCandidateSearch.genreScore(nil, briefGenres: []), 0)
    }

    func testMoodVectorSimilarityRanksAndKeywordlessSongsSurvive() {
        let albums = ["alb": album("alb", genre: "Soul")]
        let songs = [
            song("dark", albumId: "alb", keywords: ["gloomy"]),
            song("bright", albumId: "alb", keywords: ["upbeat"]),
            song("plain", albumId: "alb", keywords: nil),       // Apple-Music-style: no sentiment
        ]
        let brief = ParsedPocketBrief(moods: ["optimistic"], genres: ["soul"])
        let ids = search.candidates(songs: songs, albumsById: albums, brief: brief).map(\.id)
        XCTAssertEqual(ids.first, "bright")                     // vector-closest mood wins
        XCTAssertTrue(ids.contains("plain"))                    // still eligible on genre
        XCTAssertEqual(ids.count, 3)
    }

    func testMoodFallbackWithoutVectorsUsesTokenOverlap() {
        let noVectors = PocketCandidateSearch(embedding: { _ in nil })
        let albums = ["alb": album("alb", genre: "Soul")]
        let songs = [
            song("exact", albumId: "alb", keywords: ["optimistic"]),
            song("none", albumId: "alb", keywords: ["angular"]),
        ]
        let brief = ParsedPocketBrief(moods: ["optimistic"])
        let ids = noVectors.candidates(songs: songs, albumsById: albums, brief: brief).map(\.id)
        XCTAssertEqual(ids.first, "exact")
    }

    func testLimitCapsCandidates() {
        var small = search
        small.limit = 3
        let songs = (0..<10).map { song("s\($0)", year: 1980) }
        let brief = ParsedPocketBrief(yearFrom: 1970, yearTo: 1989)
        XCTAssertEqual(small.candidates(songs: songs, albumsById: [:], brief: brief).count, 3)
    }

    // MARK: Fitter

    func testFitterKeepsOrderSkipsOverflowAndUsesFallbackLength() {
        let lengths = ["a": 40 * 60_000, "b": 45 * 60_000, "c": 20 * 60_000, "d": nil as Int?]
        // Budget 90 min: a(40)+b(45)=85, c(20) overflows and is skipped, d(fallback 3.5) fits.
        let kept = PocketFitter.fit(ids: ["a", "b", "c", "d"],
                                    lengthMs: { lengths[$0] ?? nil },
                                    budgetMs: 90 * 60_000)
        XCTAssertEqual(kept, ["a", "b", "d"])
    }

    func testFitterAlwaysKeepsFirstPick() {
        let kept = PocketFitter.fit(ids: ["long"], lengthMs: { _ in 200 * 60_000 }, budgetMs: 90 * 60_000)
        XCTAssertEqual(kept, ["long"])
    }

    // MARK: End-to-end build with a stubbed LLM

    private struct StubModel: PocketBriefModel {
        var parsed: ParsedPocketBrief
        var plan: PocketPlan
        func parse(brief: String) async throws -> ParsedPocketBrief { parsed }
        func curate(brief: String, candidates: [PocketCandidate], maxSongs: Int) async throws -> PocketPlan { plan }
    }

    func testBuildCreatesPersistedPocketFromModelPicks() async throws {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-builder-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let collections = CollectionsStore(fileURL: url)
        collections.app = app

        let service = PocketBuilderService(app: app, collections: collections)
        service.makeSearch = { PocketCandidateSearch(embedding: Self.stubEmbedding) }
        // The model answers with one bogus id (dropped) + real fixture songs (kept, in order).
        let model = StubModel(parsed: ParsedPocketBrief(),
                              plan: PocketPlan(name: "Test Vibes",
                                               songIds: ["sng_bogus", "sng_2", "sng_1"]))
        await service.build(brief: "test vibes", targetMinutes: 90, model: model)

        guard case .done(let pocketId, let name, let count) = service.phase else {
            return XCTFail("expected .done, got \(service.phase)")
        }
        XCTAssertEqual(name, "Test Vibes")
        XCTAssertEqual(count, 2)
        let pocket = collections.pocket(pocketId)
        XCTAssertEqual(pocket?.songIds, ["sng_2", "sng_1"])     // model's order, bogus id dropped
        XCTAssertEqual(pocket?.description, "Created by Siri from: “test vibes”")

        // Persisted: a fresh store from the same file sees the pocket.
        let reloaded = CollectionsStore(fileURL: url)
        XCTAssertEqual(reloaded.pocket(pocketId)?.songIds, ["sng_2", "sng_1"])
    }

    func testBuildFailsCleanlyWhenNothingMatches() async {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-builder-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let collections = CollectionsStore(fileURL: url)
        collections.app = app

        let service = PocketBuilderService(app: app, collections: collections)
        service.makeSearch = { PocketCandidateSearch(embedding: Self.stubEmbedding) }
        // A year range no fixture song satisfies ⇒ zero candidates ⇒ failed, no pocket.
        let model = StubModel(parsed: ParsedPocketBrief(yearFrom: 1800, yearTo: 1801),
                              plan: PocketPlan(name: "X", songIds: ["sng_1"]))
        await service.build(brief: "impossible", targetMinutes: 90, model: model)

        guard case .failed = service.phase else {
            return XCTFail("expected .failed, got \(service.phase)")
        }
        XCTAssertTrue(collections.pockets.isEmpty)
    }
}
