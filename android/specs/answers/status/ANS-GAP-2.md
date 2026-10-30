state: implemented

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
