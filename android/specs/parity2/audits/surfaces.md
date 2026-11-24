# Parity 2 audit: system surfaces, settings, shell, and the commit sweep

Audited 2026-11-23 against `main` (iOS 1.0.6 / Android 1.0.0 vc 1793909808). Read-only audit.
Both code bases were read for every row. Paths are repo-relative:
`apple/PocketDJ/...` (iOS) and `android/app/src/main/java/com/levi/pocketdj/...` (Android, written
`a/...` below).

Scope: Siri / App Intents (1.0.4) mapped to Assistant, App Actions, shortcuts and media voice
search; widgets (Glance); lock screen and media notification transport; CarPlay mapped to Android
Auto; Live Activity; Settings rows; onboarding; Producer/Studio/Games changes since 10-26; and a
sweep of all 93 `apple/` commits since 2026-10-26 (§9).

Several surface rows are thin wiring over engines that other parity2 areas own: NP Mix Mode, FX
Lock, DJ Mode (playback/NP area), the Pocket Wheel and pocket runs (pockets area), and Remote /
Backseat (remote/social area). Each such row lists its engine dependency under **Depends on**.
Schedule the surface after the engine.

---

## 0. Baseline: what Android already has (verified)

| Surface | Android files | State |
|---|---|---|
| Assistant `MEDIA_PLAY_FROM_SEARCH` (playlists, pockets, albums, songs by focus) + MediaSession search (Auto voice) | `a/assistant/MediaSearchHandler.kt` (`MediaSearchResolver`, `SearchPlayBridge`), `a/di/ShellGraph.kt:130-155` (candidates), manifest `MEDIA_PLAY_FROM_SEARCH` filter | present, but narrower than iOS (see S-1) |
| Static launcher shortcuts (Collections / Browse / Mix tabs) + dynamic shortcuts (most-recently-played playlists/pockets → `pocketdj://play/<kind>/<id>`) | `res/xml/shortcuts.xml`, `a/assistant/ShortcutsPublisher.kt` | present (the App Shortcuts / donations analogue) |
| `ShellActions`, the `IntentServices` analogue: playPlaylist/Pocket/Setlist/Song/Album/SongIds, startAutoMix/pause/resume, onboarding veto, `ensureReady` | `a/shell/ShellActions.kt`, `a/shell/MixFacade.kt` | present |
| Deep links: `pocketdj://{play,album,artist,playlist,pocket,setlist,jukebox,mwf,games,search}`, App Links for jukebox, collection files | `a/shell/DeepLinkParser.kt`, `a/shell/DeepLinkDispatcher.kt` | present |
| Glance Now Playing widget (S/M/L), file snapshot with iOS key names, ♥/repeat/shuffle queue when the graph is cold | `a/widget/*` | present, but no thumbs (S-9) |
| Media notification / lock screen: prev/play/next + ♥ custom button (exo owner only); media-button resumption after process death | `a/playback/PlaybackService.kt:456-462, 537-561`, `a/playback/session/FavoriteCommand.kt` | partial (S-8) |
| Android Auto `MediaLibraryService`: Continue · Playlists (user + source) · Pockets · Mix (two-crate Auto DJ remote + Jukebox sessions), Add-to chooser command, voice search | `a/auto/*`, `PlaybackService.kt:613+` | partial (S-12…S-15) |
| Onboarding (Profile → Apple Music → Sources; marker JSON; launch gate; mutating-intent veto) | `a/onboarding/*` | present; iOS `OnboardingStore` unchanged since 10-20 |
| Settings registry (D3) with ~24 sections | `a/screens/settings/SettingsSections.kt`, `sections/*.kt` | partial (S-17…S-20) |
| Live Activity analogue | Media3 ongoing media notification | present. **iOS has no Live Activity** (`grep ActivityKit apple/` finds nothing), so nothing needs porting. |

---

## 1. Voice: Siri / App Intents (1.0.4) on Android

### iOS inventory (verified)

`apple/PocketDJ/Intents/PocketDJShortcuts.swift` has all 10 App Shortcut slots in use:

| # | App Shortcut | Intent (file) | IntentServices door |
|---|---|---|---|
| 1 | "Add this song to {collection}" | `AddCurrentSongToCollectionIntent` (`SiriIntents.swift`) | `addSongToCollection(songId: nil, …)` (`IntentServices+Siri.swift`) |
| 2 | "Add a song to {collection}" (Siri asks "Which song?") | `AddSongToCollectionIntent` | `addSongToCollection(songId:…)` + `IntentSongMatcher` |
| 3 | "Play {collection}" | `PlayCollectionIntent` (pocket OR playlist, one entity) | `playCollection(id:shuffle:)` |
| 4 | "Shuffle {collection}" | `ShuffleCollectionIntent` | `playCollection(…, shuffle: true)` |
| 5 | "Play my pocket" | `PlayPocketForNowIntent` (`PocketWheelIntents.swift`) | `playPocketForNow()` → `PocketWheelService.refresh/play` |
| 6 | "Turn {on/off} Mix Mode" | `SetMixModeIntent` | `setNowPlayingMixMode(_:)` → `SetlistPlayer.setMixMode` |
| 7 | "Mute the {stem}" | `MuteStemIntent` | `setStem(_:muted: true)` |
| 8 | "Unmute the {stem}" | `UnmuteStemIntent` | `setStem(_:muted: false)` |
| 9 | "Auto mix {source}" | `StartAutoMixIntent` (`MixIntents.swift`) | `startAutoMix(source:shuffle:)` |
| 10 | "Create a pocket" | `CreatePocketIntent` | `createPocket(brief:targetMinutes:)` (FoundationModels) |

