state: reviewed

# BRW-9 Recs core B: identity + shaping

- [x] RecIdentity.kt: RecVersionIdentity (+ credit keys, spaceless/ownership keys), RecVersionIndex, RecRecordingIdentity (union-find keepMask), RecMembership
- [x] RecShaping.kt: RecNovelty, RecComposition, RecSoundAdmit, RecAudioShortlist
- [x] version-identity-cases.json (39 cases), RecIdentityTest (15), RecShapingTest (16)

Tests: 1070 -> 1101 JVM tests, 0 failures; assembleDebug green.

Notes
- `RecVersionIdentity.key(title, artistKey)` iOS overload is `keyWithArtistKey` in Kotlin (same JVM signature as the (title, artist) overload).
- RecNovelty.primaryArtistKey reuses PuzzleSimilarity.artistKey (same as iOS). RecVersionIdentity.artistKey is the loose am-match key, deliberately NOT IndexArtist.normalize (as on iOS).
- Diversity floor port keeps iOS behavior of scanning past the lowest victim to higher ones (tested).
- No files outside owned set touched.

## Questions for Levi
None.
