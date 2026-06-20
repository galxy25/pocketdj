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
}

/// Online search against the `pocketdj` OpenSearch Serverless collection — same
/// query the PWA issues (multi_match across title/artist/album/lyrics/sentiment),
/// signed with the user's read-only key/secret. No CORS proxy needed natively.
enum SearchService {
    static let host = "zxvkpgoc5ivtrbqp37s5.us-west-2.aoss.amazonaws.com"
    static let region = "us-west-2"
    static let service = "aoss"
    static let index = "pocketdj"

    static func search(_ query: String, kind: ItemKind?, creds: SigV4Creds,
                       size: Int = 60) async throws -> [SearchHit] {
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
        if let kind { filter.append(["term": ["type": kind.rawValue]]) }
        let bodyObj: [String: Any] = ["size": size, "query": ["bool": ["must": must, "filter": filter]]]
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
    }

    private static func parse(_ data: Data) throws -> [SearchHit] {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.hits.hits.map { hit in
            let s = hit.source
            return SearchHit(id: hit.id, type: s.type ?? "song", title: s.title, artist: s.artist,
                             album: s.album, albumId: s.albumId, genre: s.genre, year: s.year,
                             bpm: s.bpm, key: s.key, camelot: s.camelot, explicit: s.explicit,
                             trackNumber: s.trackNumber)
        }
    }
}
