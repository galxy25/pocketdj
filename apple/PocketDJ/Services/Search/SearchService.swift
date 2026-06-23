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

/// One page of OpenSearch results: the page's hits plus the TOTAL match count
/// (`hits.total.value`), so the UI knows whether more pages remain (paging).
struct SearchResults: Sendable {
    let hits: [SearchHit]
    let total: Int
}

/// Seam so the paging model can be unit-tested against a stubbed fetcher without
/// the network. `SearchService` is the production conformer; tests inject a stub.
///
/// `sortKeys` is the Browser's multi-key sort (BrowseState.sortKeys). ONLINE search
/// pages server-side (from/size), so the SERVER must sort the full result set — the
/// client only ever holds the loaded pages and can't sort the whole thing. The keys
/// are translated into an OpenSearch `sort` array (see `SearchService.sortBody`).
protocol Searching: Sendable {
    func search(_ query: String, kind: ItemKind?, clauses: [Clause],
                sortKeys: [SortKey], creds: SigV4Creds,
                from: Int, size: Int) async throws -> SearchResults
}

/// Online search against the `pocketdj` OpenSearch Serverless collection — same
/// query the PWA issues (multi_match across title/artist/album/lyrics/sentiment),
/// signed with the user's read-only key/secret. No CORS proxy needed natively.
enum SearchService {
    static let host = "zxvkpgoc5ivtrbqp37s5.us-west-2.aoss.amazonaws.com"
    static let region = "us-west-2"
    static let service = "aoss"
    static let index = "pocketdj"

    /// OpenSearch's default `index.max_result_window`: `from + size` may not exceed
    /// this, so callers cap paging here (offset pagination stops at 10k results).
    static let maxResultWindow = 10_000

    static func search(_ query: String, kind: ItemKind?, clauses: [Clause] = [],
                       sortKeys: [SortKey] = [], creds: SigV4Creds,
                       from: Int = 0, size: Int = 50) async throws -> SearchResults {
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
        // `track_total_hits: true` makes OpenSearch return the EXACT total (not the
        // 10k-capped default), so the pager knows when it has loaded everything.
        // The SERVER sorts (from/size paging means the client never holds the full
        // result set), with a deterministic `id` tiebreaker for STABLE pagination.
        var bodyObj: [String: Any] = [
            "from": from, "size": size, "track_total_hits": true,
            "query": ["bool": bool],
        ]
        bodyObj["sort"] = sortBody(sortKeys, hasQuery: !trimmed.isEmpty)
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

    // MARK: - Server-side sort

    /// Native SortKey field id → INDEXED doc field used for SORTING. Distinct from
    /// `FilterQuery.docField` (filtering) because sorting can't run on a `text`-typed
    /// field — it must target a sortable `keyword`/numeric:
    ///   • TEXT fields (title/artist/album/sentiment) → their `.kw` keyword subfield.
    ///   • genre → the precomputed `genreCategory` keyword (collapsed tier-1 category).
    ///   • NUMERIC fields (year/bpm/length/trackNumber/trackCount) → the field itself.
    ///   • key/camelot/source/fileType/country → their keyword field (sortable as-is).
    /// (SortKey ids reuse the Browser field ids: `name` = title.)
    static let sortDocField: [String: String] = [
        "name": "title.kw",
        "artist": "artist.kw",
        "sentiment": "sentiment.kw",
        "genre": "genreCategory",
        "year": "year",
        "bpm": "bpm",
        "length": "length",
        "trackNumber": "trackNumber",
        "trackCount": "trackCount",
        "key": "key",
        "camelot": "camelot",
        "source": "source",
        "fileType": "fileType",
        "country": "country",
    ]

    /// Build the OpenSearch `sort` array for the Browser's multi-key sort, ALWAYS
    /// ending with an `{"id": "asc"}` tiebreaker (id is a keyword) so `from/size`
    /// pagination is STABLE — no rows duplicated or skipped across pages.
    ///
    /// • Each resolvable SortKey → `{"<docfield>": {"order": "asc"|"desc"}}` (unknown
    ///   field ids are dropped). • Empty keys WITH a query: omit explicit field sorts
    ///   so `_score` relevance leads, then the id tiebreaker. • Empty keys with NO
    ///   query (filter-only): just sort by `id` asc. Goal: paging is deterministic.
    static func sortBody(_ keys: [SortKey], hasQuery: Bool) -> [[String: Any]] {
        var sort: [[String: Any]] = []
        for k in keys {
            guard let field = sortDocField[k.field] else { continue }
            sort.append([field: ["order": k.dir == .desc ? "desc" : "asc"]])
        }
        // Deterministic tiebreaker LAST so offset pagination never duplicates/skips.
        sort.append(["id": ["order": "asc"]])
        // (With a query and no explicit keys, the leading `_score` is implicit — the
        // id tiebreaker still makes equally-scored hits page in a stable order.)
        _ = hasQuery
        return sort
    }

    // MARK: - Response parsing

    private struct Response: Decodable { let hits: Hits }
    private struct Hits: Decodable { let total: Total; let hits: [Hit] }
    /// `hits.total` is `{ value, relation }`; with `track_total_hits` the value is exact.
    private struct Total: Decodable { let value: Int }
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

    private static func parse(_ data: Data) throws -> SearchResults {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let hits = decoded.hits.hits.map { hit -> SearchHit in
            let s = hit.source
            return SearchHit(id: hit.id, type: s.type ?? "song", title: s.title, artist: s.artist,
                             album: s.album, albumId: s.albumId, genre: s.genre, year: s.year,
                             bpm: s.bpm, key: s.key, camelot: s.camelot, explicit: s.explicit,
                             trackNumber: s.trackNumber, source: s.source)
        }
        return SearchResults(hits: hits, total: decoded.hits.total.value)
    }
}

/// Production conformer: forwards to the static `SearchService.search`. A value
/// type so it stays `Sendable` and trivially injectable (default in the model).
struct LiveSearchService: Searching {
    func search(_ query: String, kind: ItemKind?, clauses: [Clause],
                sortKeys: [SortKey], creds: SigV4Creds,
                from: Int, size: Int) async throws -> SearchResults {
        try await SearchService.search(query, kind: kind, clauses: clauses,
                                       sortKeys: sortKeys, creds: creds,
                                       from: from, size: size)
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
            case .notInList:
                let nums = c.values.compactMap(Double.init).map(numJSON)
                if !nums.isEmpty { mustNot.append(["terms": [field: nums]]) }
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
            case .notInList:
                // none-of: exclude any of the selected values (online analog of the
                // on-device .notInList none-of predicate).
                let vals = c.values.map(lc).filter { !$0.isEmpty }
                if !vals.isEmpty { mustNot.append(["terms": [field: vals]]) }
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
