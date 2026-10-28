state: implemented

# COL-3 SongDuplicateJudge + Remove duplicates

- [x] SongDuplicateJudge.kt (exact + same-release tiers, Seen, collapsePlan; no LLM tier, borderline => not duplicate)
- [x] CollectionsStore: duplicateIdentity, removeDuplicatesInPocket/InPlaylist/Everywhere (one save, no activity), Seen gates in reconcilePocket/reconcilePlaylist
- [x] RemoveDuplicatesDialog.kt (result alert), menu items in PocketDetail, PlaylistDetail, Playlists sort menu (with confirm)
- [x] Tests: SongDuplicateJudgeTest (13), RemoveDuplicatesTest (6). Suite 1639 tests, 0 failures.

## Notes
- Touched PlaylistDetailScreen.kt (not in owned list; audit names it): additive menu item + alert.
- Store API named removeDuplicatesInPocket/InPlaylist (Kotlin cannot overload on label).
- Test file named RemoveDuplicatesTest per roadmap (audit said CollectionsDedupeTest).
- Emulator step not run (shared emulator).

## Questions for Levi
None.
