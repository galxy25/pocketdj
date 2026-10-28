state: merged

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

## Review
fixes applied
- MAJOR normalized/loose/tokens non-Latin semantics -> fixed: diacritic fold limited to combining-diacritical blocks; alnum filter is code-point based over L*/M*/N*; tests added (Ⅱ vs Ⅲ, Devanagari, が vs か). Suite 1642 tests, 0 failures.
- MINOR emulator step never run -> PARTIAL: reviewer was forbidden the shared emulator; step OUTSTANDING for the integrator (seed twin ids, ⋯ > Remove duplicates => "Removed 1 duplicate"; all-collections => "No duplicates found").
- MINOR PlaylistDetailScreen.kt shared touchpoint with SVC-4 -> acknowledged: additive single menu item + alert; integrator should merge after SVC-4 and keep both items.
- NIT empty-playlist disabled item -> skipped.
- NIT rememberSaveable for dedupeResult/dedupeConfirm -> fixed.
- NIT ARCHITECTURE-ANDROID ledger row -> left to the orchestrator at integration.
