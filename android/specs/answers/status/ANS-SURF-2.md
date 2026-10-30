state: reviewed

# ANS-SURF-2 status
- [x] ShellActions.playSetlist(id, shuffle) (+ SetlistNotFound, SOURCE_SETLIST, frozen repeats kept, text cues dropped, onboarding veto)
- [x] ShellGraph playItem seam routes Playlist/Pocket/Setlist/Album all through ShellActions (setlist no longer a screen-open)
- [x] scripts/jukebox-site/.well-known/assetlinks.json (debug SHA-256 real; direct-signing + Play App Signing are REPLACE_WITH_* placeholders)
- [x] scripts/publish-jukebox-wellknown.sh (uploads AASA + assetlinks, invalidates PDJ_CF_JUKEBOX, curls both; refuses while placeholders remain)
- [x] README-universal-links.md Android section; .well-known/apple-app-site-association copy
- [x] Tests: ShellActionsTest.playSetlist..., DeepLinkDispatcherTest x3 (4 new). Full suite 5415 tests, 0 failures; assembleDebug green.

## Notes
- DeepLinkDispatcher's no-seam fallback unchanged (default still opens screen); only the graph seam changed.
- Nothing uploaded to S3/CloudFront (needs Levi's OK).

## Questions for Levi
- Provide release keystore SHA-256 and Play App Signing SHA-256 to replace the placeholders in assetlinks.json.
- OK to run scripts/publish-jukebox-wellknown.sh (S3 profile levi + CloudFront invalidation)?

## Review
- MAJOR playSetlist drops frozen variant -> fixed: new CollectionsStore.playNowRows plays saved rows verbatim; test playSetlist_keepsFrozenVariantRepeatsDuplicates...
- MINOR ghost rows / repeat map collapse -> fixed (same change; duplicates and ghost rows keep their own repeat; tested)
- MINOR no markPlaylistPlayed / reserved id clobber -> fixed: stamps origin playlist; NOW_PLAYING_SETLIST_ID replays in place without playNow (tested)
- MINOR seam untested -> fixed: playLinkSeam extracted (shell/PlayLinkSeam.kt), ShellGraph uses it; test playLinkSeam_setlistPlaysThroughActions_andFailuresPostMessage. Test count 5415 -> 5417, 0 failures, assembleDebug green.
- MINOR publish script check -> fixed: waits for invalidation, exits non-zero unless 200 + application/json + 0 redirects
- MINOR assetlinks placeholders -> accepted as open: state of those acceptance items stays blocked on Levi (release + Play SHA-256, publish, verify-app-links)
- NIT duplicate AASA -> fixed: .well-known copy removed; script uploads scripts/jukebox-site/apple-app-site-association
- NIT navigate to Now Playing after link play -> rejected/deferred: needs a new ShellRoute variant touching several exhaustive whens; optional

fixes applied
