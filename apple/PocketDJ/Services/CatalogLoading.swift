import Foundation

/// Seam between the UI/logic and the data layer. The app uses the live
/// `CatalogService` (network); tests inject a fixture so the whole UI can be
/// exercised offline and deterministically — no CloudFront dependency.
protocol CatalogLoading: Sendable {
    func loadIndex() async throws -> IndexJSON
}

extension CatalogService: CatalogLoading {}

/// Loads a small catalog bundled in the app, used only when the app is launched
/// with `PDJ_USE_FIXTURE` (UI tests). Never used in normal operation.
struct FixtureCatalog: CatalogLoading {
    var resource: String = "fixture-index"

    func loadIndex() async throws -> IndexJSON {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
            throw URLError(.fileDoesNotExist)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(IndexJSON.self, from: data)
    }
}

enum CatalogLoaderFactory {
    /// Picks the loader from the launch environment so tests can force the fixture.
    static func make() -> CatalogLoading {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            return FixtureCatalog()
        }
        return CatalogService()
    }
}
