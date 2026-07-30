import SwiftUI

/// "Force Apple Music sync" — a collection-row context-menu action (right-click on macOS,
/// long-press on iOS/iPadOS) that MANUALLY drives the two things a streamable catalog song added
/// to a linked pocket/playlist is supposed to get, when the automatic path silently skipped it
/// (Levi 2026-07-24 — the "Running It Up" case):
///
///   1. LIBRARY MEMBERSHIP. A song streaming from the Apple Music catalog is NOT necessarily in
///      the user's Apple Music *library* — you can stream any catalog track without adding it. So
///      "not in my Apple Music library" is often technically correct. This action adds it to the
///      library via the SAME `MusicLibraryContributor` path SongDetail's "Add to Apple Music
///      Library" uses — no new MusicKit logic here.
///
///   2. PLAYLIST WRITE-BACK. When the collection is a converted pocket / duplicated Apple Music
///      playlist, it pushes the song to the REAL Apple Music library playlist via
///      `CollectionsStore.forceWriteBackSong`, which reuses the durable `PlaylistWriteBack` queue
///      but BYPASSES the "already in the source snapshot" guard — the guard that makes a genuine
///      add read as "already upstream" and never send when a pocket's snapshot is stale.
///
/// Everything is append-only and idempotent (the queue's transport re-checks real membership before
/// it writes), so a force on an already-synced song is harmless. Feedback is explicit — success /
/// already-synced / why-not — because a silent skip is exactly the bug this rescues.
///
/// DEVICE-ONLY end to end: the simulator has no MusicKit account, so the library-add + write-back
/// deliveries are verified on a real device. The write-back DECISION (`forceWriteBackSong`) is
/// unit-tested with no account; the MusicKit half degrades to clear feedback everywhere it can't run.
enum CollectionForceSync {

    /// Run the force-sync for one catalog song in a collection and return a user-facing summary.
    /// `@MainActor` because it touches the main-actor stores + MusicKit.
    @MainActor
    static func run(song: IndexSong, kind: AddTarget.Kind, collectionId: String,
                    collections: CollectionsStore, streaming: StreamingStore,
                    writeBack: PlaylistWriteBack?) async -> String {
        var lines: [String] = []
        lines.append(await libraryLine(song: song, streaming: streaming))
        lines.append(writeBackLine(song: song, kind: kind, collectionId: collectionId,
                                    collections: collections, writeBack: writeBack))
        return lines.joined(separator: "\n\n")
    }

    // MARK: Library membership

    /// Add the catalog song to the user's Apple Music library if a contributor can, reusing the
    /// recognizer/SongDetail add path. Returns the line to show for that half.
    @MainActor
    private static func libraryLine(song: IndexSong, streaming: StreamingStore) async -> String {
        guard let contributor = streaming.providers.libraryContributors.first, contributor.canContribute else {
            return "Connect Apple Music (Settings ▸ Accounts) to sync this track to your library."
        }
        guard contributor.canAddToLibrary else {
            // macOS / Catalyst — `MusicLibrary.add` is unavailable there.
            return "Adding to your Apple Music library isn’t available from this device."
        }
        // Resolve the catalog identity + current library membership: prefer the indexed store id,
        // else an on-device title/artist search (the indexer-missed case). nil ⇒ no confident match.
        guard let resolution = await contributor.resolveForLibrary(
            storeID: song.appleMusicId, title: song.name, artist: song.artist) else {
            return "Apple Music has no confident match for this track, so it can’t be added to your library."
        }
        if resolution.inLibrary {
            return "Already in your Apple Music library."
        }
        do {
            try await contributor.addSongToLibrary(storeID: resolution.songStoreID)
            return "Added to your Apple Music library."
        } catch {
            return "Couldn’t add it to your Apple Music library: \(errMsg(error))"
        }
    }

    // MARK: Playlist write-back

