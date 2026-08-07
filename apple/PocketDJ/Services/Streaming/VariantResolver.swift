import Foundation

/// Best-effort preferred-EDITION chooser for a single known Apple Music store id — the
/// recognizer "＋ add" seam: before the library-add + rip flow runs, swap the recognized
/// storeID for its preferred-edition sibling (clean by default, explicit when the user
/// prefers it) when one verifiably exists. Never throws; ANY failure (offline, no
/// sibling, ambiguous) falls back to the input storeID — the recognized track always
/// still adds. Deliberately NOT applied to Discover's `discoverAdd` (Discover shows
/// editions with badges; the user's tapped row is authoritative).
@MainActor
enum VariantResolver {
    static func preferredStoreID(storeID: String, title: String, artist: String,
                                 preferExplicit: Bool,
                                 using provider: AppleMusicProvider) async -> String {
        guard let row = await provider.catalogRow(forStoreID: storeID) else { return storeID }
        // Already the preferred edition (or unclassified) → keep the input.
        guard row.isExplicit == !preferExplicit else { return storeID }
        let rows = (try? await AppleMusicProvider.searchRows(term: "\(title) \(artist)", limit: 15)) ?? []
        // Same tight filter as the variant stream resolve: same recording, required
        // edition, duration agreement — never a different cut.
        let lengthMs = row.durationSeconds.map { Int(($0 * 1000).rounded()) }
        if let sibling = rows.first(where: {
            AppleMusicProvider.editionMatches($0, name: title, artist: artist,
                                              lengthMs: lengthMs, wantExplicit: preferExplicit)
        }) {
            return sibling.storeID
        }
        return storeID
    }
}
