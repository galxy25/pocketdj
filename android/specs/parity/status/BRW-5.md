state: reviewed

# BRW-5 — Online OpenSearch (aoss) search

- [x] SearchConfig (user host override -> search-config.json bypassing HTTP cache -> baked default; reload on RemoteEndpoints generation = env + searchConfigURL)
- [x] SearchService (SigV4 aoss via existing net/SigV4, body/clauses/sort translation, parse, 15 s timeout, error "Search failed (code): body[:180]")
- [x] OnlineSearchModel (50/page, reset on any change, raw-count offset, stale-page drop via generation + from check, 10 000 cap, transient page error keeps rows, no-creds failed state)
- [x] SearchSettings (creds in SecretStore: searchAccessKeyId/searchSecretKey; host override pref `searchEndpoint`)
- [x] Settings "Online search" section (Configured badge, key id/secret/host override, Remove keys) registered through BrowseGraph
- [x] Browse: cloud toggle (Albums/Songs only; Artists always on-device), exact total in header, OnlineResults list/grid with infinite scroll, hit->row mapping with stub rows for hits not in catalog
- [x] Tests: SearchServiceTest (MockWebServer + SearchConfig), OnlineSearchModelTest, FilterQueryTranslationTest = 36 new tests; suite 1106 green; assembleDebug green

## Notes / deviations
- SigV4 signing itself already existed (net/SigV4.kt + SigV4Test, AWS vector) from SVC-5; reused, not re-implemented. SearchServiceTest asserts the signed-header set host;x-amz-content-sha256;x-amz-date, service aoss, payload hash.
- SearchService has a `baseUrl` test seam (production = https://<host>).
- The device-side local pipeline still recomputes while online mode is on (wasted CPU, no visible effect); a later cleanup could gate it.
- Legacy `onlineSearchEnabled` pref is left unused; the mode is BrowseSession.searchMode (already persisted in the browse snapshot).
- Touched outside owned files: none (DataSourcesSection's stale "toggle removed" comment left alone).
- Emulator steps (paste key, 'midnight' paging, BPM sort reset) not run: shared emulator is integrator-owned.

## Questions for Levi
- None blocking. Credentials are Keystore-only and not synced between devices (iOS syncs them via SettingsCredentialsSync; that belongs to the profile-sync packages).

## Review
- OnlineResults stub rows dead end (MINOR) -> fixed: tap/play/add on hits not in the catalog are disabled (no-op) rather than landing on not-found. Full stub-through navigation not done.
- Creds false "Add credentials" flash (MINOR) -> fixed: creds load tracked as not-yet-read; search waits for first read.
- Local pipeline recompute in online mode (MINOR) -> fixed: produceState keyed to constant "online" and returns early.
- False "No matches" during debounce (MINOR) -> fixed: searchDebounced sets Loading when creds present; test added (1107 tests, 0 failures).
- Toggle hidden on Artists (NIT) -> not changed (Artists is always on-device; optional).
- Save with only one field (NIT) -> fixed: snackbar asks for both fields.
- Host override seed ordering (NIT) -> not changed (hidden by 300 ms debounce; optional).

fixes applied