These intents are also kept for Shortcuts and Siri AI: Pause/Resume Auto-Mix (through the
lock-screen seam `MixEngine.remotePause/remotePlay`), the per-kind Play/Shuffle Playlist/Pocket
intents, the Spotlight `OpenIntent`s, `SearchLibraryIntent` (`.system.search`), and on iOS 27
`AudioSchema27.swift`, which adds `PlayAudioIntent` (songs and playlists by natural language) and
`AddToPlaylistIntent`. `SiriAITools.swift` gives 12 intents `ToolIntent` conformance, but only in
internal Xcode-beta builds. `NowPlayingSiriContext.swift` publishes the playing song as onscreen
context.

**Hard-won rules from the iOS code. The port must keep them:**
- **One parameter per phrase.** The pocket and playlist kinds fold into one `CollectionEntity`
  whose id is `"pocket:<id>"` / `"playlist:<id>"`, the `MixSource.id` encoding. Android
  `MixSource` already has the same shape (`a/shell/MixFacade.kt`).
- **Collection names are matched strictly** (`SiriEntities.swift:85-120`, `rankByName`,
  commit 922ea73c). First strip a leading "my"/"the" and a trailing
  "playlist"/"pocket"/"collection". Then accept only literal hits (equals > starts-with >
  contains). Fall back to a whole-name typo (OSA distance) only when nothing is literal. **Never**
  match by initials or subsequence ("Rap" must not land in "Rainy Afternoon Pop"). An exact name
  never prompts "which one?". The reason for the strictness: an add WRITES, and Siri runs a lone
  result without asking.
- **Song resolution** (`IntentSongMatcher.swift`). Read the whole phrase as a title, and also
  split it at the LAST " by " into title + artist. Title tiers: exact > exact without a
  parenthetical or "- Remaster" tail > prefix > whole-word substring > typo (OSA, run only when
  nothing literal matched). An agreeing artist adds score. Deduplicate by recording
  (`SongDuplicateJudge.key`) and cut to the top tier. The playing song and songs already in a
  collection win ties. Cache the normalized rows per catalog revision.
- **"This song" means the AUDIBLE owner.** A Mix-tab session that owns audio wins over a parked
  Now Playing set; otherwise use the Now Playing track, playing or paused
  (`IntentServices+Siri.swift:currentSongId`).
- **The add path equals the Add-to sheet** (`AddToActions.add`). A pocket gets membership; a
  playlist gets its FIRST chapter (`sequences.first?.nodeId`). An existing member is NOT toggled
  off; the app says "X is already in Y." Never target the reserved Now Playing playlist. The add
  must reach Recent, History ▸ Activity and the Apple Music write-back like a normal add.
- **Stems by voice mirror the panel order exactly.** Turn Mix Mode on if it is off
  (`setMixMode(true)`). If `!mixAvailable` (still downloading), say why using the chip text. Then
  `engageMix()`, `setStemMode(true)` if stems are off, and `toggleStemMute(name)` only if the stem
  is not already muted. Unmute touches only a stem that IS muted. Refuse while the Mix tab is live
  (one DSP surface at a time).
- **Every mutating voice door runs the onboarding veto and `ensureReady()`.** `ensureReady()`
  must return right after the disk-cache seed, because Siri's budget is about 10 s.
- **Never donate or publish the reserved `set_now_playing` scratch set.** Android already honours
  this in `ShortcutRanking.RESERVED_IDS`.

### Rows

**S-1 Voice play by name: songs, "my pocket", strict collection matching.** State: *partial*.
Android `MediaSearchResolver` matches collections and albums, and matches songs **only** when
Assistant sends `focus=audio`. An unstructured "play Make Me Proud by Drake on PocketDJ" lands on
Browse search instead of playing. Tier 1 is "every query token is covered by name tokens"; there
is no typo tier and no title/artist split. "Play my pocket" has no meaning on Android.
*Approach:*
- Port `IntentSongMatcher` to `a/assistant/IntentSongMatcher.kt` as pure Kotlin (normalized rows
  cached per `catalogRevision`), and port `rankByName` / `spokenName` into `MediaSearchResolver`.
- Resolution order for `MediaFocus.Any`:
  1. "my pocket" / "pocket for now" / "something that fits" → `ShellActions.playPocketForNow()`.
  2. A strict collection match → play it.
  3. A top-tier unique song → `playSong`.
  4. Otherwise → Browse search.
- Keep the shuffle keyword. Keep the `lastPlayedAt` tie-break after the iOS tiers.
- Apply the same resolver to `SearchPlayBridge`, so Auto voice benefits.
*Depends on:* the pockets-area Pocket Wheel engine (`PocketWheelService` port) for step 1. Ship
steps 2–4 independently.
*Lines:* ~350. *Value:* high.

**S-2 "Add this / a song to {collection}" by voice.** State: *missing*. Android has no voice or
shortcut route that adds to a collection.
*Approach:*
- Add `ShellActions.addSongToCollection(songId: String?, collectionId: String): AddResult`. Port
  `IntentServices+Siri.addSongToCollection` exactly (same dialog strings) over Android's add-to
  logic: the `AutoAddTargets`/`AddTo` sheet code path, so Recent / Activity / AM write-back fire.
