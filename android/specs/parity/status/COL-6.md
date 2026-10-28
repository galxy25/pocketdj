state: merged

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

## Review
fixes applied
- MAJOR Collections drop targets unreachable: FIXED. Bottom-bar/rail nav items are DnD targets (`springLoadTarget`): hovering a song drag over an unselected tab for 600 ms switches to it, so the live drag carries into Collections row targets. Pure policy tested (SongDragSemanticsTest). Emulator step still device-only (integrator owns emulator).
- MINOR drag payload cap: FIXED. Drag carries SongTransfer via `localState` with a small label-only clip; drop reads localState first, clip decode as fallback. Clipboard copy keeps its cap + toast.
- MINOR long-press behavior: FIXED. Unselected rows drag a single-song payload (`rowSongId`); transfer starts only after moving past touch slop, so a stationary long-press keeps Add-to / select toggle on every row (onLongClick restored on selected rows).
- MINOR paste toast: FIXED. "Nothing to paste" vs "Already in this collection" vs "Pasted songs".
- MINOR ledger: FIXED. docs/ARCHITECTURE-ANDROID.md COL-6 row set to PARTIAL (emulator drag unverified).
- NIT typealias: FIXED. Deprecated `ui.selection.SongTransfer` alias kept.
- Tests: suite 4714, 0 failures (+3 SongDragSemanticsTest); assembleDebug green.
