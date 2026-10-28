state: implemented

COL-1 Collections + activity schema parity.
- [x] CollectionSyncDirection enum; Pocket/Playlist amSyncDirection/cleanOnly/recsEnabled (+wantsRecommendations, amSyncDir)
- [x] Playlist codec lenient cleanOnly/recsEnabled; Pocket via codegen
- [x] Store setters (…ForPocket/…ForPlaylist; JVM clash on overloads), linkToAppleMusic (playlist) / linkPocketToAppleMusic
- [x] convertPlaylistToPocket provenance carry-over
- [x] ActivityKind catalogAdd/catalogRemove, itemArtist/originInstallId/libraryWrite, per-element skip doc serializer, record() stamps origin
- [x] fixture + tests (10 new JVM tests; suite 286 green)

Deviations:
- Roadmap says Playlist.amPlaylistId IS persisted; iOS Playlist CodingKeys (CollectionsSchema.swift:360) omit it, so neither type persists it (matches iOS, round-trip key sets).
- Touched outside owned files (additive): screens/history/ActivityRows.kt, HistoryScreen.kt (exhaustive `when` for new kinds).
- Pocket (codegen) is not lenient for wrong-typed cleanOnly/recsEnabled (drops that pocket); Playlist is lenient.