    /// Force the collection's write-back for this song and translate the outcome into a line. The
    /// `.deduped` outcome is ambiguous by construction (the seam collapses "already queued", "no
    /// confident match", and "this device can't write back" into one false) so it's disambiguated
    /// here against the queue's own observable state.
    @MainActor
    private static func writeBackLine(song: IndexSong, kind: AddTarget.Kind, collectionId: String,
                                      collections: CollectionsStore, writeBack: PlaylistWriteBack?) -> String {
        switch collections.forceWriteBackSong(song.id, forTargetKind: kind, collectionId: collectionId) {
        case .notLinked:
            return "This collection isn’t linked to an Apple Music playlist, so there’s no playlist to add it to. Link it from the ⋯ menu to sync adds."
        case .pushDisabled:
            return "Sending to Apple Music is turned off for this collection (its sync is Get only / Off). Change “Apple Music sync” in the ⋯ menu to send adds."
        case .notCatalogSong:
            return "This item isn’t an Apple Music catalog track, so it can’t be added to a playlist."
        case .noIdentity:
            return "This track has no Apple Music identity, so it can’t be added to a playlist."
        case .queued:
            writeBack?.runSoon()
            return "Sending it to the linked Apple Music playlist now."
        case .deduped, .alreadyUpstream:
            // It IS linked and writable in principle — the seam declined. Say why.
            if writeBack?.canWriteBack != true {
                return "Apple Music playlists can’t be edited from this device, so it stays in your local copy."
            }
            if writeBack?.isUnsyncable(song.id) == true {
                return "Apple Music has no confident match, so it can’t be added to the linked playlist."
            }
            writeBack?.runSoon()
            return "It’s already on its way to the linked Apple Music playlist."
        }
    }

    private static func errMsg(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Row modifier

/// Attaches the "Force Apple Music sync" context menu (+ its result alert) to a collection song
/// row. Self-contained — owns its own result state so callers add it with one modifier and need no
/// shared plumbing. Applied only to CATALOG song rows in a pocket / playlist detail (studio
/// performance items have no Apple Music identity, so they don't get it).
///
/// `Extra` lets a caller fold its OWN row context-menu items (e.g. a playlist chapter's Move
/// up / Move down / Remove) into the SAME menu. SwiftUI does not merge stacked `.contextMenu`
/// modifiers — the outermost replaces the inner — so a caller that already owns a row context
/// menu MUST pass those items here, or the force-sync action gets shadowed (the playlist-row
/// bug: Levi 2026-07-24). Callers with no existing menu use the no-`extraMenuItems` overload.
private struct ForceSyncContextMenu<Extra: View>: ViewModifier {
    @Environment(CollectionsStore.self) private var collections
    @Environment(StreamingStore.self) private var streaming
    @Environment(PlaylistWriteBack.self) private var writeBack: PlaylistWriteBack?
    let song: IndexSong
    let kind: AddTarget.Kind
    let collectionId: String
    let extraMenuItems: Extra

    @State private var working = false
    @State private var result: String?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    guard !working else { return }
                    working = true
                    Task {
                        result = await CollectionForceSync.run(
                            song: song, kind: kind, collectionId: collectionId,
                            collections: collections, streaming: streaming, writeBack: writeBack)
                        working = false
                    }
                } label: {
                    Label("Force Apple Music sync", systemImage: "arrow.triangle.2.circlepath.icloud")
                }
                .disabled(working)
                .accessibilityIdentifier("force-sync-\(song.id)")
                extraMenuItems
            }
            .alert("Apple Music sync", isPresented: Binding(
                get: { result != nil }, set: { if !$0 { result = nil } })) {
                Button("OK") { result = nil }
            } message: {
                Text(result ?? "")
            }
    }
}

extension View {
    /// Add the collection-row "Force Apple Music sync" context menu for a catalog `song` in the
    /// collection `(kind, collectionId)`. See `ForceSyncContextMenu`.
    func forceSyncContextMenu(song: IndexSong, kind: AddTarget.Kind, collectionId: String) -> some View {
        modifier(ForceSyncContextMenu(song: song, kind: kind, collectionId: collectionId,
                                      extraMenuItems: EmptyView()))
    }

    /// Same, but folds the caller's own row context-menu items (`extraMenuItems`) into the SAME
    /// menu as the force-sync action — use this wherever the row already carries a `.contextMenu`
    /// (which would otherwise shadow the force-sync one). See `ForceSyncContextMenu`.
    func forceSyncContextMenu<Extra: View>(song: IndexSong, kind: AddTarget.Kind, collectionId: String,
                                           @ViewBuilder extraMenuItems: () -> Extra) -> some View {
        modifier(ForceSyncContextMenu(song: song, kind: kind, collectionId: collectionId,
                                      extraMenuItems: extraMenuItems()))
    }
}
