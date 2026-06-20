import Foundation

/// Fetches and decodes the catalog index from CloudFront (same document the PWA
/// auto-seeds from). URLSession's shared URLCache makes repeat launches fast.
struct CatalogService {
    var url: URL = Config.indexURL

    func loadIndex() async throws -> IndexJSON {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.init(rawValue: http.statusCode == 404 ? URLError.fileDoesNotExist.rawValue
                                                                   : URLError.badServerResponse.rawValue))
        }
        return try JSONDecoder().decode(IndexJSON.self, from: data)
    }
}
