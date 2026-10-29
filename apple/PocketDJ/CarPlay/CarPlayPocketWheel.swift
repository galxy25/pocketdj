import Foundation

/// **Pocket for now, in the car** (§2.6). Templates can't draw a wheel, so the car gets the wheel's
/// ANSWER: a top row "▶ Pocket for now — Potential · Tue 8 AM" on For You, and a short list of the
/// moments within ±1 h of now across modes. CarPlay connected implies the `carPlay` mode. Model-only
/// (no CarPlay import) so the unit suite verifies it; the scene just maps rows to CPListItems.
extension CarPlayModel {

    static let pocketNowRowId = "pocketwheel:now"
    static let pocketMomentRowPrefix = "pocketwheel:m:"

    /// "▶ Pocket for now" with "Potential · Tue 8 AM" (nil when the wheel has nothing to offer).
    func pocketForNowRow() -> Row? {
        guard let wheel = services.pocketWheel, let r = wheel.result else { return nil }
        let p = r.profile
        guard p.tier != .empty || !p.collections.isEmpty else { return nil }
        let name = p.dominantCollectionId.flatMap { wheel.collectionName($0) }
        let when = p.key.map { "\(PocketMomentKey.weekdayAbbrev[$0.dow - 1]) \(PocketMomentKey.hourLabel($0.hour))" } ?? p.caption
        return Row(id: Self.pocketNowRowId, title: "▶ Pocket for now",
                   subtitle: [name, when].compactMap { $0 }.joined(separator: " · "),
                   artworkAlbumId: nil, isSong: false)
    }

    /// "Pockets right now": the top 5 moments whose hour is within ±1 h of now, across modes.
    func pocketsRightNow() -> [Row] {
        guard let wheel = services.pocketWheel else { return [] }
        return wheel.momentsNow(count: 5).map { m in
            Row(id: Self.pocketMomentRowPrefix + m.key.token, title: m.key.shortLabel,
                subtitle: PocketBestMatch.detail(collectionId: m.dominantCollectionId, plays: m.directPlays,
                                                 names: wheel.collectionNames),
                artworkAlbumId: nil, isSong: false)
        }
    }

    /// Refresh the answer (the scene calls this on connect, before building For You).
    func refreshPocketForNow() async { await services.pocketWheel?.refresh() }

    /// Through the intent door (onboarding veto + readiness). False ⇒ nothing started — the
    /// scene toasts instead of opening an empty Now Playing.
    @discardableResult
    func playPocketForNow() async -> Bool {
        (try? await services.playPocketForNow()) != nil
    }

    @discardableResult
    func playPocketMoment(rowId: String) async -> Bool {
        guard rowId.hasPrefix(Self.pocketMomentRowPrefix),
              let key = PocketMomentKey(token: String(rowId.dropFirst(Self.pocketMomentRowPrefix.count))) else { return false }
        return (try? await services.playPocketMoment(key)) != nil
    }
}
