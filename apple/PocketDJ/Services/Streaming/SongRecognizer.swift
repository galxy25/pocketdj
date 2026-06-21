import Foundation

/// A pure *catalog-resolution* capability, decoupled from both `StreamingProvider`
/// (account-link + playback) and `StreamingSearch` (free-text browse). Given one of
/// OUR catalog songs, a recognizer answers "does my provider's catalog have a
/// playable track for this song?" and, if so, hands back a `StreamingTrack`.
///
/// WHY ITS OWN PROTOCOL. A recognizer touches no audio session and holds no UI
/// state — it is data-only. Splitting it from the player lets:
///   • a future cloud-ID / metadata service contribute resolution *without* being
///     a player,
///   • the registry ask "any connected provider that can resolve this rip-less
///     song?" via `providers.compactMap { $0 as? SongRecognizer }`,
///   • the Shazam bridge turn an `appleMusicID` (or a title/artist pair) into a
///     playable provider track when there is no local rip — the single, optional
///     coupling point between recognition and streaming.
///
/// It reuses the existing `StreamingTrack` value type rather than introducing a
/// parallel `ProviderTrackRef`, so there is exactly one "track returned by a
/// provider" type in the codebase.
///
/// `@MainActor` to match the rest of the streaming seam (providers are main-actor
/// `@Observable` types); `AnyObject` so the registry can hold `any SongRecognizer`
/// existentials and identity-compare them.
@MainActor
protocol SongRecognizer: AnyObject {
    var kind: StreamingProviderKind { get }

    /// True when this recognizer can answer right now (e.g. the account is linked
    /// and the subscription can play catalog content). A provider may be
    /// *available* (SDK + creds) yet not *resolving* (logged out), so this is its
    /// own gate, distinct from `StreamingProvider.isAvailable`.
    var canResolve: Bool { get }

    /// Map one of OUR `IndexSong`s to a playable provider track, or nil if this
    /// provider's catalog does not have it. Implementations should prefer a stable
    /// provider id when our song already carries one (e.g. a namespaced
    /// `am:<storeID>` id) and fall back to a normalized title/artist lookup.
    func resolve(_ song: IndexSong) async -> StreamingTrack?
}

extension Sequence where Element == any StreamingProvider {
    /// Convenience: pull the `SongRecognizer`s out of a provider list.
    /// `providers.recognizers` reads better than the raw `compactMap` at call sites.
    var recognizers: [any SongRecognizer] {
        compactMap { $0 as? (any SongRecognizer) }
    }
}
