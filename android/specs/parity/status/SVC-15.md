state: reviewed

# SVC-15 Apple Music Web API client
- [x] AppleMusicTokens (interface + Default/Static impls)
- [x] AppleMusicApiModels (lenient JsonElement parsers; null = unreadable)
- [x] AppleMusicApi (catalog search, artists latest-release, storefront, library playlists list/create/add/remove, addToLibrary, rate/unrate/star/lovedIds)
- [x] Tests: AppleMusicApiTest (22), AppleMusicApiModelsTest (8), all green

## Notes / deviations
- Results are a sealed AmResult (Ok/NeedsUserToken/RateLimited/Failure), no exceptions.
- removeTracksFromPlaylist is best-effort: Apple documents no remove endpoint; a 4xx surfaces as Failure.
- Not wired into AppGraph (outside owned files); consumers construct `AppleMusicApi(http, DefaultAppleMusicTokens(devTokenClient, settings))`.
- No other files touched.

## Questions for Levi
- None.

## Review
fixes applied
- MAJOR playlistTracks 404 -> fixed (404 = empty page Ok; added allPlaylistTrackCatalogIds walker; tests for 404/walk/unparsable next)
- MINOR invalidateDeveloperToken no-op -> fixed (MusicKitDeveloperTokenClient.invalidate() clears memory + Settings; Default tokens override; interface fun now suspend)
- MINOR artists truncation -> fixed (batched at 50, any non-Ok batch fails whole call)
- MINOR test coverage -> fixed (parameterized 401/429/no-MUT over all 13 user endpoints + catalog endpoints). Full suite 1939 -> 1953 (AppleMusicApiTest now 39). Docs ledger row in docs/ARCHITECTURE-ANDROID.md is left to the integrator.
- MINOR 429 backoff -> fixed (15 s total sleep budget per call, then RateLimited immediately)
- NIT token header IllegalArgumentException -> fixed (trim + catch -> NeedsUserToken/Failure)
- NIT allLibraryPlaylists unparsable next -> fixed (AmPage.hasCursor; fall back to offset += items.size)
