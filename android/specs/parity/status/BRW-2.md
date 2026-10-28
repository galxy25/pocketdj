state: reviewed

# BRW-2 Filter/sort sheets + membership + favorite + hide-skips read-time layers

- [x] ReadTimeFilters.kt: MembershipFilter, applyMembership/applyFavorites (nullable provider)/hideSkips
- [x] ClauseEditor.kt: ClauseReducer (pure) + ClauseEditorRow (field/op/value, multi-select, comma list, date pickers)
- [x] MembershipSection.kt, BrowseFilterSheet.kt rebuilt as clause editor (full-height sheet, Add/Remove, Clear all)
- [x] BrowseModels: BrowseFilters.membership/hideSkips (transient), clearedAll, glyphLit, activeCount(kind, historyMode)
- [x] BrowseScreen: favorites + membership applied at read time after the memoized pipeline; paging key = constraints only

## Deviations / notes
- Hide skips toggle + historyMode params exist on BrowseFilterSheet but HistoryScreen (other package) does not call the sheet yet; ReadTimeFilters.hideSkips is ready.
- Old quick genre/BPM/key chips replaced by generic clauses (SourcesRail still uses withSources).
- Membership alone lights the toolbar glyph (bare badge), not counted (iOS parity).
- No files touched outside owned list.

## Questions for Levi
None.

Tests: see commit message / head.
