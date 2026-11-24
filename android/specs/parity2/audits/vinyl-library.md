# Parity2 audit — vinyl / library / rip / burn / storage / recognizer / AM sync

Audited 2026-11-23 against `main` 4bcd08db (iOS = `apple/PocketDJ`, Android = `android/app/src/main/java/com/levi/pocketdj`).
Sources read: iOS commits since 2026-10-26 (`5932062e`, `db98dd1f`, `2163f8a3`, `1bad0e9d`, `67c26bd2`,
`b2c75f8a`/`5b1d7492`/`eb629fb0`/`f1083dbe`, `741e576d`/`15a8ec35`), memory notes `vinyl-album-side-playback`,
`storage-manager`, `recognizer-apple-music-add`, `queued-after-android-waves`, `history-default-and-album-artist-hotlink`,
and the Android code named below. Paths below are relative to those two roots unless absolute.

## TL;DR

The 1.0.5 vinyl work is entirely missing on Android, and Android's current analog playback has the exact defect
Levi fixed on iOS (songs cut at `startMs + duration`, the next song's opening under the old title). On top of that,
Android's set/Now Playing path plays the analog **per-song CUT** file for burned vinyl, which iOS never does: cuts are
burn-export sidecars still cut at catalog length on the server. Boundary edits can't reach Android either, because the
`edits` document isn't a sync key there. Smaller items: the credentials sync guard still compares exact URLs (the
2026-10-30 fleet token-wipe bug was never ported), the album page is missing the artist hotlink, queue menu, Stemify,
Edit and two-line rows, there's no in-app store-album page for the recognizer/For You, and the on-device
"Apple Music" library source (public mode) was never ported or audited.

Browse / Artists / History: iOS had no user-visible changes in these screens since 10-26 except Pocket Wheel
(History ▸ Pockets, a separate area) and DJ Mode/Remote hooks (other areas). Storage soft cap, the shazam
recognizer core and AM playlist sync with reconcile are already at parity (recorded as `present`).

---

## G1 — `AlbumFileTimeline` + `SegmentOverrides` (pure layout model) — MISSING · direct · ~350 lines (incl. tests)

iOS: `Playback/AlbumFileTimeline.swift` (whole file, 164 lines). Tests: `Tests/Unit/AlbumFileTimelineTests.swift`
(7 cases, port them as JVM goldens with the same numbers).

Android today: nothing. Each analog song is `PlayAction.Stream(url, clipStartMs = entry.startMs, clipEndMs = startMs + entry.durationMs)`
(`data/rips/PlayResolver.kt:55-63`) or `burnedLocalFile(...)` (`playback/sequencer/LocalFileResolver.kt:28-38`).

Create `data/rips/AlbumFileTimeline.kt`:
- `data class Segment(songId, startMs: Long)`; `AlbumFileTimeline(key, segments, exactEndMs, detectedEndMs)` with the
  constructor sort `(startMs, songId)` and the **drop-duplicate-start (keep first)** rule.
- `FADE_GRACE_MS = 15_000`.
- `forSong(songId, manifest, layout)`: null unless `manifest[songId].startMs != null`; members = `layout.albumTracks[layout.albumOfSong[songId]]`.
- `forKey(key, manifest, layout, members)`: every manifest entry with `e.key == key`, **skip non-members** (a stale
  re-split id would end a real song early), start = `layout.startMs[id] ?: e.startMs`.
- `next(after)`, `previous(before)`, `isLast`, `segment(atMs)` (a position before the first start = the first song, the lead-in).
- `endMs(of)`: `own = exact[id] ?: detected[id]?.plus(15_000)`; if `own == null || own <= start` → next start (null for the last song =
  file end); else `min(own, nextStart)`.

