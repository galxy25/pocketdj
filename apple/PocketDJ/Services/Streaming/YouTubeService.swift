import Foundation

/// YouTube Data API v3 — catalog search via an **API key** (public data only;
/// no OAuth needed for search). Endpoint:
///
///   GET https://www.googleapis.com/youtube/v3/search
///     ?part=snippet&type=video&maxResults=N&q=<query>&key=<API_KEY>
///
/// Quota: `search.list` costs **100 units** per call against a default daily
/// quota of 10,000 units → ~100 searches/day. Keep that in mind before wiring
/// search-as-you-type; debounce and cache. (videos.list for durations costs 1.)
///
/// This type is self-contained — it has NO dependency on the
/// youtube-ios-player-helper pod. Search and playback are decoupled: this gets
/// the videoId; `YouTubePlayerView` plays it. So the app compiles and the
/// search source works even before the player pod is added.
@MainActor
struct YouTubeService: StreamingSearch {
    let kind: StreamingProviderKind = .youTube

    /// Public Data API key (Google Cloud → APIs & Services → Credentials). Search
    /// only needs this; it does NOT prove a user is signed in.
    let apiKey: String

    /// Optional OAuth access token. Present only after account-link; lets us hit
    /// the user's own resources (their playlists, likes) on top of public search.
    let accessToken: String?

    var canSearch: Bool { !apiKey.isEmpty }

    private static let base = URL(string: "https://www.googleapis.com/youtube/v3")!

    func search(_ query: String, limit: Int = 25) async throws -> [StreamingTrack] {
        guard canSearch else { throw StreamingError.notConfigured }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        var comps = URLComponents(url: Self.base.appendingPathComponent("search"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "part", value: "snippet"),
            .init(name: "type", value: "video"),
            .init(name: "videoEmbeddable", value: "true"), // only ToS-embeddable
            .init(name: "maxResults", value: String(min(max(limit, 1), 50))),
            .init(name: "q", value: q),
            .init(name: "key", value: apiKey),
        ]
        guard let url = comps.url else { throw StreamingError.notConfigured }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        // If we have an OAuth session, send it; the API key still scopes the app.
        if let token = accessToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw StreamingError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw StreamingError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            // 403 with reason quotaExceeded / dailyLimitExceeded → friendly message.
            if http.statusCode == 403,
               let body = String(data: data, encoding: .utf8),
               body.contains("quota") || body.contains("Exceeded") {
                throw StreamingError.quotaExceeded
            }
            throw StreamingError.http(http.statusCode)
        }

        let decoded: SearchResponse
        do {
            decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw StreamingError.decoding
        }
        return decoded.items.compactMap { item in
            guard let vid = item.id.videoId else { return nil }
            let thumb = item.snippet.thumbnails.high?.url
                ?? item.snippet.thumbnails.medium?.url
                ?? item.snippet.thumbnails.defaultThumb?.url
            return StreamingTrack(
                id: "youtube:\(vid)",
                kind: .youTube,
                providerTrackID: vid,
                title: item.snippet.title,
                artist: item.snippet.channelTitle,
                artworkURL: thumb.flatMap(URL.init(string:)),
                durationSeconds: nil)
        }
    }

    // MARK: - Wire shapes (search.list, part=snippet)

    private struct SearchResponse: Decodable { let items: [Item] }
    private struct Item: Decodable {
        let id: ID
        let snippet: Snippet
        struct ID: Decodable { let videoId: String? }
        struct Snippet: Decodable {
            let title: String
            let channelTitle: String
            let thumbnails: Thumbnails
        }
        struct Thumbnails: Decodable {
            let defaultThumb: Thumb?
            let medium: Thumb?
            let high: Thumb?
            struct Thumb: Decodable { let url: String }
            enum CodingKeys: String, CodingKey {
                case defaultThumb = "default", medium, high
            }
        }
    }
}
