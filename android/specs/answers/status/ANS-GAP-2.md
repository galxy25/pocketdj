state: reviewed

# ANS-GAP-2 - COL-9 complete: AM playlist sync reconcile (removals/reorders)

- [x] PlaylistReconcilePlanner (pure diff: removal-only deletes strays; reorder rewrites from first divergence; fail-closed on rows lacking ids)
- [x] PlaylistReconcileResult + sync step "Reconciling removals & reorders" (durable amPlaylistId link preferred over by-name; skips just-created; once per remote id; failures absorbed per playlist)
- [x] "reconciled" audit kind + summary text
- [x] Web-API transport reconcile (read rows load-bearing, empty target never touches anything, first-DELETE refusal => NotEditable, nothing appended)
- [x] Tests: PlaylistAppleMusicSyncReconcileTest (19). Suite 5430 total (was 5411), assembleDebug green.

## Files touched outside owned list (minimal, additive)
- data/applemusic/AppleMusicApiModels.kt (AmTrackPage.rows + AmTrackRow, defaulted)
- data/applemusic/AppleMusicApi.kt (allPlaylistTrackRows)
- data/applemusic/AppleMusicLibraryPlaylists.kt (PlaylistWriteBackTransport.reconcile default Unsupported; WebApi impl)
AMPlaylistSyncClient.kt unchanged (no client change needed).

## Deviations
- Apple's Web API has no replace-all; reconcile = DELETE library rows (undocumented endpoint, best-effort) + POST append. A half-applied reorder (delete ok, append failed) converges on the next push (append-missing).
- "Private-server branch": iOS has no separate private-server reconcile; its private-catalog mention is the pull-import mirror provenance, already ported (isAppleMusicSource accepts both Apple Music sources). Nothing further added.

## Questions for Levi
- Does Apple accept DELETE /me/library/playlists/{id}/tracks for Web-API-created playlists? Device-only; if refused, reconcile reports nothing and stays fail-closed.
- Flaky pre-existing: ReleaseFeedServiceTest.cachePersistsAcrossRelaunchAndCorruptFileIsHarmless failed once, passed on rerun.

## Review

fixes applied

- MAJOR upload/unmatched guard: fixed. Track rows no longer read a library id (`i.*` / `isLibrary`) as a catalog id, so the real upload shape yields catalogId null and the planner returns Unsafe (no DELETE). Test `transportRealUploadShapeNeverDeleted`.
- MAJOR double append on stale read: fixed. The planner re-adds only rows it deleted itself in this pass (removal-only => never appends; missing tail is the push's job). Test `transportStaleReadNeverAppendsTheJustPushedTail`.
- MAJOR canEdit: fixed. Reconcile GETs `/v1/me/library/playlists/{id}` before any DELETE and requires `canEdit == true` (absent => NotEditable). Test `transportCanEditFalseOrAbsentWritesNothing`.
- MINOR equivalent ids: fixed. Rows carry `equivalentIds` (non-library playParams id, purchasedId); a row matches a target song through its whole id set. Tests `equivalentCatalogIdIsTheSameSong`, `parserReadsEquivalentIdsAndIgnoresLibraryIds`.
- MINOR delete-by-song-id clash: fixed. Delete start is moved back (and removal-only is skipped) when a deleted library id also sits in the kept prefix. Test `prefixCopyIsNotDeletedWithItsLaterDuplicate`.
- NIT emulator/iOS wire fixture: deviation recorded. iOS uses MusicKit `edit`, so no wire fixture exists; the DELETE-then-POST order test `transportRemovesThenAppendsInOrder` stands in. No emulator was used in review.

Tests: 5436 run, 0 failed (6 added).