Create `data/rips/SegmentOverrides.kt` (`Snapshot(startMs, endMs, detectedEndMs, albumOfSong, albumTracks)` + pure `derive(albumEdits, rawAlbum, orderedSongIds, effectiveAlbums)`):
- detected ends + membership only for albums whose `audioTracks.size == trackList.size`;
- edit deltas matched onto the RAW album's segments: `trackNumber` first, else positional **only when the delta has no trackNumber**;
- skip an album whose ordered song count != segment count (never guess).
- Hold it as a `StateFlow<Snapshot>` owned by `CatalogRepository` and recompute on every catalog publish (iOS does it in
  `AppModel.assign`: `State/AppModel.swift` ~1521). Android hook: `data/catalog/CatalogRepository.kt` `buildCatalog`/`reapplyEdits` (line ~213).
  The playback layer must read the snapshot without the UI (it is a singleton on iOS for exactly that reason).

Invariant: **every reader of a shared-file start goes through the override.** iOS `RipsStore.effectiveStartMs`,
`BurnStore.startMs(forSong:)`, `MixStreamLoader` (`s.startMs = rips.effectiveStartMs(id)`). Android readers to switch
(grep `\.startMs` result): `data/rips/PlayResolver.kt:57`, `data/burns/BurnStore.kt:201-202` (`startMs(songId)`),
`playback/sequencer/BurnedRowResolver.kt:44`, `di/ServicesGraph.kt:134`, `di/MixGraph.kt:1022`,
`mix/stream/MixStreamLoader.kt:297,479`, `screens/mix/MixWaveform.kt:90`, `di/StudioGraph.kt:445,455,693`,
`screens/producer/cues/CuesScreen.kt:162-184` (+ `studio/cues/CueSeek.kt`). Add `RipsRepository.effectiveStartMs(id)` and make
`BurnStore.startMs` apply `SegmentOverrides.startMs(SongVariant.baseId(id)) ?: item.startMs` (only when the item has a start).

## G2 — Lone vinyl song ends at its end on the record (detected + 15 s, or edited) — MISSING · direct · ~150

iOS: `SetlistPlayer.sharedFileEndBoundaryMs` (`Playback/SetlistPlayer.swift:4019-4045`), `sliceLengthMs` (DSP engages, ~4083).
Android: the end is `startMs + manifest.durationMs` everywhere (`PlayResolver.resolve`, `burnedLocalFile`, `PlaybackController.playAlbumQueue`
lines 1070-1130, the "unbounded analog truncation" hack at 1098-1104, `mix/nowplaying/NowPlayingDspHost.kt:122` window length).
Change: a single `AnalogWindow.endMs(songId, startMs, timeline, run)` helper used by the resolvers. With a timeline:
`run.next?.startMs` (album run, see G3) / null when `run.fromPrevious && isLast` / else `timeline.endMs(songId)`.
Without a timeline: old `startMs + lengthMs`. The `isUnboundedAnalog` queue-truncation in `playAlbumQueue` becomes unnecessary once G3 lands.
Test: iOS `testLoneVinylSongEndsAtItsDetectedEndPlusGrace` + timeline goldens.

## G3 — Album run: one file end-to-end, glide, in-place ⏭/⏮, lead-in, waveform scrub — MISSING · equivalent · ~900 (incl. ~300 tests)

iOS (`Playback/SetlistPlayer.swift`): `albumRun` 4048, `albumLeadIn` 4067, `glideInSameFile` 4117 (`glideToleranceMs = 3_000`),
`jumpInSameFile` 4143, `retargetInPlace` 4163, `seekAlbumFile(toFileMs:)` 4203, `cueNextStart` 4235 (30 s expiry),
`albumFilePositionMs` 4093, `playerOwnsSideClock` 4102, advance hook 4400-4547 (`glideOnNextAdvance` set only on a NATURAL end;
`if cause == .user, jumpInSameFile(...)`), lead-in plumbing `RipServerPlaybackProvider.leadInSongId` (one-shot),
`RipsStore.play(..., leadIn:)` seekMs=0, `playLocalFile(..., leadIn:)` (`PlaybackCoordinator.swift`), card elapsed clamp
`max(0, currentTime - cardOffsetSec)` (`PlayerEngine.swift` ~1369), `PlayerEngine.retitleInPlace`.
Tests: `SetlistPlayerTests` 939-1160 (6 cases: glide without reload, run through the gap after a detected end, last song to file end,
skip seeks in place, album from the top starts at lead-in, scrub moves the deck).

