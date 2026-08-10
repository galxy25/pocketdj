import Foundation

// ============================================================================
// MARK: - Playing a record you do not own
// ============================================================================

/// One track of a release, flattened out of whichever expansion tier answered. Deliberately a
/// plain value with no MusicKit and no `RipsStore` types in it, so the mapping below — the part
/// that decides what actually gets queued — is exercised by the unit suite rather than only by
/// driving the UI against the network.
struct ReleaseStreamTrack: Equatable {
    var storeID: String
    var title: String
    var artist: String
    var lengthMs: Int?
}

/// **New is playable.** Owner, verbatim: *"we want to be able to play or shuffle New as well, that
/// is the equivalent of cloud mode for a collection."*
///
/// The New tile lists releases by artists he plays that he does NOT own — which is exactly why the
/// ordinary door is closed to it. `CollectionsStore.playNow` (and therefore
/// `IntentServices.playSongIds`, and therefore `CollectionPlayback.start`) DROPS every id the
/// catalog cannot resolve, and no track of an unowned release resolves. Sending New down that path
/// would produce an empty setlist and a ▶ that silently does nothing.
///
/// So it uses the app's OTHER, already-shipped door for Apple-Music-only audio: a
/// `SetlistPlayer.Item` carrying the namespaced `am:<storeID>` id, handed straight to the
/// sequencer. `PlaybackCoordinator.providers(for:)` recognises that namespace and routes it to the
/// MusicKit backend; the Jukebox (`JukeboxStore.accept`) and Music with Friends
/// (`MusicWithFriendsStore.queueMatchIfPlayable`) have both queued exactly this shape since they
/// shipped. Nothing here is a new playback path — this is that path, given a release to expand.
///
/// ── WHAT THE DEVICE/CLOUD TOGGLE MEANS HERE ──────────────────────────────────────────────────
/// The same thing it means everywhere, which is why it is wired and not hidden. `SetlistPlayer`
/// reads `SettingsStore.playbackMode` per track: in `.device` it plays only a burned local file
/// and SKIPS anything without one, in `.cloud` it streams what it hasn't got. A New queue is
/// mostly (often entirely) unowned, so cloud mode plays it and device mode plays only the parts he
/// has already pulled down — the honest reading of "device = only what is downloaded", and the
/// reason streaming an unowned release IS the cloud-mode analogue for this tile.
///
/// ── DEGRADE, NEVER STALL ─────────────────────────────────────────────────────────────────────
/// Every layer skips rather than blocks: a release with no store id is never offered by
/// `ReleaseFeedService.feed` in the first place, a release whose expansion comes back empty
/// contributes nothing, a track with a blank store id is dropped here, and a queued row whose
/// audio cannot be resolved at play time is skipped forward by `SetlistPlayer` itself. A dead row
/// can therefore never park the queue.
enum ReleaseStreaming {

    /// How many releases one ▶ expands. Each release is one network round trip, so this is a
    /// latency ceiling, not a taste judgement: 25 albums is already a multi-hour queue, and the
    /// tail of a 30-day feed is the part he is least likely to be waiting on.
    static let maxReleases = 25
    /// Expansions in flight at once. Bounded for the same reason the release feed's own fetch is:
    /// a burst of unbounded requests against the Apple Music endpoints earns a 429.
    static let concurrency = 4

    // ── The pure part ────────────────────────────────────────────────────────────────────────

    /// Expanded tracks → queue items.
    ///
    ///  • A blank store id is DROPPED — it can never resolve to audio, and a row that can never
    ///    play has no business occupying a queue slot.
    ///  • A track the local catalog already claims (some indexed song carries that Apple Music id)
    ///    plays under its OWN song id, so device mode can reach its burned file and history/stats
    ///    key the real song. Everything else plays under `am:<storeID>` — the stream.
    ///  • Duplicates collapse: an artist can appear twice in the feed, and a single is routinely
    ///    also a track on the album released beside it.
    static func items(_ tracks: [ReleaseStreamTrack],
                      catalogSongId: (String) -> String? = { _ in nil }) -> [SetlistPlayer.Item] {
        var seen = Set<String>()
        var out: [SetlistPlayer.Item] = []
        for t in tracks {
            let storeID = t.storeID.trimmingCharacters(in: .whitespaces)
            guard !storeID.isEmpty else { continue }
            let id = catalogSongId(storeID) ?? AppleMusicCatalog.namespacedSongID(storeID)
            guard seen.insert(id).inserted else { continue }
            out.append(SetlistPlayer.Item(id: id, title: t.title, artist: t.artist,
                                          lengthMs: t.lengthMs))
        }
        return out
    }

    // ── The expansion ────────────────────────────────────────────────────────────────────────

    /// Expand one release's Apple Music ALBUM id into its tracks, through the SAME two tiers
    /// `AlbumPreviewView` and `RipsStore.discoverAddAlbum` already use: MusicKit when the account
    /// can read the catalog, else the rip server's subscription-free `/album-tracks` proxy. Empty
    /// on failure — the caller drops the release.
    @MainActor
    static func tracks(forReleaseId releaseId: String, rips: RipsStore,
                       library: (any MusicLibraryContributor)?) async -> [ReleaseStreamTrack] {
        if let library, library.canContribute {
            let rows = await library.albumTracks(albumStoreID: releaseId)
            if !rows.isEmpty {
                return rows.map {
                    ReleaseStreamTrack(storeID: $0.storeID, title: $0.title, artist: $0.artist,
                                       lengthMs: $0.durationSeconds.map { s in Int((s * 1000).rounded()) })
                }
            }
        }
        let expansion = await rips.fetchAlbumExpansion(collectionId: releaseId)
        return expansion.tracks.map {
            ReleaseStreamTrack(storeID: $0.id, title: $0.title, artist: $0.artist,
                               lengthMs: $0.durationMs)
        }
    }

    /// Expand a list of releases IN ORDER, `concurrency` at a time. Order is preserved because a
    /// queue built from "newest release first" that came back in completion order would shuffle
    /// itself differently on every tap.
    @MainActor
    static func tracks(forReleaseIds ids: [String], rips: RipsStore,
                       library: (any MusicLibraryContributor)?) async -> [ReleaseStreamTrack] {
        let wanted = Array(ids.prefix(maxReleases))
        guard !wanted.isEmpty else { return [] }
        var byIndex: [Int: [ReleaseStreamTrack]] = [:]
        var next = 0
        while next < wanted.count {
            let slice = next..<min(next + concurrency, wanted.count)
            next = slice.upperBound
            let batch = await withTaskGroup(of: (Int, [ReleaseStreamTrack]).self) { group in
                for i in slice {
                    group.addTask { @MainActor in
                        (i, await tracks(forReleaseId: wanted[i], rips: rips, library: library))
                    }
                }
                var acc: [(Int, [ReleaseStreamTrack])] = []
                for await pair in group { acc.append(pair) }
                return acc
            }
            for (i, rows) in batch { byIndex[i] = rows }
        }
        return wanted.indices.flatMap { byIndex[$0] ?? [] }
    }
}
