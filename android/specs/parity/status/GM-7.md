state: implemented

# GM-7 In the Pocket store + PocketsBridge + rounds upload client

- [x] data/pockets/PocketsBridge.kt: PocketsBridge interface (isEnabled, results, refreshIfStale, flushSoon, roundsProvider, credentials, installId), PocketsCredentials(key, profileId, enrollSecret), NoPocketsBridge default
- [x] InThePocketInputs.kt: pure makeInput (catalog slice, playable = rips + burned + AM-with-appleMusicId, plays with outcome/tz, collections)
- [x] InThePocketStore.kt: build (refuse while building/active, replace unstarted, failure messages, seed string, algoVersion, bpm target, chips), start via GameRunPlayer under itp_<UUID> + 1 Hz ticker, resumeTrackingIfNeeded, evaluate (scoreboard + onRoundsChanged), saveFeedback, uploadWires, trim 300, clearLocal, per-element lenient Document
- [x] InThePocketRoundsClient.kt: POST /pockets/rounds, ack on 2xx only, 404 -> roundsServiceAvailable=false, cap 50, 90-day window + delete floor, device-local pocketdj-in-the-pocket-sync.json
- [x] GamesGraph: pocketsBridge, roundsClient, inThePocket (wired to catalog/rips/burns/collections/settings), reset hook, resume on init, debug `-e pdj.pocketsStub true`
- [x] backup_rules.xml (+ data_extraction_rules.xml): round document, tmp and sync file excluded from backup
- [x] Tests: InThePocketStoreTest (17), RoundsClientTest (12). Suite: 2909 tests, 0 failures.

## Notes / deviations
- Touched outside owned files: res/xml/data_extraction_rules.xml (additive excludes; Android 12+ needs them for the same guarantee).
- Rounds upload is Games-owned: the store's onRoundsChanged calls bridge.flushSoon() AND a 5 s debounced `roundsClient.flush` in GamesGraph (gated on bridge.isEnabled and credentials()). A real services bridge may instead call `gamesGraph.roundsClient.flush(creds, store.uploadWires(installId), installId)` from its own flush (after plays).
- Services wave: assign `GamesGraph.servicesBridge` before first `inThePocket` access. Debug builds default to a stub bridge (disabled until the pdj.pocketsStub extra) with empty results and no credentials, so it never networks.
- Cloud results only feed a build while bridge.isEnabled (privacy gate).
- Collections fed to the scorer carry no add timestamps (Android has no CollectionActivity flattening yet); scorer treats unknown as 0.75 scale.
- Listening-context guess is a seam (`contextGuess`), unwired (null) until the places/trips service exists.
- AudioAvailability.canStreamAppleMusic = settings.hasAppleMusic (AM-only songs ride as 30 s previews via GameRunPlayer).
- Store persists via coalesced off-thread writes (asyncPersist); `flush()` writes now.
- Emulator steps not run (emulator owned by integrator).

## Questions for Levi
None.