Android today: `SetlistSequencer` loads ONE row per ExoPlayer item (`PlayerPort.load`, `playback/sequencer/PlayerPort.kt`), each with its own
`ClippingConfiguration` (`PlaybackService.SessionCallback.resolve`, `playback/PlaybackService.kt:780-797`); PB-10 preloads the next row into slot 1
(`NextRowPreloader.kt`). Every song boundary = a new item = a re-open + seek of the same mp3.

Android approach (equivalent mechanism, same user behavior):
1. **Run detection** in `SetlistSequencer` — port `albumRun(item, timeline)` verbatim: next = the timeline's next segment when it is also
   `queue[pos+1]` (by `SongVariant.baseId`) and the row won't replay (repeat ONE or `repeatCount > 1` ⇒ no run); `fromPrevious` likewise.
2. **One ExoPlayer item per run**: when the current row starts a run (or the run's first song is the record's first song and it starts fresh →
   lead-in), load the side file with a clip of `[leadIn ? 0 : songStart, C.TIME_END_OF_SOURCE)` and arm per-song boundaries in the sequencer,
   NOT in `ClippingConfiguration` (a clip change forces a re-prepare). Add to `PlayerPort`:
   `suspend fun armBoundary(fileMs: Long?)` (fires `handleBoundary(songId)` once) and `suspend fun seekInFile(fileMs: Long)`; implement in
   the Media3 adapter (`PlaybackController` as PlayerPort) with an ExoPlayer `PlayerMessage` at the position (exact, survives Doze) or a 250 ms
   position poll as fallback. **Seek BEFORE re-arming the boundary** (a tick still carrying the old position must not fire the new song's end).
3. **Glide** (natural boundary): if the playhead is within `[curStart, next.start + 3 000]` → retarget in place; if `next.start - pos > 3 000`
   (side flip / run-out after a lone song's detected end) → `seekInFile(next.start)` then retarget. Decline (fall back to a normal load) when:
   Now Playing DSP engaged (`mix/nowplaying/NowPlayingDspHost`), Stem Lock / local lane wanted, held deck (`isHeldForResume`/HeldQueue),
   Apple Music backend active, live HLS, DJ Mode tail deck owning audio, or the row would not resolve to the same backend family.
4. **Retarget in place** = the bookkeeping of a normal start minus the load: cancel `playTask`, bump `playGeneration` (stale resolves must not land),
   `coordinator.supersedePendingPlay` analogue, skip tracker `noteTrackRestarted`/re-arm, `currentPlaysRemaining`, history/play-stats/PlayEventBus
   track-start event, dead-air meter first-audio, rip-window reconcile, `prefetchUpcoming`, `persistSession(positionMs = 0)`, and **retitle** the
   session: `controller.replaceMediaItem(0, sameUriSameClip.withMetadata(newTitle, artist, art))`. Media3 1.6.1 `ProgressiveMediaSource/ClippingMediaSource.canUpdateMediaItem`
   allows a metadata-only update without re-prepare **only if URI and clipping are unchanged** — verify on the emulator (no STATE_BUFFERING,
   no discontinuity). Keep `MediaItem.mediaId = songId` updated: `PlaybackService.refreshCustomLayout` and the favorite command read it.
   Title must come from the CURRENT catalog (a waveform rename shows at once — iOS `catalogNames`).
5. **Song-relative clocks**: the run item's position is file-relative. `SequencerForwardingPlayer` (`playback/session/SequencerForwardingPlayer.kt`)
   must expose `currentPosition/duration` as `pos - songStart` / `songEnd - songStart` (clamped ≥ 0: lead-in shows 0:00) and translate lock-screen /
   Android Auto `seekTo` back to file-relative; SkipTracker high-water (`noteAdvanceAway` in `SetlistSequencer.kt:810`), listenedFraction,
   session snapshot `positionMs`, and the Glance widget all take song-relative values.
6. **In-place ⏭/⏮**: in `skipNext/skipPrevious` (`SetlistSequencer.kt:715-745`) after `index` moves, if the new row is a segment of the loaded file →
   `seekInFile(seg.start)` then retarget; a skip while paused starts playback (iOS `if player.pausedByListener { player.play() }`).
7. **Lead-in**: first song of the record, fresh start, no resume/cue, and it starts a run ⇒ start at file 0:00; the song's identity start is unchanged
   (boundary math). Never a negative cue; a restore/resume never uses lead-in.
8. **Last song through the album** (`run.fromPrevious && isLast`) arms no boundary and plays to the file's natural end (STATE_ENDED → normal advance).
9. **PB-10 preload**: never preload slot 1 when the next row is a run continuation (ExoPlayer would transition to a second item of the same file).
10. **Waveform scrub API** for G6: `seekAlbumFile(fileMs)` (same song ⇒ plain seek; other song of the side ⇒ `nearestOccurrence` forward-tie, index move,
    `noteAdvanceAway` + `noteUserTransport`, persist, seek-then-retarget; DSP engaged ⇒ `startPlayCurrent(resumeAtMs = fileMs - seg.start)`), and
    `cueNextStart(songId, atMs)` one-shot (30 s expiry) consumed by the next fresh start.
11. **Album ▶ must go through the sequencer**: Android's album "Play" uses `PlaybackController.playAlbum` → `playAlbumQueue` (an ExoPlayer-owned multi-item
    queue, `PlaybackController.kt:725-1130`), while iOS ▶ and 🔀 both use `collections.playNow(.album)` into the reserved Now Playing setlist
    (`AlbumDetailView.play(shuffle:)`). Route Android ▶ through `graph.collections.playNow(songIds, name, shuffle = false, SOURCE_ALBUM, originId)` like
    Shuffle already does (`screens/browse/AlbumDetailScreen.kt:176-196`), then delete the truncation hack; otherwise G3 has two code paths.
Other invariants: one audio owner (`SessionSwitchboard`); DJ Mode's "album run / album plays through" status words (iOS 2685-2770) belong to the DJ
area but must read the same `albumRun` helper; burned and streamed copies of the side are the same audio — a glide continues whatever file is loaded.
Accurate seeks: ExoPlayer's MP3 extractor seeks by constant-bitrate estimate unless the file has a Xing/VBRI TOC; if side rips are VBR without TOC,
enable `DefaultExtractorsFactory().setMp3ExtractorFlags(Mp3Extractor.FLAG_ENABLE_INDEX_SEEKING)` for analog keys (check a real side's header first).

## G4 — Burned vinyl in the set must play the SIDE file, never the per-song cut — PARTIAL (wrong) · direct · ~40

iOS: set/Now Playing/rows use `BurnStore.localURLForPlayback(forSong:)` (shared side + window); only Mix decks, Demux, sample carve and Mix waveform use
`localURLForPlaybackPreferringCut` (`State/BurnStore.swift:1048-1070`). Memory: "the analog CUT (`cutKey`) is BURN-ONLY — playback never touches it";
server cuts are still cut at catalog length (`cutDurationMs` in `scripts/rip-server.mjs`).
Android: `di/ServicesGraph.kt:131-137` builds the set's `BurnedRowResolver` from `burnStore.localUrlPreferringCut` → a burned analog song plays the
cut (cut short; glide impossible). Fix: `BurnedRowResolver.from(file = { burnStore.localUrlForPlayback(it) }, ...)` with `isCut = false` for the
sequencer + `PlayResolver.resolveBurnedFirst`; keep `localUrlPreferringCut` for Mix/Studio callers. Add a JVM test that a burned analog row with a cut
on disk resolves to the side file + window.

## G5 — `edits` document sync + live re-apply — MISSING · direct · ~120

iOS: `cloudSync.register("edits", fileURL: edits.syncFileURL)` with `reloadFromDisk()` + `app.applyEdits()` (`PocketDJApp.swift:1918-1924`),
file `pocketdj-edits.json` (`State/EditsStore.swift`). Android: edits are only a backup-restore artifact, `filesDir/backup-edits.json`
(`data/catalog/CatalogEdits.kt:186-210`, `data/backup/BackupModels.kt:161`), and NOT in any `SyncEntry`.
Without this, a boundary edit or rename made on the iPhone never re-times Android playback. Approach: rename to `pocketdj-edits.json`
(one-time migration from `backup-edits.json`), register `SyncEntry("edits", "pocketdj-edits.json", onPulled = { catalogEdits.invalidate(); catalogRepository.reapplyEdits() })`
in the services/collections graph, include in the account-deletion reset hooks, and write through a `VersionedJsonWriter`. Keep the iOS document shape
(`{schemaVersion, albums, songs, meta?}`; absent = no override; lenient per-entry decode). A pull must never push back (whole-doc LWW, no loop).
Re-derive `SegmentOverrides` on every reapply (G1).

## G6 — Album waveform editor on the album page — MISSING · direct · ~550

iOS: `Views/AlbumWaveformEditor.swift` (423 lines, not tvOS), mounted in `AlbumDetailView` under the header (self-hides when `starts == nil`).
Behaviour to port 1:1:
- Image: `RipManifestEntry.waveform` of any track (`rips/waveforms/<albumId>.png`, URL = `Endpoints.RIPS_BASE + "/" + key`; exists only after the
  album's first rip). Placeholder text "Waveform appears after the album's first play" / "Loading waveform…".
- `starts[i]` = `effectiveStartMs(trackList[i]) ?: overrides.startMs ?: (segs.size == ids.size ? segs[i].startMs : null)`; any missing ⇒ hide.
- `total` = the player's real duration when this side is loaded on the ExoPlayer (not the DSP), else `audioDurationSec*1000`, else `max(lastSeg.endMs, lastStart + 240 000)`.
- Regions tinted by each track's Camelot key colour (catalog camelot, else the segment's) at 0.26 alpha + a 3 dp solid key-coloured top edge;
  untinted gaps (region ends at the song's PLAYBACK end from `AlbumFileTimeline.endMs`). Titles under regions. Android has `KeyChip` colours — reuse that palette.
- Handles: band 22 dp above a 96 dp waveform; a handle per start + one for the side's end; drag (within 22 px), clamp with `minGapMs = 1000` between
  neighbours; tap a handle selects it → nudge bar −1 s / −0.1 s / +0.1 s / +1 s / "Set to playhead" / ✕.
- Tap or horizontal drag on the waveform = play from that point (`seekAlbumFile` when loaded, else `cueNextStart` + play the album from that track
  via the sequencer). A **vertical** pan that starts on the waveform must scroll the LazyColumn and neither scrub nor play (iOS `panIsVertical`).
- Double-tap a region = rename dialog → `SongEdit.name` (nil when equal to the raw name).
- Save boundary: rebuild one `AudioTrackEdit` per RAW segment (carry existing by trackNumber, else positional-without-number), set
  `deltas[i].startMs` (nil if equal to raw) and `deltas[i-1].endMs`; the end handle sets the last segment's `endMs`; `audioTracks = null` when every
  delta is empty. Editing is disabled unless raw `audioTracks.size == trackList.size`. Then persist (G5) + reapply + re-derive overrides; log
  `album boundary edit album=… index=… ms=…`.
- Readout: "N tracks · m:ss.t", while scrubbing "m:ss.t · Title", while dragging "Boundary m:ss.t" / "End m:ss.t"; footer hint copy as iOS.
- Live playhead at 4 Hz from `sequencer.albumFilePositionMs()` (song-relative DSP clock + start when engaged).
Android files: new `screens/browse/AlbumWaveformEditor.kt` (Compose `Canvas` + `pointerInput` with `detectTapGestures(onDoubleTap)` and a custom drag
detector that decides horizontal-vs-vertical before consuming), Coil for the PNG; reuse `screens/producer/common/WaveformView.kt` drawing helpers if
they fit; wire into `AlbumDetailScreen.kt` as an item after the header. Needs a small `EditsStore` write API on Android (today `CatalogEditsFile` is read-only).

## G7 — Album page parity: two-line rows, artist hotlink, queue menu, Stemify, track context menu — PARTIAL · direct · ~250

iOS `Views/AlbumDetailView.swift` vs Android `screens/browse/AlbumDetailScreen.kt`:
- **Two-line track rows** (iOS compact width = phones): line 1 = title up to 2 lines + E badge; line 2 = "BPM · key chip · time · ≤2 keywords"
  (fixed-size, keywords give way first); header "Title · BPM · Key · Time". Android `AlbumTrackRow` (line ~263) is single-line `maxLines = 1`.
  Use `WindowWidthSizeClass.Compact` (phones) for two-line; keep columns on tablets/foldables open.
- **Artist hotlink**: Android renders `album.artist` as plain text (line ~126). Add `onOpenArtist` → `nav.navigate(artistRoute(name))` in
  `shell/ShellNavigation.kt` ALBUM_ROUTE composable (ARTIST_ROUTE already exists at ~588). Direct push, album stays underneath for Back.
- **Album queue menu** (Play next / Play last / Add to playlist) beside the track count — Android has `screens/nowplaying/QueueAdd.kt` + `AddToPlaylistMenu`.
- **Track row long-press** context menu (Play next/last, Add to playlist) — Android rows only open the detail sheet.
- **Stemify album** (toolbar, disabled without a rip server, uses the collection controller's progress + over-cap confirm) — Android has
  `screens/playlists/CollectionBurnBar.kt` `stemify(ids, confirmLarge)`.
- **"Add to Apple Music again"** for a provisional Discover album (`amrec_album_…`) on the album page (+ "In your Apple Music library" receipt).
  Android has `AlbumLibraryWriteRetry` (`screens/discover/DiscoverRetryRow.kt`) and `BrowseGraph.retryAlbumLibraryWrite` but only on Discover results.

## G8 — Metadata edit sheets + Settings ▸ Edits — MISSING · direct · ~500

iOS: `Views/EditAlbumView.swift` (127), `Views/EditSongView.swift` (95), `Views/EditAudioAnalysisView.swift` (118; per-segment BPM/key/Camelot/start/end deltas),
`Views/EditsFile.swift` (export/import/clear in Settings). Android: none (Q115 built only the overlay). With G5 + G6 Android needs a writable edits store
anyway; add Edit buttons on the album page (album + audio analysis) and the song detail sheet, storing only fields that DIFFER from the raw catalog row
(`rawAlbum`/`rawSong` — Android must keep the pre-overlay catalog accessible from `CatalogRepository`). Import merges (imported wins per id); export stamps `meta{exportedAt, appVersion, platform:"android"}`.

## G9 — Credentials sync: same-HOST empty-token guard — PARTIAL (bug) · direct · ~30

iOS fix `1bad0e9d` (`Settings/SettingsCredentialsSync.swift` `keepLocalSecret` + `sameServerHost`): a pulled empty secret is ignored when the pulled URL
is the same HOST (case-insensitive) as the local URL, not the exact same string. Android `data/credentials/CredentialsSync.kt:111-112` still uses
`pulledUrl == localUrl` — an iOS device re-pointing the rip URL to `:10000` with an empty token wipes the Android rip token (all presign / rip-collection 401).
Port `sameServerHost` (trim; exact-equal shortcut; `Uri.parse(..).host?.lowercase()` compare; fall back to string equality) + the iOS test cases.

## G10 — Rip-server auth rejection is a credential hold, not "server down" — PARTIAL · direct · ~150

iOS `State/RipsStore.swift` (1bad0e9d): `RipError.unauthorized`, token-scoped `rejectedToken`/`rejectedAt`, `isAuthRejected`, `authHoldoff`
(`authReprobeSeconds = 120`), `noteAuthStatus` on every authed call, `BatchRipResult.refusedStatus`. Android `data/rips/RipServerClient.kt:539` only maps
401/403 to a message. Add the same token-scoped, self-clearing state to `RipsRepository`/`RipServerClient` (never persist or log the token), expose it to
the Rip/Burn bar copy ("The import server rejected this device's token (Settings ▸ Import server)") and to automatic callers (presign prefetch, burn
lane, rip window). The Mix crate-lane half of 1bad0e9d is the Mix area's.

## G11 — On-device "Apple Music" library source (public mode) — MISSING · equivalent · ~900

iOS: `State/AppleMusicLibraryStore.swift` + `Services/Streaming/AppleMusicLibraryIndexer.swift` (2026-07-29/30, never in the Android audits).
A signed-in user's own Apple Music library becomes a catalog source "Apple Music": songs `amlib_<libraryId>` (with `appleMusicId`, `dateAdded`,
album/track fields), albums, library playlists `amlibpl_<id>` (first injection source that emits playlists → converted-pocket follows / write-back work),
full vs incremental runs (`lastAddedMs` high-water), SUPERSEDE onto an indexed twin by `appleMusicId` with `supersededAddedAt` carried for Recently added,
synced as cloud key `apple-music-library` (whole-doc LWW, `pocketdj-apple-music-library.json`, optional `albums`/`playlists` keys so a missing key never wipes).
Android: Android's MusicKit SDK has no library reads, but the Web API with the MUT does: `GET /v1/me/library/songs?limit=100&include=catalog`,
`/v1/me/library/albums`, `/v1/me/library/playlists` (+ `/tracks`). `data/applemusic/AppleMusicApi.kt` already pages library playlists
(`AppleMusicLibraryPlaylists.kt`). Build `data/applemusic/AppleMusicLibraryStore.kt` (same JSON shape and ids so iOS and Android share the synced doc) +
`AppleMusicLibraryIndexer.kt` (WorkManager, after sign-in and daily), fold in through the merged-catalog injection path used by `DiscoverAddsStore` /
`ImportedSongsStore`, register the sync key. Verify whether library-song attributes carry `dateAdded`; if not, use first-indexed time and prefer a pulled
iOS doc's values. Value: a Play user with no private catalog sees their own library in Browse/Collections.

## G12 — In-app store album page (`AlbumPreviewView`) for recognizer / For You / Discover — MISSING · direct · ~450

iOS: `Views/AlbumPreviewView.swift` (pushed for `AppleMusicAlbumRef` from `NavigationDestinations.swift:44`): cover + MusicKit/REST tracklist, ownership-
aware "Add album to your library" / "Add remaining (n)" / "In your library" (`AlbumOwnership`), per-row ✓, Download (rip+burn album with ONE shared poll
loop), "Open album" when the catalog already has it, artist hotlink, "Add to Apple Music again". Android: the recognizer's `OpenRecognizedAlbum` opens the
Apple Music app/URL instead (`screens/settings/sections/AppleMusicRecognitionSection.kt:172-176` "No synthesized album page on Android");
`data/recs/AlbumOwnership.kt` is ported but has no UI consumer. Build `screens/discover/AlbumPreviewScreen.kt` over `AppleMusicApi` catalog album lookup +
`DiscoverAddController` album fan-out; route the recognizer, For You new-release rows and Discover album taps to it.

## G13 — Recognizer: edition swap before add (`VariantResolver.preferredStoreID`) — MISSING · direct · ~60

iOS `Views/Shazam/AppleMusicRecognitionSection.swift:261`. Android lists it as not ported (Q84). Before the library add / rip+burn, resolve the
explicit/clean twin per the edition policy (`data/edition/EditionPolicy`) so the add matches the user's preferred edition.

## G14 — Inline slide-out player under the playing row — MISSING · equivalent · ~250 (low)

iOS `Views/CollectionSongRow.swift` `InlinePlayerSlot`/`InlinePlayerPanel`/`InlinePlayerExpanded` (play/pause · title · collapse · ✕; song waveform
thumbnail with tap/drag seek; live HLS state; AM flavour "via Apple Music"). Android uses the global `MiniPlayerBar` + Now Playing deck instead. Low value
once G6 gives album pages a scrubbable waveform; port as an optional row-trailing panel on album/collection detail if wanted.

## G15 — AM sync: rejected Music-User-Token → reconnect prompt — PARTIAL · equivalent · ~60 (low)

iOS `67c26bd2` re-mints the MUT with `.ignoreCache` and retries a sync job once on "AM <METHOD> <path> -> 401|403". Android's MUT comes from the Android
MusicKit auth activity (`data/applemusic/MusicKitAuth.kt`) and cannot be silently re-minted; when a job fails with that pattern
(`data/applemusic/AMPlaylistSyncClient.kt`), clear the stored MUT and show "Reconnect Apple Music" in Settings ▸ Apple Music instead of failing daily.

## Cross-area row — Settings ▸ Storage "Mix Mode buffer" section

iOS `b2c75f8a`/`5b1d7492`/`eb629fb0`/`f1083dbe`: `BurnStore.TemporaryHold` ledger field (absent = pinned), `StorageManager.sweepTemporary`
(48 h TTL / 2 GB cap, stamp first, ledger-only plan, 25-hold chunks, protected window), Storage section (footprint, next expiry, TTL + cap pickers, per-song
rows, Keep all, Clear now, "Keep buffered files in shared/picked folders" toggle) + clock badge / Keep on song rows. Android has none of it
(`grep TemporaryHold` empty). It ships with NP Mix Mode (owned by that area's audit); the ledger field must stay additive-optional in
`pocketdj-burns.json` so iOS/Android ledgers round-trip.

## Present (recorded so nobody re-does them)

- Storage manager: soft cap GB/songs, stamp-first 20 h gate, one-scan `planEvictionSweepingOrphans`, 25-chunk async prune with protected set re-read
  (`data/storage/StorageManager.kt`, `transfers/StoragePruneWorker.kt`), delete by artist / collection / stems / all, SAF burn folder
  (`screens/settings/StorageScreen.kt`, `screens/settings/storage/*`).
- Shazam recognizer core: ShazamKit AAR backend, catalog match, AM library membership, add + rip+burn, "Open album" for indexed albums
  (`screens/shazam/*`, `screens/settings/sections/AppleMusicRecognitionSection.kt`). Gaps are G12/G13 only.
- AM playlist sync incl. reconcile (ANS-GAP-2), `amPlaylistId` persistence (ANS-COL-1), favorites two-way sync (COL-11) — device-only verification remains.
- Album audio-analysis table (`AudioAnalysisSection`), Shuffle into Now Playing, Share, Add-to-collection on the album page.

## Suggested package order

G1 → G4 → G2 → G5 → G3 → G6 → G7 → G8; G9 and G10 are independent one-day fixes (do G9 first, it is a fleet-wide data-loss guard);
G11, G12, G13 are a separate Apple Music library mini-program; G14/G15 last.
