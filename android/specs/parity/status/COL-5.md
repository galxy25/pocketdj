state: implemented

COL-5: Multi-select (RowSelection + SelectableRow + SelectionBar), Android port.

- [x] RowSelection.kt: scoped select mode, select-all over full universe, prune, ordered payload, active-list/paste registration, SongTransfer (iOS JSON shape, 8MB decode cap, 200-line text cap)
- [x] SelectionUi.kt: selectableRow/selectionDecor/selectionTap, SelectionScope (register/prune), SelectionBar (count, Select all, Add to Recent/Pockets A-Z/Playlists A-Z, Copy, Clear), clipboard write/read
- [x] CollectionsGraph.rowSelection (single window instance)
- [x] Wired: Browse songs list (scope "browse"), pocket, playlist (node-id keyed, nodes->song ids), source playlist (index keyed), setlist (position keyed)
- [x] Tests: RowSelectionTest (13) + SelectionBarSemanticsTest (5); full suite 2461 tests, 0 failures; assembleDebug green

## Deviations / notes
- Touched outside owned files (additive): SourcePlaylistDetailScreen.kt, SetlistDetailScreen.kt (goal asks for source-playlist + setlist wiring).
- Browse songs long-press now ARMS select mode (was: open Add-to menu). Add-to for a song is via the selection bar, the song detail sheet, and Online results (unchanged). Album long-press unchanged.
- No hardware-keyboard modifier range/toggle (Mac/iPad-only in the audit). Paste target is registered/testable but no UI invokes paste yet.
- Selection survives an Add (as iOS); a Toast reports "Added N to X".
- Setlist/source rows keyed by position (repeated songs possible).

## Questions for Levi
- Should Browse long-press keep a quick single-song Add-to (as before) in addition to arming select mode?
