import Foundation

/// **IS THIS SONG ALREADY IN THAT COLLECTION?** — asked once, in one place, by every surface that
/// offers something to add.
///
/// Owner, verbatim: *"don't recommend songs that are already in that collection for adding to a
/// collection."* A `Set<String>` of the member ids answers that question WRONGLY, and quietly: one
/// recording rides this app under as many as three different ids, so a song can be a member under
/// one of them and a "suggestion" under another, and the two never compare equal.
///
/// ── THE THREE IDENTITIES ─────────────────────────────────────────────────────────────────────
///  1. **The catalog id** — `sng_<12 hex>`. The ordinary case.
///  2. **The variant id** — `sng_<12 hex>_clean` / `_explicit` (`SongVariant`). A DIFFERENT string
///     for the same recording: the clean rip is a distinct S3 object, so it needs its own id, and
///     an add made from an explicit-filtered browse lands the variant while the tile suggests the
///     base.
///  3. **The ad-hoc Apple Music id** — `amrec_<storeId>`, minted by Discover / the recognizer for
///     a song captured before the nightly indexer has ever seen it. It carries the Apple Music
///     store id IN THE NAME, and the indexed catalog row that eventually supersedes it carries the
///     same number as `IndexSong.appleMusicId` — so those two strings name one recording with
///     nothing textual in common.
///
/// This exact duplicate-identity class has already cost this app a bug once: a track that played
/// twice because two ids for it both looked new. Here it costs a *suggestion slot* — the tile
/// offers a song he already filed, the 👍 is a no-op, and the candidate that should have had the
/// row never gets it.
///
/// ── WHY A VALUE TYPE AND NOT A METHOD ON THE STORE ───────────────────────────────────────────
/// The ranking runs OFF the main actor (`ForYouFeedBuilder` is `Task.detached` over ~96k rows) and
/// `CollectionsStore` is `@MainActor`. So membership crosses the actor hop as a snapshot, exactly
/// as the catalog and the play log do. `Sendable`, immutable, and buildable from literals — which
/// is also what lets the guarantee be unit-tested under all three id forms.
struct RecMembership: Sendable, Equatable {

    /// Every identity key any member resolves to. A candidate is a member if it shares ONE of them.
    private let keys: Set<String>

    /// - Parameters:
    ///   - memberIds: the collection's resolved playable ids (albums/pockets already expanded — a
    ///     song that is in the collection *through* an album member is just as much a member).
    ///   - appleMusicId: catalog lookup for a member id, when the caller has one. Supplies the
    ///     REVERSE direction of the ad-hoc join (member `sng_…` ⇒ its store id, so a candidate
    ///     `amrec_<that id>` is recognised). Defaulted to "don't know", because the pure engine
    ///     paths and the tests genuinely do not.
    init(memberIds: some Sequence<String>, appleMusicId: (String) -> String? = { _ in nil }) {
        var keys = Set<String>()
        for id in memberIds {
            for k in Self.identityKeys(songId: id, appleMusicId: appleMusicId(id)) { keys.insert(k) }
        }
        self.keys = keys
    }

    /// Direct construction from keys — the memoized store path, which has already resolved them.
    private init(keys: Set<String>) { self.keys = keys }

    /// No members ⇒ nothing is filtered. Distinguished from "everything is filtered" on purpose:
    /// callers use it to skip the whole pass.
    var isEmpty: Bool { keys.isEmpty }

    /// Is this song already in the collection, under ANY of its identities?
    ///
    /// `appleMusicId` is the CANDIDATE's catalog store id when the caller has it (`IndexSong`
    /// carries one on most "Apple Music (Local)" rows). Without it the ad-hoc join still works in
    /// the direction that matters most — an `amrec_` MEMBER vs a catalog candidate — only when the
    /// candidate side supplies the number, so callers that can pass it should.
    func contains(_ songId: String, appleMusicId: String? = nil) -> Bool {
        for k in Self.identityKeys(songId: songId, appleMusicId: appleMusicId) where keys.contains(k) {
            return true
        }
        return false
    }

    /// The read-time filter: `ids` minus everything that is already a member, order preserved.
    ///
    /// ── WHY THIS EXISTS SEPARATELY FROM THE ENGINE'S FILTER ──────────────────────────────────
    /// The suggestion lists are FROZEN (`ForYouFeedSnapshot`) and only recomputed on an explicit
    /// Refresh — that is the owner's cache rule and it is not negotiable. But membership changes on
    /// every add, including the adds made FROM these very lists, so a filter applied only when the
    /// ranking is built goes stale the first time he acts on it: the tile keeps counting a song he
    /// just filed, and keeps offering it after a relaunch until the next Friday refresh.
    ///
    /// So membership is filtered at READ, over the frozen ids, every time they are read. Cheap —
    /// a set lookup per row over a list of ~25 — and it means the answer is never older than the
    /// glance.
    func excluding(_ ids: [String], appleMusicId: (String) -> String? = { _ in nil }) -> [String] {
        guard !keys.isEmpty else { return ids }
        return ids.filter { !contains($0, appleMusicId: appleMusicId($0)) }
    }

    // ========================================================================
    // MARK: - Identity
    // ========================================================================

    /// Every key one song id can be recognised by. THE definition of "the same song" for
    /// recommendation membership, and the only one — two answers to this question is how the app
    /// ends up suggesting what it already owns.
    static func identityKeys(songId id: String, appleMusicId: String? = nil) -> [String] {
        // The BASE id collapses `_clean` / `_explicit` onto the recording; identity for every
        // other id shape (`amrec_`, `smp_`, `pdj_`, a bare `sng_`), so the ordinary case is one
        // string and one set lookup.
        var out = [SongVariant.baseId(id)]
        if let store = adHocStoreId(id) { out.append(storeKey(store)) }
        if let am = appleMusicId, let key = validStoreKey(am) { out.append(key) }
        return out
    }

    /// `amrec_<storeId>` ad-hoc rip ids carry their Apple Music store id in the name (the
    /// recognizer / Discover convention). THE one parser — `SongLibraryAffordance.adHocStoreID`
    /// forwards here rather than keeping a second copy.
    static func adHocStoreId(_ songId: String) -> String? {
        guard songId.hasPrefix("amrec_") else { return nil }
        let raw = String(songId.dropFirst("amrec_".count))
        return !raw.isEmpty && raw.allSatisfy(\.isNumber) ? raw : nil
    }

    /// Namespaced so an Apple Music store id can never collide with a song id in the same set.
    private static func storeKey(_ storeId: String) -> String { "am:" + storeId }

    /// ── WHY THE STORE ID IS VALIDATED AND NOT JUST NON-EMPTY ─────────────────────────────────
    /// This key is a JOIN, and a bad join is the one failure mode worse than the bug it fixes: a
    /// placeholder shared by many rows ("0", "", "unknown") would fold a whole slice of the
    /// catalog into ONE identity and silently delete real suggestions. Apple's adam ids are long
    /// bare numerals, so requiring exactly that is a cheap, total guard — anything else simply
    /// does not participate in the join and falls back to id equality.
    private static func validStoreKey(_ raw: String) -> String? {
        guard raw.count >= 4, raw.allSatisfy(\.isNumber), raw.contains(where: { $0 != "0" }) else {
            return nil
        }
        return storeKey(raw)
    }
}