- Add `ShellActions.currentSongId()`, mirroring the audible-owner rule through
  `SessionSwitchboard.current`. If the Mix owns audio, use the Mix's now-playing song; else use
  the sequencer's current row.
- Expose the action three ways:
  - **App Actions custom intents** (`shortcuts.xml` `<capability android:name="custom.actions.intent.ADD_TO_COLLECTION" app:queryPatterns="@array/add_to_collection_queries">` with a `collection` (and optional `song`) parameter → `pocketdj://add?collection=…&song=…`).
  - A deep-link verb `add` in `DeepLinkParser` (playback-free, veto-gated).
  - An AppFunction (S-6).
- Report results through `ShellActionException` → toast/notification. Android has no spoken
  dialog unless Assistant renders it.
*Feasibility:* equivalent. App Actions custom intents need Play Console upload + the App Actions
test tool. Gemini's support for App Actions on new devices is uncertain, so the deep link and
AppFunctions keep the capability reachable.
*Lines:* ~320. *Value:* high.

**S-3 Mix Mode on/off and mute/unmute stems by voice.** State: *missing*. Android has no NP Mix
Mode at all: `grep -ri mixMode a/` finds nothing. It does have the NP DSP + Stem Lock
(`a/mix/nowplaying/NowPlayingDspHost.kt`, `StemLock.kt`).
*Approach:*
- Add `ShellActions.setNowPlayingMixMode(on)` and `ShellActions.setStem(stem, muted)`, ported
  line-for-line from `IntentServices+Siri.swift` over the Android NP DSP host
  (`NowPlayingDspHost`: engage / stem mode / toggleStemMute).
- Add a `StemPart` enum with the spoken synonyms from `SiriEntities.swift:213-240` (vocals/voice,
  drums/beat, bass/bassline, other/instruments).
- Expose it through App Actions custom intents (`custom.actions.intent.SET_MIX_MODE`,
  `custom.actions.intent.MUTE_STEM` / `UNMUTE_STEM`), deep links
  (`pocketdj://np/mixmode?on=1`, `pocketdj://np/stem/vocals?mute=1`) and AppFunctions.
*Depends on:* playback/NP area porting NP Mix Mode (`SetlistPlayer.setMixMode`,
`mixAvailable`, `mixModeIndicator.chipText`). The stem half can ship first against today's NP DSP
if `mixAvailable` is approximated by "the current row is local or buffered".
*Lines:* ~220 (surface only). *Value:* medium.

