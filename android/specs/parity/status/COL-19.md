state: merged

# COL-19 Listening places engine + location store

- [x] ListeningPlaceEngine.kt: pure port (ingest, movement hint, cluster/merge+aliases, ordered trip ids, lookup w/ 6 h horizon, currentGuess, rank labels A-Z/AA, prune)
- [x] ListeningPlacesStore.kt: ListeningLocationStore (default OFF, setEnabled(false) erases + deletes file, revision, trackingStartedAt, ListeningContextProviding), ListeningLocationSource, ListeningLocationAuthorization
- [x] Backup exclusions for pocketdj-listening-places.json (+ .tmp) in backup_rules.xml AND data_extraction_rules.xml (latter touched outside owned list; additive, required for API 31+)
- [x] Tests: 11 engine + 6 store = 17 new; full suite 5078 tests, 0 failures; assembleDebug green

## Deviations
- Times are epoch-ms Long in the doc (iOS stores Date reference-seconds). The file is device-local and never synced, so cross-platform shape compat was not needed. Field names otherwise match iOS (places/timeline/rawVisits/tripIds/aliases); ms fields carry an `Ms` suffix.
- Store defaults platformSupported=true with no source (LOC-2 supplies one); with no source authorization stays NOT_DETERMINED so isActive is false and nothing is ever stamped.
- Disabling deletes the file outright (iOS rewrites an empty doc), per the acceptance line.
- Store is synchronized + saves inline (doc is small); no coroutine scope needed.

## Questions for Levi
None.
