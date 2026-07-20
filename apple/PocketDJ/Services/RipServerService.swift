import Foundation

/// `/health` response from the iMac rip server (mirrors the PWA's serverInfo).
struct RipHealth: Decodable {
    let version: Int?
    let hls: Bool?
    let cached: Int?
    let catalog: Catalog?
    struct Catalog: Decodable { let songs: Int?; let albums: Int? }
}

/// Talks to the rip server over Tailscale (same API the PWA uses).
enum RipServerService {
    /// Minimum server version that supports live HLS (PWA's EXPECTED_RIP_VERSION).
    static let expectedVersion = 2

    /// `profileId` is the signed-in `ProfileStore.id` (defaulted empty for callers that have
    /// none yet); it + the device id ride as the forward-compatible per-user identity headers.
    static func health(urlString: String, token: String, profileId: String = "") async -> Result<RipHealth, Error> {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard let base = URL(string: trimmed), base.scheme != nil else {
            return .failure(URLError(.badURL))
        }
        var request = URLRequest(url: base.appendingPathComponent("health"))
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        PDJIdentityHeaders.apply(to: &request, profileId: profileId)
        request.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failure(URLError(.badServerResponse))
            }
            return .success(try JSONDecoder().decode(RipHealth.self, from: data))
        } catch {
            return .failure(error)
        }
    }
}
