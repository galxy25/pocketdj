state: implemented

Tests: MixSessionCsvTest, 5 new tests; full JVM suite + assembleDebug green. Build needed -Pkotlin.daemon.jvmargs=-Xmx4g once (OOM under concurrent builds).

# ANS-GAP-7 MIX-15 complete
- [x] MixSessionCsv.kt (iOS columns via shared TracklistCsv; filename rules)
- [x] Session detail overflow menu "Export tracklist (CSV)" via CollectionExporter (SAF CreateDocument)
- [x] Load card tap -> SongDetailSheet (iOS handleTap; falls back to playhead jump if song not in catalog)
- [x] Wrapped tablet layout >= 600dp (3/row, 5/row >= 900dp, arrows + wrap arrow)
- [x] MixSessionCsvTest (CSV + ReplayLayout)
## Notes
- Touched nothing outside owned files; reused ExportRequest/rememberCollectionExporter (ANS-COL-3) and SongDetailSheet.
- No manifest/proguard changes, so assembleRelease not run.
