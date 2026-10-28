state: reviewed

# COL-16 — Listening pockets wire models, client, CollectionFlattener + collections payload

- [x] CollectionFlattener.kt (flatten/pocketSongs/playlistSongs/capped/expand/addTimes/addEvents)
- [x] ListeningPocketsModels.kt (upload batch/event/collection/addEvent/place/trip wires, upload response; results decoder already exists from GM-5 in PocketsModels.kt and is reused)
- [x] ListeningPocketsClient.kt (OkHttp Call.Factory; events/results/deleteState/health; 403 body mapping, 404 => NotFound)
- [x] ListeningPocketsCollections.kt (caps, hash, isDue, byte cap, context mapping)
- [x] Tests (4 files, 20 new tests; full suite 4187 tests, 0 failures)

## Notes / deviations
- No postRounds in the client: rounds upload already lives in InThePocketRoundsClient (games area).
- Results decode is not duplicated; client calls ListeningPocketsResults.parse.
- Byte cap enforcement (iOS only declares the constant): payload sheds oldest add events, then trailing collections, and re-hashes.
- Client takes PocketsCredentials (existing type) instead of key/profileId; device header via an optional lambda.
- No files outside owned set touched.

## Questions for Levi
None.
