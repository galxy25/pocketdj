import Foundation

/// One OpenSearch hit, flattened from `{ _id, _source }`.
struct SearchHit: Sendable {
    let id: String
    let type: String        // "album" | "song"
    let title: String?
    let artist: String?
    let album: String?
    let albumId: String?
    let genre: String?
    let year: Int?
    let bpm: Double?
    let key: String?
    let camelot: String?
    let explicit: Bool?
    let trackNumber: Int?
    let source: String?
}

/// Online search against the `pocketdj` OpenSearch Serverless collection — same
/// query the PWA issues (multi_match across title/artist/album/lyrics/sentiment),
/// signed with the user's read-only key/secret. No CORS proxy needed natively.
enum SearchService {
    static let host = "zxvkpgoc5ivtrbqp37s5.us-west-2.aoss.amazonaws.com"
    static let region = "us-west-2"
    static let service = "aoss"
    static let index = "pocketdj"

    static func search(_ query: String, kind: ItemKind?, clauses: [Clause] = [],
                       creds: SigV4Creds, size: Int = 60) async throws -> [SearchHit] {
        let path = "/\(index)/_search"
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let must: [[String: Any]] = trimmed.isEmpty
            ? [["match_all": [:]]]
            : [["multi_match": [
                "query": trimmed,
                "fields": ["title^3", "artist^2", "album^1.5", "lyrics", "sentiment^2"],
                "type": "best_fields",
                "fuzziness": "AUTO",
                "operator": "and",
              ]]]
        var filter: [[String: Any]] = []
        var mustNot: [[String: Any]] = []
        if let kind { filter.append(["term": ["type": kind.rawValue]]) }
        // Translate every structured filter clause into OpenSearch query clauses so
        // the online results honor the SAME filters as on-device. Field ids map to
        // the indexed doc fields (keyword/int/bool); `genre` uses the precomputed
        // `genreCategory` keyword so it matches the app's collapsed categories.
        for c in clauses {
            FilterQuery.append(c, into: &filter, mustNot: &mustNot)
        }
        var bool: [String: Any] = ["must": must, "filter": filter]
        if !mustNot.isEmpty { bool["must_not"] = mustNot }
        let bodyObj: [String: Any] = ["size": size, "query": ["bool": bool]]
        let body = try JSONSerialization.data(withJSONObject: bodyObj)

        var request = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        for (k, v) in SigV4.sign(method: "POST", host: host, path: path, body: body,
                                 region: region, service: service, creds: creds) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "PocketDJ.search", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Search failed (\(http.statusCode)): \(msg.prefix(180))"])
        }
        return try parse(data)
    }

    // MARK: - Response parsing

    private struct Response: Decodable { let hits: Hits }
    private struct Hits: Decodable { let hits: [Hit] }
    private struct Hit: Decodable {
        let id: String
        let source: Source
        enum CodingKeys: String, CodingKey { case id = "_id"; case source = "_source" }
    }
    private struct Source: Decodable {
        let type: String?
        let title: String?, artist: String?, album: String?, albumId: String?
        let genre: String?, key: String?, camelot: String?
        let year: Int?, trackNumber: Int?
        let bpm: Double?
        let explicit: Bool?
        let source: String?
    }

    private static func parse(_ data: Data) throws -> [SearchHit] {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.hits.hits.map { hit in
            let s = hit.source
            return SearchHit(id: hit.id, type: s.type ?? "song", title: s.title, artist: s.artist,
                             album: s.album, albumId: s.albumId, genre: s.genre, year: s.year,
                             bpm: s.bpm, key: s.key, camelot: s.camelot, explicit: s.explicit,
                             trackNumber: s.trackNumber, source: s.source)
        }
    }
}

/// Translates the app's `Clause` filter model into OpenSearch bool-query clauses,
/// so ONLINE search honors the same filters as on-device. Each filterable field id
/// maps to its indexed doc field; ops become term/terms/range (+ must_not for neq).
enum FilterQuery {
    /// Native field id → indexed doc field. `genre` resolves to the precomputed
    /// `genreCategory` keyword (collapsed tier-1 category) so it matches the app's
    /// category options; text fields use their `.kw` keyword subfield for exact eq.
    private static let docField: [String: String] = [
        "artist": "artist.kw",
        "name": "title.kw",
        "year": "year",
        "genre": "genreCategory",
        "fileType": "fileType",
        "source": "source",
        "country": "country",
        "trackCount": "trackCount",
        "trackNumber": "trackNumber",
        "length": "length",
        "bpm": "bpm",
        "key": "key",
        "camelot": "camelot",
        "explicit": "explicit",
        "sentiment": "sentiment.kw",
    ]

    static func append(_ c: Clause, into filter: inout [[String: Any]],
                       mustNot: inout [[String: Any]]) {
        guard !c.isIncomplete, let field = docField[c.field],
              let f = Fields.byID[c.field] else { return }

        switch f.kind {
        case .bool:
            // explicit eq → term true/false
            if c.op == .eq { filter.append(["term": [field: c.value == "true"]]) }

        case .number:
            switch c.op {
            case .eq:
                if let n = Double(c.value) { filter.append(["term": [field: numJSON(n)]]) }
            case .neq:
                if let n = Double(c.value) { mustNot.append(["term": [field: numJSON(n)]]) }
            case .inList:
                let nums = c.values.compactMap(Double.init).map(numJSON)
                if !nums.isEmpty { filter.append(["terms": [field: nums]]) }
            case .between:
                var r: [String: Any] = [:]
                if let lo = c.min { r["gte"] = numJSON(lo) }
                if let hi = c.max { r["lte"] = numJSON(hi) }
                if !r.isEmpty { filter.append(["range": [field: r]]) }
            }

        case .string, .stringArray:
            // Keyword fields use a lowercase normalizer in the index, so we
            // lowercase clause values here → case-insensitive parity w/ on-device.
            // (stringArray = sentiment: eq → contains; neq → not contains.)
            switch c.op {
            case .eq:    if !c.value.isEmpty { filter.append(["term": [field: lc(c.value)]]) }
            case .neq:   if !c.value.isEmpty { mustNot.append(["term": [field: lc(c.value)]]) }
            case .inList:
                let vals = c.values.map(lc).filter { !$0.isEmpty }
                if !vals.isEmpty { filter.append(["terms": [field: vals]]) }
            case .between: break
            }
        }
    }

    /// Doc numeric fields are integers; emit Int when whole to match the mapping.
    private static func numJSON(_ n: Double) -> Any {
        n == n.rounded() ? Int(n) : n
    }

    /// Lowercase + trim to match the index's `lc` keyword normalizer.
    private static func lc(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
