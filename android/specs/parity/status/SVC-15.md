state: implemented

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
