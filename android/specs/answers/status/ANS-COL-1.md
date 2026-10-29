state: in-progress

# ANS-COL-1 — Persist amPlaylistId on Pockets AND Playlists

- [x] Kotlin: Pocket @Transient removed; PlaylistSerializer reads/writes amPlaylistId (lenient); sanitizePocketFlags drops non-string
- [x] Kotlin: PocketZip/PlaylistZip/CollectionFile envelope export strip the field; import upsert/remint still strip
- [x] iOS: CodingKeys + try? decode + memberwise inits (Pocket, Playlist); `strippedForExport` used in zips + exportPocket/exportPlaylist envelopes
- [x] Tests written (Kotlin + Swift)
- [ ] Gradle green / iOS unit run

Touched outside owned files: apple/PocketDJ/State/CollectionsStore.swift (exportPocket/exportPlaylist use strippedForExport, 2 lines).
