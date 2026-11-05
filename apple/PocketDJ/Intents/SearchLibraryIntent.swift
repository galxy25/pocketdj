import Foundation
import AppIntents

/// "Search PocketDJ for boogie" — the system.search assistant schema (the ONE
/// pre-audio-domain schema that fits a music library, iOS 18-era): Siri/Spotlight
/// route a search term straight into the Browser's search field. The term rides
/// `IntentServices.pendingBrowseQuery` (consumed by BrowseView) and
/// `.browseSearch` lands the user on the Browser tab.
///
/// Not on tvOS: the tvOS 27 SDK marks the `.system` schema domain unavailable (the 26 SDK
/// didn't), so the TV build never had a working Siri search to lose.
#if !os(tvOS)
@AppIntent(schema: .system.search)
struct SearchLibraryIntent {
    static let title: LocalizedStringResource = "Search PocketDJ"
    static let description = IntentDescription("Searches your PocketDJ sources for albums and songs.")
    static let searchScopes: [StringSearchScope] = [.general]

    var criteria: StringSearchCriteria

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult {
        services.pendingBrowseQuery = criteria.term
        services.pendingRoute = .browseSearch
        return .result()
    }
}
#endif
