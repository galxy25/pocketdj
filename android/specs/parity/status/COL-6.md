state: implemented

COL-6: Song drag & drop + clipboard (SongTransfer, SongDrop, Compose DnD, paste).

- [x] SongTransfer moved to data/collections/SongTransfer.kt (iOS JSON shape, 8MB cap, 200-line text cap) + SongDrop (acceptableIds: dedupe, 100k ids / 128 chars, resolve gate; accept = one addSongs) + fromClipTexts (label-gated decode)
- [x] ui/dnd/SongDragDrop.kt: songDragSource (long-press-drag, in-app only, chip decoration), songDropTarget (ROW fill / LIST outline highlight only while hovered), clipboardHasSongs, acceptSongsInto, pasteSongsInto
- [x] Collections list: playlist + pocket rows are drop targets (default chapter / pocket); folder headers and source rows are not
- [x] Playlist + pocket detail: whole-list drop target, SelectionScope paste target, "Paste songs" overflow item
- [x] Browse songs + selectableRow: a SELECTED row is the drag handle (drags the whole selection)
- [x] Tests: SongTransferTest (6), SongDropAcceptableIdsTest (5); suite 4711, 0 failures; assembleDebug green

## Deviations / notes
- Touched outside owned files (additive): CollectionsStore.songResolves (resolve gate = catalog OR studio info), RowSelection.kt (SongTransfer moved out; import), imports in Pocket/Setlist/SourcePlaylist detail screens and tests, PocketDetailScreen.kt.
- Drag starts only from a selected row (long-press on an unselected row keeps its COL-4 Add-to / select behavior); long-press on a selected row no longer toggles it off.
- Drag is in-app only (no DRAG_FLAG_GLOBAL), so nothing leaks to other apps.
- Emulator drag not run (integrator owns emulator).

## Questions for Levi
- Should long-press-drag also work from an UNselected row (single-song drag), as iOS `.draggable` does?
