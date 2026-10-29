import XCTest
@testable import PocketDJ

/// IN THE POCKET — the cross-platform GOLDEN. `InThePocketScorer` is held to the Kotlin port
/// (`android/.../InThePocketGoldenTest.kt`) by one shared fixture:
///
///   apple/Tests/Fixtures/inthepocket-golden-input.json   (cases: catalog, plays, cloud results,
///                                                          collections, past rounds, seeds)
///   android/app/src/test/resources/fixtures/inthepocket-golden-expected.json  (what Swift builds)
///
/// WRITER mode (`PDJ_WRITE_GOLDEN=1`) runs `InThePocketScorer.build` for every case and rewrites
/// the expected JSON. ASSERT mode (the default, so CI guards drift) re-runs the same cases and
/// compares with the committed expected file (doubles to 1e-9). Regenerate on purpose only — a
/// changed golden means the scorer's behaviour changed, and the Kotlin port must change with it.
///
/// Run (My Mac, ad-hoc signing): see the apple-test skill; writer mode:
///   PDJ_WRITE_GOLDEN=1 xcodebuild test … -only-testing:PocketDJTests/InThePocketGoldenTests
/// (the env var must reach the test process: `TEST_RUNNER_PDJ_WRITE_GOLDEN=1`).
final class InThePocketGoldenTests: XCTestCase {

    // MARK: - Paths

    /// <repo>/apple/Tests/Unit/<this file> → <repo>
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private static var inputURL: URL {
        repoRoot.appendingPathComponent("apple/Tests/Fixtures/inthepocket-golden-input.json")
    }
    private static var expectedURL: URL {
        repoRoot.appendingPathComponent("android/app/src/test/resources/fixtures/inthepocket-golden-expected.json")
    }