**S-4 Auto-mix a source by voice or shortcut.** State: *partial*. `ShellActions.startAutoMix`
exists, but nothing outside the Mix tab and Android Auto reaches it: no deep-link verb, no
shortcut, no voice phrase. Pause/resume already work through the media session ("Hey Google,
pause").
*Approach:*
- Add a `DeepLinkParser` verb `automix/<pocket|playlist|setlist>/<id>[?shuffle=1]` → `ShellActions.startAutoMix` (veto + `ensureReady`).
- Add an App Actions custom intent `custom.actions.intent.AUTO_MIX` with a `source` parameter
  resolved by the S-1 strict collection matcher (setlists included).
- Add a dynamic shortcut "Auto-mix <last crate>". Rank it into `ShortcutsPublisher` with 1 slot.
- Keep the iOS result line: "Auto-mixing X — N burned songs" (it counts burned songs only).
*Lines:* ~140. *Value:* medium.

**S-5 Create a pocket from a spoken brief.** State: *missing*. It was recorded N/A in parity 1
because there are no Foundation Models on Android.
*Approach:* this is equivalent, not impossible. Port the pure steps of `PocketBuilder.swift`:
`PocketCandidateSearch` (exact year range, fuzzy genre via the Genre.category star-map, mood
similarity) and `PocketFitter` (90-minute fit), then `CollectionsStore.createPocket`.
- Parse the brief with a deterministic grammar: decade/year ranges, the genre list from the
  catalog, mood words from the sentiment vocabulary.
- Where it exists, use the on-device ML Kit GenAI Prompt API (Gemini Nano; Pixel 9+/S25-class)
  for the parse and curate steps. Detect availability at runtime; never make it a hard
  dependency.
- Replace NLEmbedding mood vectors with token overlap + the sentiment-keyword table. iOS already
  falls back to that.
- Run the build async. Surface status as a Collections-tab banner, as iOS does with
  `PocketBuilderService.phase` (iOS shows status only there).
- Doors: in-app "Create pocket…" sheet, App Actions `custom.actions.intent.CREATE_POCKET` with a
  free-text `brief`, and AppFunctions.
*Feasibility:* equivalent. LLM curation is device-limited; the deterministic path works
everywhere.
*Lines:* ~650. *Value:* low–medium.

**S-6 Siri AI tools → Android AppFunctions (Gemini).** State: *missing*. Closest analogue:
Jetpack `androidx.appfunctions` (Android 16 / API 36). Gemini calls the app's annotated functions
without fixed phrases.
*Approach:*
- Add an `a/assistant/PocketDjAppFunctions.kt` service exposing the same 12 tools: add (×2), Mix
  Mode, mute/unmute stem, play/shuffle collection, play my pocket, auto-mix start/pause/resume,
  create pocket.
- Each tool is a thin adapter over `ShellActions`. iOS does the same: intent structs are adapters
  and `IntentServices` owns the logic.
- Gate at runtime on `Build.VERSION.SDK_INT >= 36`. minSdk 35 stays.
*Feasibility:* equivalent. The library is alpha, so pin an exact version, and it reaches only
devices whose assistant supports AppFunctions. If the library is not stable at build time, defer
and keep S-2…S-5 reachable through App Actions and deep links.
*Lines:* ~350. *Value:* medium.

**S-7 Small voice/launcher extras.** State: *missing*.
- (a) Static shortcuts "Play my pocket" (`pocketdj://pocket-for-now`) and "Create pocket". Keep
  `ShortcutManagerSink.STATIC_COUNT` in sync.
- (b) In-app search action. Add an intent filter for `com.google.android.gms.actions.SEARCH_ACTION`
  and `android.intent.action.MEDIA_SEARCH` (the `MediaStore.INTENT_ACTION_MEDIA_SEARCH` constant)
  → `ShellRoute.BrowseSearch(query)`. This is the analogue of iOS `SearchLibraryIntent`.
- (c) Onscreen context: `MainActivity.onProvideAssistContent`. While Now Playing is visible, set
  `structuredData` (schema.org MusicRecording JSON-LD: title, byArtist) and a `webUri`, mirroring
  `NowPlayingSiriContext`.
- (d) "Add to Home screen" for a playlist/pocket via `ShortcutManagerCompat.requestPinShortcut`
  from the collection menu. This is the analogue of a user-made Shortcuts-app shortcut.
- (e) `PocketDjDestination.fromToken("Remote")` → `Jukebox` (iOS maps the retired Remote token
  into the Jukebox panel, `RootView.swift:88-90`).
*Lines:* ~260 total. *Value:* low–medium.

**Platform-impossible here:** Spotlight indexing of collections (`CollectionsDonations.swift`) and
the iOS 27 indexed audio-schema entities. Android has no public API that puts third-party app
content into system or launcher search. AppSearch `PlatformStorage` documents are visible only to
allow-listed system packages, and launchers do not query them. The dynamic and pinned shortcuts
(already present, plus S-7d) are what the launcher's search does surface.

---

## 2. Lock screen and media notification transport

iOS has `PlayerEngine.swift:1204-1240, 1287-1320, 1383-1389` and `NowPlayingArbiter`:
- `likeCommand` = ♥ Favorite.
- `changeRepeatModeCommand` / `changeShuffleModeCommand` are enabled only while a set runs. They
  are re-asserted on every card write and show `effectiveRepeatMode` (7fa721f4: a pocket run
  forces repeat off, and the repeat controls are inert during a run).
- A Mix-owned card disables `likeCommand` (`MixEngine.swift:6325`).
- In DJ Mode, a remote ⏭ (lock screen / CarPlay / widget) = the 5 s fast sweep
  (`skipNext(fast: true)`, e88622c9).
- A Backseat controller forwards every local transport to the Remote session (2b0e9d07,
  `SetlistPlayer.remoteControllerGate` / `routeListenerPlayPause`).

**S-8 Media notification buttons: shuffle, repeat, and 👍/👎 for recommendation queues.** State:
*partial*. `PlaybackService.refreshCustomLayout()` publishes only the ♥ (`FavoriteCommand.layout`).
Media3's default notification shows no repeat or shuffle.
*Approach:*
- Media3 1.6.1 is already on the classpath. Replace `setCustomLayout` with
  `setMediaButtonPreferences`. The button set:
  - ♥ (exo owner only; the existing Q27 rule);
  - shuffle (`ICON_SHUFFLE_ON/OFF`) and repeat (`ICON_REPEAT_OFF/ALL/ONE`), while
    `SequencerControl.isRunning` only;
  - 👍/👎 (`ICON_THUMB_UP`/`ICON_THUMB_DOWN`, filled vs outline), only while the current row is
    a recommendation (S-10's `currentRecTarget`). The pair is all-or-nothing, as in the CarPlay
    five-button rule.
- New `SessionCommand`s are `pdj.shuffle`, `pdj.repeat`, `pdj.rec.accept`, `pdj.rec.reject`. Add
  them to the trusted-controller set in `onConnect` (`PlaybackService.kt:477-483`).
- Rebuild on track change, favorite change, repeat/shuffle change and verdict change. Use the
  `RunTransportBus.stateChanged` hook that already exists.
- Android Auto renders the same preferences, which closes the CarPlay Now Playing button gap.
*Invariants:* repeat shows the EFFECTIVE mode (S-11). A 👎 never skips or pauses ("a driver
mis-tapping a thumbs-down at speed must not lose the song", `CarPlayScene.swift:666-672`).
Tapping the lit thumb clears it (toggle). A 👍 that lands `accepted` also adds the song to the
scoped collection (`IntentServices.recordNowPlayingFeedback`, line 570); reserved scopes
(zone/new) are feedback only, and an undo never un-adds.
*Lines:* ~240. *Value:* high.

**S-11 Surface transport follows new NP modes (effective repeat, DJ fast ⏭, Backseat
forwarding).** State: *missing* (engine-dependent).
- `SequencerForwardingPlayer.getRepeatMode` (`a/playback/session/SequencerForwardingPlayer.kt:211`),
  the widget snapshot (`WidgetInputs.repeatMode`) and the Auto/notification buttons must read
  `effectiveRepeatMode` once pocket runs exist. `setRepeatMode` must be inert during a run.
- When DJ Mode is active, `seekToNext` arriving from a remote (non-`callerInternal`) controller and
  the widget's NEXT must call the sequencer's `skipNext(fast = true)`.
- When the device is a Backseat controller, `play`/`pause`/`next` from the notification, widget,
  headset and Auto must forward to the session (iOS `routeListenerPlayPause()` is checked first in
  `WidgetSync.transportToggle`).
*Depends on:* pocket runs (pockets area), DJ Mode (playback area), Remote/Backseat (remote area).
*Lines:* ~80 surface wiring. *Value:* medium.

---

## 3. Recommendation thumbs on Now Playing (shared by every surface)

**S-10 Now Playing 👍/👎 for a recommendation queue.** State: *missing*. The Now Playing deck has
a seam `NowPlayingSeams.rating` (`a/screens/nowplaying/NowPlayingSeams.kt:17-19`), rendered at
`NowPlayingDeckCluster.kt:229`, but **nothing ever installs it**
(`grep "NowPlayingSeams.rating ="` finds nothing). Android has `RecFeedbackStore.scopeForPlaying`
(`a/data/recs/RecFeedbackStore.kt:348`) and `RecFeedbackButtons` (For You lists only).
*Approach:*
- Port `IntentServices.currentRecTarget / currentRecVerdict / recordNowPlayingFeedback`
  (`IntentServices.swift:520-575`) into a small `a/data/recs/NowPlayingFeedback.kt`. Use the
  sequencer row id + `scopeForPlaying`; return nil unless the standalone player owns audio.
- Install `NowPlayingSeams.rating` from `BrowseGraph` with `RecFeedbackButtons` bound to it.
- S-8 and S-9 consume the same object.
- Record the surface as `nowPlaying` / `widget` / `lockScreen` / `auto`, using iOS
  `RecFeedbackStore.Surface` raw values so synced feedback docs stay compatible.
*Lines:* ~180. *Value:* high. It unlocks the thumbs on the widget, lock screen and Auto.

---

## 4. Widgets (Glance)

iOS: `apple/PocketDJWidgets/NowPlayingWidget.swift` (S/M/L; `FeedbackPair` when
`recScope != ""`), `apple/Shared/NowPlayingSnapshot.swift`, `apple/Shared/WidgetTransport.swift`
(`WidgetCommandChannel.sendVerdict(songId:scope:verdict:)`). `apple/PocketDJ/Playback/WidgetSync.swift`
changed since 10-26 in three ways: effective repeat (7fa721f4), ⏭ = `skipNext(fast: true)`
(e88622c9), and the Backseat toggle (2b0e9d07).

**S-9 Widget 👍/👎 for recommendation queues.** State: *partial*.
- The snapshot carries `recVerdict`/`recScope`, but Android always writes "" ("Android has no
  For You verdicts yet", `a/widget/NowPlayingSnapshot.kt`). That premise is stale: Android has
  For You verdicts now.
- `WidgetCommand.Kind.VERDICT_ACCEPT/REJECT` exist, but `WidgetBridge.kt:44` drops them.
- `WidgetCommand` has no `scope` field.
*Approach:*
- Feed `WidgetInputs.recVerdict/recScope` from S-10.
- Render the pair in Medium/Large when `recScope` is non-empty. Use the existing
  `ic_widget_*` drawables plus two new thumb vectors.
- Add `scope: String? = null` to `WidgetCommand` (additive; old files decode).
- Make the drain apply the verdict to the **snapshot's** songId + scope, never to whatever is
  current at drain time. This is the iOS "self-contained verdict" rule (`NowPlayingSnapshot.recScope`
  doc).
- Verdicts never expire in the queue (already the policy). A thumbs-down followed by a ⏭ must not
  overwrite or lose the verdict (`WidgetTransport.swift:42`).
*Lines:* ~200. *Value:* medium.

**S-16 Widget picker preview.** State: *partial* (Q62 left the default as built).
`now_playing_widget_info.xml` has no `previewLayout`/`previewImage`, so the picker shows the
launcher icon. *Approach:* add an XML `previewLayout` (API 31+). Optionally use Glance 1.2
`providePreview` for generated previews on API 35+ (needs a Glance bump to an exact pinned
version). *Lines:* ~60. *Value:* low.

---

## 5. CarPlay → Android Auto

iOS: `apple/PocketDJ/CarPlay/CarPlayScene.swift` has a tab bar Playlists · Pockets · For You ·
Mix, an Up Next list with edit actions, Now Playing buttons (shuffle, repeat, ♥, 👍/👎, capped at
5), and pocket-wheel rows (`CarPlayPocketWheel.swift`, 1fa284b8). Android has the root Continue ·
Playlists · Pockets · Mix (`a/auto/AutoBrowseTree.kt:74-110`, `AutoMixTab.kt`).

**S-12 Auto "For You" tab (frozen) with "▶ Pocket for now" and "Pockets right now".** State:
*missing*.
*Approach:*
- Add `AutoId.Tab.Which.FOR_YOU("foryou")` plus nodes `fy:<tileId>` (tiles: New, In Da Zone,
  per-collection, in the phone's order). Build them from the **cached** `ForYouFeedStore`
  snapshot and `ForYouTiles.build`, the same function the phone grid calls, so the car cannot
  drift from the phone.
- New lists out-now releases only. The count on a tile equals the playable rows behind it.
- Release rows are namespaced `rel:` so they never collide with song ids.
- On a cold cache, show one non-playable row "Open For You on your phone to build your
  recommendations" (`CarPlayForYou.swift:coldFeedNote`).
- **Never refresh or rank on connect** ("the car must never be the surface that computes a
  ranking").
- Row actions: play now; "Add to pocket / playlist" through the existing `pdj.addTo` command
  button.
- Top section "Pocket": a playable row `pw:now` titled "▶ Pocket for now", subtitled
  "<collection> · Tue 8 AM" (`pocketForNowRow`); a browsable "Pockets right now" with the top 5
  moments within ±1 h across modes (`pocketsRightNow`), each playable via `playPocketMoment`.
  Car connected implies mode `carPlay`. On failure, show a "Couldn't play" error
  (`MediaLibrarySession` error result) instead of opening an empty player.
- Auto's root tab cap is 4 (8 on some hosts), so the root becomes Continue (conditional) ·
  Playlists · Pockets · For You · Mix. Check the host's `ROOT_LIST_MAX_ITEMS`
  (`androidx.media.utils.MediaConstants.BROWSER_ROOT_HINTS_KEY_ROOT_CHILDREN_LIMIT`). If the limit
  is 4, fold Continue into a top row inside Playlists. iOS CarPlay also caps at 4 tabs.
*Depends on:* pockets-area wheel engine for the Pocket section. Tiles can ship first.
*Lines:* ~450. *Value:* high (drive-time is a core use).

**S-13 Auto "Up Next".** State: *missing*. Media3 sees only ExoPlayer's 1–2 item window
(`SequencerForwardingPlayer` does not override `getCurrentTimeline`), so Auto's queue view shows
almost nothing.
*Approach:* add a browsable root-level (or Now-Playing-linked) node `upnext` listing the
sequencer's not-yet-played rows. Tapping a row is "play now" (the jump path the NP Up Next uses).
Per-row `setCommandButtonsForMediaItems` adds "Play next", "Move to end" and "Remove", mirroring
`CarPlayScene.presentUpNextActions`. On every sequencer change, call
`notifyChildrenChanged("upnext")`.
An alternative is a virtual `Timeline` over the sequencer queue. It is rejected: D11 says the
sequencer owns the queue, and a fake timeline invites `seekTo(index)` races.
*Lines:* ~250. *Value:* medium.

**S-14 Auto Mix tab live controls.** State: *partial*. `AutoMixTab.liveRows()` has status / New
Mix / pause / quick skip / long-blend skip / stop. iOS adds (37d128a6, still current):
- a Transitions section: FX Glide and Audio Glide toggles, plus Stop;
- FX rack slot on/off rows for the lead deck;
- Tempo − / + (0.01 step) and Pitch − / + (1 semitone), **disabled mid-transition**;
- Stems: a mode toggle plus 4 mutes (a mute with stems off turns stems on first, per the TV
  semantics);
- a catalog-shortfall row "Only N of M songs available — Rest not in this device's catalog yet —
  re-checks as it loads" (1bad0e9d copy).
*Approach:* new `AutoMixKind`s (`FX_GLIDE`, `AUDIO_GLIDE`, `FX_SLOT`, `TEMPO_DOWN/UP`,
`PITCH_DOWN/UP`, `STEMS`, `STEM_MUTE`, `SHORTFALL`) as playable action rows over `MixFacade` /
`AutoDj` lead-deck APIs. The `Mix` id codec already carries `a`/`b` payloads.
*Lines:* ~350. *Value:* medium.

**S-15 Auto source-playlist play origin attribution.** State: *partial*. The
`AppAutoServices.setFor(SOURCE)` call (`a/auto/AppAutoServices.kt:179-188`) calls
`collections.playNow(...)` **without `originId`**, so history records no `originCollectionId`.
iOS fixed the same bug in 7df7017f (CarPlay source playlists pass `originId: sp.id`). The Pocket
Wheel colours and pocket × collection stats depend on it.
*Approach:* pass `originId = sp.playlist.id`. Audit `ShellActions.playSongIds` callers for the
same omission. *Lines:* ~15. *Value:* medium (cheap, and a prerequisite for the wheel).

(The CarPlay Now Playing buttons are covered by S-8. Auto renders the session's media-button
preferences.)

---

## 6. Settings rows

The iOS order (`apple/PocketDJ/Views/SettingsView.swift:56-74`): identity · sources ·
collections · Apple Music · search · rip · jukebox · For You · recommendations · **Pocket Wheel**
(iOS only) · **Mixing (pane)** · storage · edits · backup · reset · debug.

**S-17 Settings ▸ Mixing pane (crossfades shared with DJ Mode, 7 DJ Mode toggles, Mix-tab
options + Volume Glide).** State: *partial*. Android `MixSection.kt` has the crossfade steppers
and Mix-tab options inline. It has no DJ toggles and no Volume Glide.
*Approach:*
- Turn the section into one "Mixing" row that opens a sub-screen
  (`a/screens/settings/MixingSettingsScreen.kt`) with three groups: Crossfades (lead 3–60, length
  1–12, skip fade 1–60, glide 1–30); DJ Mode (transitions, effect sweeps, tempo match, key/pitch
  match, volume leveling, tempo waves, pockets; all default ON); Mix tab (Volume glide (Auto-DJ),
  default OFF; auto-hide; cue channel; beat pulse; deck layout).
- Settings JSON keys must be iOS-verbatim: `djTransitions`, `djEffectSweeps`, `djTempoMatch`,
  `djKeyMatch`, `djVolumeLeveling`, `djTempoWaves`, `djPockets`, `mixVolumeGlide`. A missing key
  reads as the iOS default (DJ true, glide false). Keep the test tags from iOS ids
  (`settings-dj-*`).
*Depends on:* the DJ Mode and Volume Glide engines (playback/mix areas). The pane can land first
with the rows hidden behind the feature flags.
*Lines:* ~200. *Value:* medium.

**S-18 Now Playing Mix Mode buffer settings.** State: *missing*. iOS keys (SettingsStore diff
since 552abac7), shown in `MixingSettingsView` / `StorageView`:
- `npMixBufferAhead` (1/3/5/10, default 3);
- `npMixCellular` (`NPMixCellularPolicy` raw value, default `.nextSong`);
- `npMixModeDefaultOn` (default off);
- `npMixBufferTTLHours` (6/12/24/48/72/168, or 0 = Keep; default 48);
- `npMixBufferCapGB` (0.5–20, default 2);
- `npMixKeepPickedFolderBuffers` (default off);
- `lastTemporarySweepAt`.
*Approach:* add rows in Settings ▸ Storage (TTL, cap, keep picked folder) and Settings ▸ Mixing /
Playback (buffer ahead, cellular, default on), with key names verbatim. A corrupt or negative TTL
reads as the default, never as Keep or "expire now" (`npMixBufferEffectiveTTLHours`).
*Depends on:* playback-area NP Mix Mode + the temporary-hold ledger.
*Lines:* ~150. *Value:* medium.

**S-19 Settings ▸ Pocket Wheel ▸ "Notice walking & running" (+ "Adapt pocket runs").** State:
*missing*. Android declares no `ACTIVITY_RECOGNITION` permission (manifest verified).
*Approach:*
- Add `<uses-permission android:name="android.permission.ACTIVITY_RECOGNITION"/>`.
- Add a settings section `ListeningMotionSection.kt` with these rows:
  - the main toggle, which requests the runtime permission;
  - an "Adapt pocket runs to walking & running" toggle (iOS `ListeningMotionStore.adaptToActivityKey`);
  - a "Motion access" status row (Allowed / Not asked yet / Denied, plus an "Open Settings"
    intent when denied);
  - the privacy footer, worded per whether listening pockets are on (iOS copy verbatim, with
    "iPhone" → "this phone").
- Release paperwork: Play Data safety must add "Fitness info / physical activity" (W4 allows the
  upload).
*Depends on:* the pockets-area motion source. iOS uses a retroactive `CMMotionActivityManager`
query. **Android has no retroactive activity history**, so the port uses play-services-location
`ActivityRecognitionClient.requestActivityTransitionUpdates` (already on the classpath via
`play-services-location`) to record live transitions into a small ring buffer, which the settle
step reads. This needs a PendingIntent receiver and works while the process lives or the FGS
runs.
*Lines:* ~180 surface (engine counted in the pockets area). *Value:* medium.

**S-20 Settings ▸ Edits: export/import local metadata edits JSON.** State: *missing* as a
standalone section. Android exports edits only inside the backup zip (`BackupSection.kt:42`).
*Approach:* add an `EditsSection.kt` with "Export edits…" (SAF `CreateDocument("application/json")`,
default name `pocketdj-edits.json`, disabled when the count is 0) and "Import edits…"
(`OpenDocument`) over `CatalogEdits.exportData/importData` + re-apply. The footer shows the count
and the schema version. *Lines:* ~110. *Value:* low.

---

## 7. Producer / Studio / Games / onboarding since 10-26

- **Studio:** two iOS changes, both owned by other features.
  - **S-21 Studio explicit-use pins** (5b1d7492). Every explicit Studio use of a song's buffered
    audio pins it, so the Mix Mode expiry sweep can never delete it: Demux, Tracks stem import,
    new-sample-from-track, takes. iOS calls `burns.pin(songIds:reason:)` with reasons
    `tracks-stems` etc. *Approach:* add the same pin calls at the Android sites
    (`a/screens/producer/demux/*`, `a/screens/producer/tracks/*` stem import,
    `a/screens/producer/samples/*` new-from-track, the takes path in `a/studio/store/*`) once the
    temporary-hold ledger lands. *Depends on:* the NP Mix Mode ledger. *Lines:* ~40. *Value:*
    medium (prevents data loss).
  - `KeyDetector` gained a `maxSeconds` window (ac7dae40) for DJ progressive analysis. That is
    DJ-area work, no Studio UI change.
- **Games:** no iOS commits since 10-26 (`git log --since=2026-10-26 -- apple/PocketDJ/Games` is
  empty). Nothing to do.
- **Performance/Producer UI:** no commits since 10-26.
- **Onboarding:** `OnboardingStore.swift` / `Views/Onboarding` unchanged since 10-20. Android
  `a/onboarding/*` matches (Profile/AppleMusic/Sources raw 0/1/2). Nothing to do.

---

## 8. Not ported, by decision or platform

- Mac/iPad keyboard commands `⌘⌥M` (Mix Mode) / `⌘⌥J` (`PocketDJApp.swift:2515+`
  `NowPlayingControlCommands`, macOS only): N/A per the parity-1 multi-window decision.
- tvOS / visionOS shells (`TVRootView`, `TVRemoteView`): no Android TV/XR target.
- Spotlight donations / indexed entities: platform-impossible (see end of §1).
- iOS 27 audio-schema `PlayAudioIntent`: covered by S-1's song resolution (MEDIA_PLAY_FROM_SEARCH)
  plus AppFunctions (S-6).
- Live Activity: iOS has none. The Android media notification is the ongoing surface.
- Privacy manifest (8b8410f2) and ASC labels: the Android equivalent is Play Data safety. S-19
  adds "Fitness" and nothing else is needed.
- 67c26bd2 (MUT `.ignoreCache`) and 338400ab (emulator AM tokens): Apple-side token plumbing.
  Android's REST client already refreshes on 401/403 (`a/data/applemusic/AppleMusicApi.kt:435`).

---

## 9. Sweep: every `apple/` commit since 2026-10-26 (93), by owning area

Surfaces rows above are marked **(S-n)**. Everything else names the area that must carry it.
"no-op" means build, version, screenshot or test-only.

**Playback core / stall hop (playback area)**
- 5f5b5c74, 532ac59f: stall hop never resumes the deferred row's late resolve. Stall EPISODE
  rule: never hop back to a row abandoned in the episode; on-device preferred; no eligible target
  ⇒ keep buffering.
- fa8085da: release MusicKit on leaving Apple Music, plus a stray-play reclaim. Android
  `AppleMusicSessionCore` must stop + clear the AM queue on every leave.
- dd1f190c, 1bad0e9d: Mix stall / one audio owner / token rejection / "Play in Now Playing"
  fallback (`playMixCratesInNowPlaying`) → **mix area**. CarPlay shortfall copy → S-14.

**NP Mix Mode / FX Lock / Stem Lock (playback/NP area)**
- b2c75f8a, 5b1d7492 (Studio pins → S-21), 0d1d5d09, a9787b35, 08547f69, 0c607f96, 76dc87ed,
  b4d679e9, eb629fb0, df804136 (merge), a96a45b2, f1083dbe, ca14de1d, 428a16ef.
- FX Lock: 7c0828e2, 9797d1b2, d1ab06e0.
- Settings keys → S-18. Voice → S-3.

**Siri 1.0.4 (surfaces)**
- 8e6ebc1d → S-1/S-2/S-3/S-6/S-7c.
- 922ea73c (strict collection names) → S-1/S-2 invariant.
- d89d228d (Spotlight fingerprint gate; "Drop the <stem>" phrase removed, so do not add that
  synonym) → S-3.
- 6aaf068e: no-op (version).

**Vinyl / album (library area)**
- 5932062e: album side as one file + waveform scrub + boundary editor.
- db98dd1f: album plays end to end, skips seek in place.
- 2163f8a3: two-line album rows, key-tinted waveform regions.

**Remote / SharePlay / Mix Together (remote area)**
- ca15deb4, 692343db, 2b0e9d07 (widget/lock-screen Backseat forwarding → S-11), 7d9b708a,
  98484d49, 4c941a7e, 16cfd8f0, f9259495 (Remote folds into the Jukebox panel; retired "Remote"
  token → S-7e), fb4dd652, 8e32a039 (screenshots).

**DJ Mode (playback/mix area)**
- 17eff3c3, 75a9d0e0, bba72977, abbc4679, fb693252, 5cb33cdf (Settings section → S-17),
  24e9ab82, 2d0cc256, d4ce5efb, 6aa616cf.
- e88622c9: ⏭ mixes; remote/widget ⏭ = fast sweep (→ S-11); Settings ▸ Mixing (→ S-17).
- 75e265c8, 9d10a6a7, bdc7d841, a524839c, b59423f5, ac7dae40, 0926a3b5, 9aeac302, 0c696c9a
  (release blocker: NP ⏭ press gesture swallowed taps; Compose equivalent: don't put a
  `pointerInput` press detector over the ⏭ `clickable`), d8d2d40d.
- 16e2a6b0: Mix tab Volume Glide → mix area + S-17 row.

**Pocket wheel / pocket runs (pockets area)**
- 7df7017f: attribution + PlayEvent `motion`/`pocketRun` fields (Android `PlayHistoryModels.kt`
  lacks both: pockets area). CarPlay origin → S-15.
- 3bdadcb7: motion → S-19 settings.
- 58cd59a9, d28c08ac.
- 1fa284b8: CarPlay + Siri door → S-12, S-1.
- 35aadafe, 8ab55811, 3a48ba28 (merge).
- 59e3bba0: review fixes (repeat → S-11).
- 7fa721f4: effective repeat on widget/CarPlay/lock → S-11. Re-tuned badge + profile-cap 403 copy
  → pockets/recs areas.
- 379b38c5, 1cbbbbc4, c7a8d3a7, cdbf9e87 (artist spacing in DJ + pocket replan).

**Answers-program merges and fixtures (already on Android)**
- 552abac7, de44c281, 509b586f, 9d36a61c, b380cb75, 96de01d0, 0ab3f8e5, 15a8ec35, 741e576d.

**Apple-only / no-op**
- 67c26bd2, 338400ab, 8b8410f2.
- c8991d98, 6b2e915c, 5df05ec2 (versions/scripts).
- a36da0e4, 56f1f42e, 4cad5530 (screenshots).

---

## 10. Suggested package order for surfaces

1. S-15 (one-line attribution fix) and S-10 (NP thumbs), then S-8 (notification/Auto buttons)
   and S-9 (widget thumbs). All have no engine dependency.
2. S-1 steps 2–4, S-2, S-4, S-7 (voice + shortcuts over `ShellActions`). No engine dependency.
3. S-12 tiles, S-13, S-14 (Auto).
4. After the engines land: S-1 step 1 + the S-12 pocket section (wheel), S-3 + S-18 (NP Mix
   Mode), S-17 DJ rows (DJ Mode), S-11 (runs / DJ / Backseat), S-19 (motion), S-21 (ledger).
5. Optional / low: S-5, S-6, S-16, S-20.