    private var writing: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["PDJ_WRITE_GOLDEN"] == "1" || env["TEST_RUNNER_PDJ_WRITE_GOLDEN"] == "1"
    }

    // MARK: - Fixture → Input

    private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    private func tag(_ v: Any?) throws -> ListeningContextTag? {
        guard let o = v as? [String: Any] else { return nil }
        return try JSONDecoder().decode(ListeningContextTag.self, from: JSONSerialization.data(withJSONObject: o))
    }

    private func context(_ o: [String: Any]) throws -> InThePocketContext {
        InThePocketContext(timeBucket: o["timeBucket"] as! String, dayType: o["dayType"] as! String,
                           dow: (o["dow"] as! NSNumber).intValue, ctx: try tag(o["ctx"]))
    }

    private func song(_ o: [String: Any]) -> InThePocketScorer.Song {
        .init(id: o["id"] as! String, title: o["title"] as! String, artist: o["artist"] as! String,
              lengthMs: (o["lengthMs"] as? NSNumber)?.intValue, genre: o["genre"] as? String,
              bpm: num(o["bpm"]), camelot: o["camelot"] as? String, moods: (o["moods"] as? [String]) ?? [])
    }

    private func round(_ o: [String: Any]) throws -> InThePocketRound {
        let created = num(o["createdAtMs"])!
        let outcome: InThePocketOutcome
        switch o["outcome"] as! String {
        case "pocket": outcome = .pocket
        case "broke": outcome = .broke(at: (o["brokeAt"] as! NSNumber).intValue)
        default: outcome = .abandoned
        }
        let targets = (o["targets"] as! [[String: Any]]).map {
            InThePocketTarget(dim: $0["dim"] as! String, value: $0["value"] as! String,
                              label: $0["label"] as! String, weight: num($0["weight"])!)
        }
        let songs = (o["songIds"] as! [String]).map {
            InThePocketSong(id: $0, title: $0, artist: "A-\($0)", lengthMs: nil, score: 1, why: [])
        }
        return InThePocketRound(
            id: UUID(), createdAtMs: created, startedAtMs: created, endedAtMs: created + 900_000,
            updatedAtMs: created + 900_000, tzOffsetMin: -420, context: try context(o["context"] as! [String: Any]),
            contextLabel: nil, mode: .cloud, seed: "1", algoVersion: 1, targets: targets, songs: songs,
            outcome: outcome, rating: nil, feedback: nil, appVersion: "golden")
    }

    private func input(_ o: [String: Any], catalog: [String: InThePocketScorer.Song]) throws -> InThePocketScorer.Input {
        var results: ListeningPocketsResults?
        if let r = o["results"] as? [String: Any] {
            results = try JSONDecoder().decode(ListeningPocketsResults.self,
                                               from: JSONSerialization.data(withJSONObject: r))
        }
        let plays = try (o["plays"] as! [[String: Any]]).map { p in
            InThePocketScorer.Play(songId: p["songId"] as! String, atMs: num(p["atMs"])!,
                                   tzOffsetMin: (p["tzOffsetMin"] as! NSNumber).intValue,
                                   outcome: p["outcome"] as! String, ctx: try tag(p["ctx"]))
        }
        let collections = (o["collections"] as! [[String: Any]]).map { c in
            InThePocketScorer.CollectionInfo(
                id: c["id"] as! String, name: c["name"] as? String, songIds: Set(c["songIds"] as! [String]),
                addedAtMs: (c["addedAtMs"] as? [String: NSNumber])?.mapValues(\.doubleValue) ?? [:])
        }
        return InThePocketScorer.Input(
            context: try context(o["context"] as! [String: Any]), contextLabel: o["contextLabel"] as? String,
            results: results, catalog: catalog, playableIds: Set(o["playableIds"] as! [String]), plays: plays,
            pastRounds: try (o["pastRounds"] as! [[String: Any]]).map(round),
            nowMs: num(o["nowMs"])!, seed: UInt64(o["seed"] as! String)!, collections: collections)
    }

    // MARK: - Output → JSON

    private func json(_ t: InThePocketTarget) -> [String: Any] {
        ["dim": t.dim, "value": t.value, "label": t.label, "weight": t.weight]
    }

    private func expected(_ result: Result<InThePocketScorer.Output, InThePocketScorer.Failure>, name: String) -> [String: Any] {
        switch result {
        case .failure(let f):
            return ["name": name, "result": f == .nothingPlayable ? "nothingPlayable" : "notEnoughCandidates"]
        case .success(let o):
            return [
                "name": name, "result": "success", "mode": o.mode.rawValue,
                "targets": o.targets.map(json),
                "bpmBand": o.bpmBand.map { [$0.lowerBound, $0.upperBound] } ?? NSNull(),
                "picks": o.picks.map { ["id": $0.song.id, "score": $0.score, "why": $0.why] as [String: Any] },
                "chips": o.chips,
            ]
        }
    }

    private func buildAll() throws -> (names: [String], rows: [[String: Any]]) {
        let data = try Data(contentsOf: Self.inputURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let catalog = Dictionary(uniqueKeysWithValues: (root["catalog"] as! [[String: Any]]).map { (song($0).id, song($0)) })
        var names: [String] = [], rows: [[String: Any]] = []
        for c in root["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            names.append(name)
            rows.append(expected(InThePocketScorer.build(try input(c, catalog: catalog)), name: name))
        }
        return (names, rows)
    }

    // MARK: - Tests

    /// Writer (PDJ_WRITE_GOLDEN=1): rewrite the Kotlin expected file. Assert otherwise.
    func testGoldenRoundsMatchTheCommittedExpectedFile() throws {
        let (names, rows) = try buildAll()
        XCTAssertGreaterThanOrEqual(rows.count, 50, "the golden fixture must keep its breadth")
        XCTAssertEqual(Set(names).count, names.count, "case names are keys — they must be unique")
        let successes = rows.filter { $0["result"] as? String == "success" }
        XCTAssertGreaterThan(successes.count, 40)
        for mode in ["cloud", "history", "cold"] {
            XCTAssertTrue(successes.contains { $0["mode"] as? String == mode }, "no \(mode)-mode case in the golden")
        }

        if writing {
            let doc: [String: Any] = ["version": 1, "algoVersion": InThePocketScorer.algoVersion, "cases": rows]
            let out = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .prettyPrinted])
            try FileManager.default.createDirectory(at: Self.expectedURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try out.write(to: Self.expectedURL)
            return
        }

        let want = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.expectedURL)) as! [String: Any]
        let wantCases = want["cases"] as! [[String: Any]]
        XCTAssertEqual(wantCases.count, rows.count, "expected file out of date — run with PDJ_WRITE_GOLDEN=1")
        for (got, exp) in zip(rows, wantCases) {
            let name = got["name"] as! String
            XCTAssertEqual(exp["name"] as? String, name)
            assertEqualJSON(got, exp, path: name)
        }
    }


    /// Same input + seed ⇒ the same output (the property the whole golden rests on). Compared with
    /// the golden's own tolerance: Swift `Dictionary` iteration order is per-instance random, so
    /// sums over dictionaries may differ in the last ulp between two builds — picks must not.
    func testBuildIsDeterministicAcrossRuns() throws {
        let a = try buildAll().rows, b = try buildAll().rows
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) { assertEqualJSON(x, y, path: x["name"] as! String) }
    }

    private func assertEqualJSON(_ a: Any, _ b: Any, path: String, file: StaticString = #filePath, line: UInt = #line) {
        switch (a, b) {
        case let (x as [String: Any], y as [String: Any]):
            XCTAssertEqual(Set(x.keys), Set(y.keys), path, file: file, line: line)
            for k in x.keys { if let yv = y[k] { assertEqualJSON(x[k]!, yv, path: path + "." + k, file: file, line: line) } }
        case let (x as [Any], y as [Any]):
            XCTAssertEqual(x.count, y.count, path, file: file, line: line)
            for (i, (p, q)) in zip(x, y).enumerated() { assertEqualJSON(p, q, path: "\(path)[\(i)]", file: file, line: line) }
        case let (x as String, y as String):
            XCTAssertEqual(x, y, path, file: file, line: line)
        case let (x as NSNumber, y as NSNumber):
            XCTAssertEqual(x.doubleValue, y.doubleValue, accuracy: 1e-9, path, file: file, line: line)
        case (is NSNull, is NSNull): break
        default: XCTFail("\(path): \(a) vs \(b)", file: file, line: line)
        }
    }
}
