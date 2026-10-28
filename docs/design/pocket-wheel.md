# Pocket Wheel + adaptive 100-song pocket runs (design, 2026-10-28)

Status: DESIGN ONLY. No code has been written. Branch to use when building: `feat/pocket-wheel` (sub-branches per phase).
Platforms: iOS/iPadOS first (macOS and visionOS get the wheel for free; tvOS has no History tab and is skipped), then Android.

## 0. Levi's ask, restated as requirements

| # | Requirement | Where in this doc |
|---|---|---|
| R1 | Pockets are shown as a **colour wheel**: 24 hour segments around, **7 weekday rings** | §2 |
| R2 | Within a ring cell, **modes** (CarPlay / Mix / Browse / trip …) are told apart | §1.3, §2.3 |
| R3 | New modes: **running vs walking** | §1.4 |
| R4 | The dominant feature, and the colour, is the **collection the music came from** (playlists like Potential, Favorites, pockets) | §1.5, §2.4 |
| R5 | A **centre ▶** plays the pocket that best matches *now* (time, day, location, previous activity) | §3 |
| R6 | A pocket run is **capped at 100 songs** | §4.1 |
| R7 | Skips inside a run **re-tune the run live**. Example: skipping Drake replaces the upcoming Drake songs with songs by *other* artists that sound similar and fit the pocket | §4.3–4.5 |
| R8 | What was learned carries into **future runs of that pocket** | §4.6 |
| R9 | Zero dead air (the standing rule) | §4.4 |

Vocabulary. The code already has `Pocket` (the collection DAG, `CollectionsSchema.swift`) and `ListeningPocket` (cloud-detected grooves, `ListeningPocketsModels.swift`). This feature adds two new names that don't clash with either:
- **PocketMoment**: one wheel cell, keyed (hour, weekday, mode).
- **PocketRun**: one adaptive 100-song playback started from the wheel.

The UI just says "pocket".

---

## 1. Data model: from play history to pocket moments

### 1.1 What already exists (and is reused unchanged)

- `PlayHistoryStore.PlayEvent` (`apple/PocketDJ/State/PlayHistoryStore.swift`) carries the fields below. The log is append-only, capped at `maxEvents = 20_000`, and union-synced across devices through CloudSync.
  - `playedAt`, `tzOffsetMin`
  - `source` (browser/playlist/pocket/album/setlist/mix/artist/game)
  - `contextId`, `originCollectionId`
  - `carPlay`
  - `listeningContext` (opaque place/trip ids, write-once settle)
  - `wasSkipped`, `listenedFraction` (SkipTracker verdict and high-water fraction)
- `ListeningPlaceEngine.currentGuess` (the current place, or a trip with its likely destination) and the settle rule (`pendingHorizon` 6 h).
- The membership vector m(s) (hard + soft + add-time recency, 45-day half-life): `InThePocketMembership.swift`, spec in `docs/design/pockets-collections.md`.
- `SimilarityFamilies` provides `eraWindow`/`eraFit`, `timbreProfile`/`timbreFit`/`timbreNetFit`, and the A/B/C family blend. `TimbreCatalog` is an actor holding about 15k vectors.
- Cloud `ListeningPocketsResults`: pockets, patterns, `collectionCandidates`, round learning.

### 1.2 New, additive-optional fields on `PlayEvent` (no schema bump, the `carPlay` precedent)

```swift
/// Dominant CoreMotion activity over this play's audible window, settled write-once (§1.4).
/// "running" | "walking" | "cycling" | "automotive" | "stationary". nil = unknown, not opted in, or not yet settled.
/// Raw token stored; the MODE is derived at aggregation time so the mapping can change without a migration.
var motion: String? = nil
/// Set only for plays started by a PocketRun (§4).
var pocketRun: PocketRunTag? = nil      // { runId, momentKey "h08|d2|carPlay", rowCollectionId?, slot }
```

Both are Swift `Codable` keys that older builds ignore. They are never uploaded in v1 (see §5 and Q4).

`source` stays `.pocket` for run plays. This is deliberate: adding a `PlaySource` case makes older builds *drop* those events (`LenientEvent`). After a CloudSync union, an older device would then save and push a log without them. A run's identity rides in `pocketRun` and the run tag `pwr_<runId>`, following the `itp_` precedent in `PocketDJApp.historyContext`.

### 1.3 Mode derivation (per play, at aggregation time)

One play maps to exactly one mode. Rules are checked in order, and the first match wins:

| Order | Mode | Rule | Signal origin |
|---|---|---|---|
| 1 | `carPlay` | `event.carPlay == true` | existing `carPlayProbe` |
| 2 | `running` | `motion == "running"` | new (§1.4) |
| 3 | `walking` | `motion == "walking"` | new |
| 4 | `trip` | `listeningContext.isTrip`, or `motion` is `automotive`/`cycling` without CarPlay | existing place engine + new motion |
| 5 | `mix` | `source == .mix` | existing |
| 6 | `browse` | `source ∈ {.browser, .album, .artist}` | existing |
| 7 | `collection` | everything else (pocket / playlist / setlist) | existing |

Games (`source == .game`) are excluded, as the cloud detector already does.

Why this order: CarPlay is definitive and also the screen Levi drives with. Body activity says more about the vibe than the screen the music came from. "Trip without CarPlay" covers passenger, transit and bike. The surface modes (mix, browse, collection) describe the *listening style* when the body isn't moving. Cycling folds into `trip` in v1; see Q6.

### 1.4 Running and walking: CoreMotion

- **API.** `CMMotionActivityManager`, behind a new protocol `MotionActivityProviding`. It is in the style of `ListeningContextProviding`, with a Noop provider for macOS/tvOS/visionOS and tests.
- **Retroactive settle, with zero continuous cost.** The motion coprocessor already records activity, and `queryActivityStarting(from:to:to:)` returns the last **7 days**. So no live updates are needed for history. A settle pass runs when the app foregrounds and on the same cadence as `stampContexts`. For each of this install's events with `motion == nil` that are older than 2 min and younger than 6.5 days, it takes the activity segments overlapping `[playedAt, playedAt + duration]` (duration from the catalog `lengthMs`, else `listenedFraction × length`, else 3 min). It keeps only segments with `confidence ≥ .medium`, picks the activity with the most overlap seconds, and writes it once. Ties go to the more active state (running > walking > cycling > automotive > stationary). Plays older than 7 days stay nil forever.
- **"Now" read** for the centre button and live run re-planning: query the last 5 min when ▶ is tapped. `startActivityUpdates` runs only while a PocketRun is playing *and* the user has enabled "Adapt to activity" (Phase 5b). Its cost is near zero (coprocessor, push-based), and it stops when the run ends.
- **Permission.** Add `NSMotionUsageDescription` to `project.yml` (`INFOPLIST_KEY_NSMotionUsageDescription`), for example: "PocketDJ can notice when you're walking or running while music plays, so your pockets can tell a run from a commute. Motion data stays on this device." Opt-in toggle "Notice walking & running" in `ListeningLocationSettingsSection` (or a sibling `ListeningMotionSettingsSection`), **default OFF**, same posture as places & trips. The prompt fires on enable. Denied or restricted means the feature is inert and the toggle explains why.
- **Battery.** No GPS, no live updates during ordinary listening, and one query per foreground. That is negligible.
- **Privacy.** v1 keeps motion device-only (it is never in the pockets upload), so the App Privacy label doesn't change. Uploading it later would need "Fitness" on the label (Q4).

### 1.5 Collection attribution: the "dominant feature"

Every non-game play is attributed to collections as a sparse weight map. This is the play's **source collection** first, and its membership second.

1. **Origin, weight 1.0.** First match of:
   - `pocketRun.rowCollectionId`
   - `originCollectionId`
   - `contextId`, when it names a real collection: a pocket, a playlist, or a catalog source playlist (`pl_…`).

   Setlist ids resolve to their playlist.
2. **No origin** (Browser singles, album/artist plays, Mix sessions without a crate). Weight 0.5, spread over the song's **hard memberships**, with each share proportional to m(s). **Mega-collections** are excluded from this fallback: any collection holding more than 25% of the playable library, or more than 3,000 songs, such as a whole-library source playlist. They would otherwise dominate every cell. They still count when they are a play's actual origin.
3. **Soft membership is not used for colour.** It stays a recommendation signal (§4.2), because colour must mean "where the music came from".

**Attribution gaps found while reading the code.** These must be fixed first (Phase 0), or the most important feature is blind on the very collections Levi named:
- **Catalog source playlists ("Potential" when it is an AM smart playlist rather than a converted pocket).** `CarPlayModel.playPlaylist` → `IntentServices.playSongIds(…, source: .playlist)` and `CollectionPlayMenu` → `playSongIds` pass **no `originId`**. `CollectionsStore.playNow(songIds:)` supports `originId:`, but `playSongIds` never forwards it, so these plays record `contextId = set_now_playing` with no origin.
- **Favorites.** `FavoritesStore` isn't a collection. Playing the Favorites filter in Browse has no origin. Add the reserved synthetic id `fav_songs` (name "Favorite songs") and stamp it as the origin.
- **Mix.** History records `contextId = mixSessions.currentId` (a session, not a crate). The Auto-DJ crate's `MixSource` id (`.pocket(id)` / `.playlist(id)`) should be stamped as `originCollectionId` (`PocketDJApp.swift` around line 970).

### 1.6 The PocketMoment aggregate (pure, on device)

```swift
struct PocketMomentKey: Hashable, Codable { var hour: Int /*0–23 local*/; var dow: Int /*1=Mon…7=Sun*/; var mode: PocketMode }
struct PocketMoment {
  var key: PocketMomentKey
  var plays: Double            // decayed, kernel-weighted count of non-skipped plays
  var skips: Double            // decayed count of skips
  var distinctDays: Int        // distinct local dates contributing directly (not via smoothing)
  var collections: [String: Double]   // §1.5 weights, from non-skipped plays (L1-normalised, top 8)
  var dominantCollectionId: String?   // argmax, only when its share ≥ 0.25, else nil ("mixed")
  var artists: [String: Double]; var genres: [String: Double]
  var bpm: (lo: Double, hi: Double)?  // p25–p75 of folded BPM, ≥ 3 values
  var era: SimilarityFamilies.EraWindow?
  var timbre: SimilarityFamilies.TimbreProfile?   // from played-through members with vectors
  var ctx: [String: Double]    // place/trip id distribution ("none" included)
  var seeds: [String: Double]  // songId → strength (played through here)
  var cloudPatternIds: [String]   // listening-pocket patterns whose time bucket/dayType/ctx overlap
  var lastSeenMs: Double
  var confidence: Double { 1 - exp(-plays / 6) }    // 0.39 at 3 plays, 0.81 at 10
}
```

**How it is built** (`PocketMomentEngine.build(events:collections:catalog:timbre:now:)`, pure and off-main):

- **Local time.** `playedAt + tzOffsetMin` gives the hour and the ISO weekday. Events without `tzOffsetMin` use the most common offset, as the cloud does.
- **Decay.** Each play's weight is `0.5^(age/45 d)`, the same half-life as add-time recency.
- **Smoothing.** Cells are sparse: there are 168 cells × 7 modes, and only about 20k plays to fill them. Each play also credits neighbouring cells:
  - ±1 hour at 0.5 and ±2 h at 0.15;
  - other days of the same day type at 0.25;
  - the same hour and day in a *related* mode at 0.3. Related pairs: carPlay↔trip, running↔walking, mix↔collection.

  `distinctDays` counts only direct credit. The UI and the scorer use it to tell a **recurring** cell (≥ 2 distinct days, drawn solid) from a **one-off** (drawn dim).
- **Run plays** (`pocketRun != nil`) count **0.5×** in `plays` and `collections`, but **1×** in `skips`. A run must not paint the wheel with its own choices (a feedback loop), while its skips are honest negatives.
- **Cost.** One O(n) pass over ≤ 20k events plus O(cells) normalisation. It is recomputed when `PlayHistoryStore.revision` changes, debounced 5 s, on a background task, and the result is memoised (the "no derivations in view bodies" rule). It is persisted as a cache (`pocketdj-pocket-wheel-cache.json`, device-local) so the wheel paints instantly at launch.

The cloud listening pockets are **priors, not the source of truth**. When the opt-in is on, a cell gets `cloudPatternIds`, and the patterns' `collectionCandidates` and round-learning multipliers feed the run planner (§4.2). The wheel itself is drawn from local history, so it works with the cloud opt-in off, offline, and immediately.

---

## 2. The wheel UI

### 2.1 Placement

- **History ▸ Pockets** becomes a **Wheel | List** segmented control. Wheel is the default; List is today's `ListeningPocketsView`.
- The Pockets tab is currently gated on `ListeningPocketsService.isEnabled` (the cloud opt-in). The wheel needs only local history, so the tab gate changes to "history exists". The List segment keeps the cloud opt-in offer. See Q1 for whether Levi instead meant the **Pockets collection tab** (`Views/PocketsView.swift`).
- Also reachable: a "Pocket for now" ▶ on the Now Playing home deck when idle, a CarPlay entry (§2.6), and an App Intent "Play my pocket" (`Intents/PlaybackIntents.swift`).

### 2.2 Geometry (opinionated)

- **Clock face:** midnight at 12 o'clock, clockwise, 15° per hour. Hour ticks at 0/6/12/18 are labelled; the others are dots. A thin **"now" needle** runs from the centre to the outer edge at the current local time.
- **Rings:** Monday innermost, Sunday outermost. Fixed order, so the shape is learnable ("weekends are the outer two rings"). A thin gap separates Fri|Sat to mark the weekend.
- **Today's ring is 1.8× thicker** (a fisheye). Tapping a weekday label (a small letter at the ring's 12 o'clock end) moves the fisheye to that ring. This is what makes hit targets workable on iPhone. On a 390 pt-wide phone, with R = 175 pt and a centre hole of 0.30 R:
  - the focused ring is about 26 pt thick and its outer cells about 45 pt along the arc;
  - unfocused rings are about 14 pt thick.
- **Centre:** a ▶ button about 96 pt across, with a ring of the best-match colour around it and a two-line caption under the wheel: "Tue 8 AM · CarPlay" / "Potential · 23 plays".
- **Drawing:** a SwiftUI `Canvas` of 168 × ≤ 3 annular sectors from a precomputed `WheelLayout` value. Nothing is derived in the body. Hit-testing converts the touch point to polar (r, θ) → (ring, hour, sliver).

### 2.3 Modes within a ring cell (R2)

Two complementary views, chosen with a chip row above the wheel: **All · CarPlay · Trip · Run · Walk · Mix · Browse · Home**. "Home" is the `collection` mode; its label is open in Q6.
- **All (default).** Each (hour, day) cell is split *angularly* into up to 3 slivers: the cell's top 3 modes by plays, ordered by the fixed mode order in §1.3, each sliver's width proportional to its plays (minimum 20% of the cell). Each sliver is coloured by **its own** dominant collection. With one mode, the cell is one solid sector. A small (about 9 pt) mode glyph sits in the sliver only on the focused ring, where the room exists: car, figure.run, figure.walk, slider, list.
- **One mode selected.** Every cell shows only that mode's moment, full width. "Where do I run on Saturdays" becomes obvious.

### 2.4 Colour = dominant source collection (R4)

- **Palette.** 12 perceptually spaced colours in OKLCH (L 0.72 / C 0.15 in dark theme, L 0.58 in light), hue steps chosen to avoid adjacent near-collisions. They are defined as tokens next to `Theme`.
- **Stable assignment.** `PocketPaletteStore` keeps `collectionId → slot`. A slot is assigned the first time a collection becomes dominant in any cell, in descending global dominance on the first build. It **never moves afterwards**, and a slot is freed only 30 days after its collection disappears or is deleted. The store is **CloudSync'd**, last-writer-wins per key with assign-time tiebreak, so iPhone, iPad and Mac show the same colours.
- **Overflow** (a 13th dominant collection): a hue hashed from sha256(id) at lower chroma (0.08), plus a hatch pattern. In practice Levi's dominant set will be under 12.
- **Encoding:**
  - cell opacity = `0.25 + 0.75·confidence`;
  - one-off cells (`distinctDays < 2`) are drawn at 50% saturation;
  - an empty cell is the theme's `surface` colour;
  - a "mixed" cell (no collection ≥ 25%) is neutral grey with a fine stripe.
- **Legend:** a horizontal chip list under the wheel. It shows each colour, the collection name, and its share of the week. Tapping a legend chip highlights that collection's cells and dims the rest.
- Per-collection colour override is optional (Q3). It would be an additive-optional `wheelColor` on `Pocket`/`Playlist` (no schema bump).

### 2.5 Interaction

- **Tap a cell or sliver.** Selects it, with a haptic. A detail card slides up with:
  - its moment: "Tuesday 8 AM · CarPlay";
  - its collections, as coloured bars;
  - its top artists and genres, BPM band, place/trip chips (re-labelled on device, as `ListeningPocketLabeler` does), and plays and skip rate;
  - **▶ Play this pocket**, which starts a PocketRun for that key;
  - "Why this colour";
  - the run history for that moment: last runs and skip rate trend, which shows that learning is happening.
- **Scrub.** Touching down and dragging shows a magnifier callout above the finger with the cell under it, the way the keyboard does. Releasing selects that cell. This is the answer to 168+ small targets on a phone.
- **Centre ▶.** Starts the best-match run (§3). A long-press shows the **top 3 alternatives** ("Not this? Saturday-morning Run · Favorites"). While a run plays, the centre shows ⏸ plus a small "37/100" ring progress.
- **Pinch.** Zooms to a single-day 24-hour donut whose sub-rings are modes. This is a nice-to-have (Phase 3b) for iPad.

### 2.6 Device fallbacks

- **iPad and Mac.** The wheel is up to 520 pt with the legend and detail card in a side column. On Mac, hovering shows the callout. visionOS uses the same view.
- **CarPlay.** Templates can't draw a custom wheel. Add a top row **"▶ Pocket for now — Potential · Tue 8 AM"** (`CPListItem`) to the CarPlay root/For You list (`CarPlay/CarPlayModel.swift`, `CarPlayForYou.swift`). A list template, "Pockets right now", follows with the top 5 moments whose hour is within ±1 h of now across modes. The `carPlay` mode is implied while connected.
- **tvOS.** No History tab, so out of scope.
- **Android Auto.** See §6.

### 2.7 Accessibility

- A `Canvas` exposes nothing to VoiceOver, so the wheel gets `.accessibilityRepresentation`: a container with **7 children (one per weekday ring)**, each an adjustable element. Swipe up/down moves through the hours, and the value reads "8 AM, CarPlay: Potential, 23 plays, 4% skips; also Mix: Late Night, 6 plays". Double-tap opens the detail card. The rotor lists "Recurring pockets".
- The centre ▶ is a normal `Button`: "Play the pocket for now: Potential, Tuesday morning, CarPlay".
- **Colour is never the only channel.** The legend names collections, the detail card names them, and a "Show labels" setting draws the collection's initials on focused-ring cells. The palette is checked for deuteranopia/protanopia separability (the `dataviz` validator approach) at design time.
- Dynamic Type scales the captions, legend and card; the wheel itself scales with width. Reduce Motion turns off the needle sweep and the fisheye animation.

---

## 3. Best match for the centre ▶

### 3.1 Inputs at tap time

- `h`: local fractional hour.
- `d`: weekday and day type.
- `mode_now`:
  - CarPlay connected → `carPlay`;
  - else motion in the last 5 min is running/walking (confidence ≥ medium) → that;
  - else automotive, or `currentContextGuess` is a trip → `trip`;
  - else **unknown**. The surface modes aren't inferable at tap time, because the user is looking at the wheel.
- `ctx_now`: `ListeningContextProviding.currentContextGuess()` (place or trip, or nil).
- **Previous activity**:
  - the last 45 min of plays: their collection-attribution vector `P` (§1.5) and their skip rate;
  - the last mode;
  - the last motion state, even if now is "stationary": a run that just ended means a cool-down.

### 3.2 Score for every cell k with `plays > 0` (after smoothing)

```
match(k) = Kt(h, k.hour) · Kd(d, k.dow) · Km(mode_now, k.mode) · Kl(ctx_now, k)
  Kt = exp(−Δh² / 2)                       Δh circular, in hours (σ = 1 h)
  Kd = 1 same weekday · 0.6 same day type · 0.25 otherwise
  Km = 1 same · 0.7 related pair (§1.6) · 0.35 unrelated · 0.6 when mode_now is unknown
  Kl = ctx_now && k.ctx non-empty ? 0.3 + 0.7·k.ctx[ctx_now] : 1
quality(k) = k.confidence · (1 − skipRate(k))^1.5 · (distinctDays ≥ 2 ? 1 : 0.7)
continuity(k) = cosine(P, k.collections)    (0 when no plays in the last 45 min)
score(k) = match(k) · (0.4 + 0.6·quality(k)) + 0.35·continuity(k)·match(k)^0.5
```

The winner is the argmax, with ties broken by `lastSeenMs`. The alternatives are the next 3 with a **different dominant collection**.

The continuity term is "previous activity". If Levi has been listening to Potential unskipped for 30 min, Potential-heavy moments win even slightly off-hour. The `^0.5` stops continuity from dragging a 3 AM cell into a 6 PM tap. If the recent skip rate is above 50% (he's unhappy with what's on), continuity is **negated**, to steer away.

The cloud is an optional boost. A cell whose `cloudPatternIds` include a pattern with round-learning `pocketRate ≥ 0.5` gets ×1.15.

### 3.3 Cold start (tiers, shown honestly in the caption)

| Tier | Condition | Behaviour | Caption |
|---|---|---|---|
| T0 rich | winner `match ≥ 0.35` and `plays ≥ 3` | as above | "Tue 8 AM · CarPlay" |
| T1 neighbourhood | weak winner, but day-type × ±3 h has ≥ 5 plays | blend the profiles of the top 5 cells by score | "Weekday mornings" |
| T2 cloud | the opt-in is on and patterns match the time bucket | the profile from patterns, exactly `InThePocketScorer`'s `.cloud` profile | "From your listening pockets" |
| T3 whole history | ≥ 20 non-skipped plays anywhere | the `.cold` profile, weighted by collections' `lastPlayedAt` recency | "Your recent favourites" |
| T4 empty | nothing | the most recently played collection, else Favorites, else For You's top tile. The wheel shows a ghost outline with "Play for a week to paint your wheel." | "Getting to know you" |

Every tier produces the same `PocketProfile` value that feeds §4, so the run planner has no special cases.

---

## 4. The adaptive 100-song PocketRun

### 4.1 Shape

- A run is **100 slots**. The cap counts tracks *started*, skipped ones included. Replacements *substitute* slots and never extend the run. When slot 100 ends, the run stops with a "Pocket finished · ▶ another" card. Repeat is forced off for run tags (Q2).
- Run tag: `pwr_<runId>`.
  - `PocketDJApp.historyContext` maps it to `(.pocket, "Pocket · Tue 8 AM CarPlay")`, so History reads naturally.
  - `SetlistPlayer.restore` must keep the tag. Today it nils only `puzzle_` tags.
- Rows carry a new field on `SetlistPlayer.Item`, excluded from equality like `variant`:

```swift
struct PlanTag: Hashable, Codable { var runId: UUID; var slot: Int; var collectionId: String?; var score: Double; var pinned: Bool }
var plan: PlanTag? = nil
```

Rows the user adds by hand (Up Next add, Jukebox, "Play next") have `plan == nil`. Rows the user moves get `pinned = true`. **Neither is ever replaced.**

### 4.2 Initial selection (pure: `PocketRunPlanner.plan(profile:catalog:playable:timbre:tuning:seed:)`)

**1. Candidate pool** (≈ 300–600 songs; playable only, using the `InThePocketStore` playability rule: rip manifest / burned / AM with a store id):
- hard members of the profile's collections, weighted by the collection weight;
- the cell's seed songs;
- cloud `collectionCandidates` for its patterns;
- soft neighbours: non-members whose `timbreFit` to the profile centroid is ≥ 0.6, or whose B+C family score (genre+era, genre+bpm+key) is ≥ 0.6. Capped at 25% of the pool.
- **Exclusions:** songs played in the last 12 h (not 48 h; a 100-song run needs room), and any song with a lifetime 👎.

**2. Score**

```
s = 1.5·Σ_c w_c·m_c(song)              collection, the DOMINANT feature (hard m = 1·recency, soft ≤ 0.6)
  + 0.8·seed(song) + 0.6·bpmFit + 0.5·eraFit + 0.7·timbreNetFit (shrunk, timbrePrior = 2)
  + 0.4·genreMatch + familiarity (InThePocketScorer formula)
  then × Π tuning multipliers (§4.6) over the song's features
```

**3. Compose 100** with quotas and caps (`RecComposition` style):
- **Collection quota:** slots ∝ `w_c`, with the dominant collection at ≥ 40% when its share is ≥ 0.25. This keeps the run *about* its colour.
- **Artist cap:** ≤ 6 per artist in 100, and no artist twice within 4 slots. The newcomer-floor lesson applies: ≥ 20% of slots go to artists not among the cell's top 10.
- **Order:** a seeded greedy flow. Slot 1 is a weighted draw (score²) from the top 8. Each next slot re-ranks for `e^(−|ΔBPM|/10)` and Camelot neighbour (`Performance/RealizeEngine` harmonics), plus diversity, and draws from the top 6. This is the same structure as `InThePocketScorer`'s pick, extended to 100.

**4. The bench.** Everything scored but not placed (up to 400 ids plus their scores) is kept as the run's replacement bench.

### 4.3 Live learning inside the run

Each verdict on a run row arrives through the existing `SkipTracker` → `PlayHistoryStore.markSkipped` / `noteListened`. `PocketRunStore` observes `PlayHistoryStore.revision` and reads events with this `runId`, the way `InThePocketRoundEvaluator` does. It never adds a second skip pipeline.

**Signal strength** per finished row:
- fast skip, `fraction < 0.15`: −1.0;
- skip below 0.5: −0.6;
- completed, ≥ 0.9 or natural end: +0.5;
- partial 0.5–0.9: +0.2.

Auto-advances (dead source, cascade breaker) are **not** skips, because SkipTracker never classifies them. That is correct: a failed rip is not taste.

**Features of each row:**
- artist: credit keys, as `creditArtistKeys`, so features are counted too;
- album;
- genre;
- era bucket (5 years);
- BPM bin (8 BPM);
- source collection;
- timbre vector (when present).

**Per-feature evidence** for the run: `neg_f`, `pos_f` (sums of strengths). Its multiplier uses **the formula the cloud and In the Pocket already use for round learning**, made stronger for artists:

```
artist:     mult = clamp(2·(pos + 0.5) / (pos + neg + 1), 0.15, 1.6)   → 1 fast skip 0.33, 2 skips ≈ 0.2
album:      same as artist, prior 0.5
collection: clamp(2·(pos + 2) / (pos + neg + 4), 0.5, 1.4)            (slow: one skip barely moves the colour)
genre/era/bpm: clamp(2·(pos + 1) / (pos + neg + 2), 0.35, 1.5)
timbre:     skipped vectors form the run's NEGATIVE TimbreProfile (minVectors 1),
            used through timbreNetFit with rejectionWeight 0.5 (the 👎 mechanism, reused)
```

**Hard exclude:** an artist whose multiplier is ≤ 0.35 (one fast skip, or two ordinary skips) is banned for the rest of the run. That is the "skip Drake → no more Drake" behaviour.

### 4.4 Re-planning without dead air (R9)

**Trigger:**
- a skip verdict on a run row, debounced 1.5 s, because a verdict can land one track late (the SkipTracker stash);
- a light re-score every 5 completed rows;
- the motion state changing during the run (Phase 5b, opt-in).

**Compute:** `PocketRunPlanner.replan(state:queueSnapshot:)` is pure and off-main, and returns `[uid: Item]` replacements plus `[uid]` removals.

**Replacement rule** for a row r that now scores below the re-plan floor (its artist is banned, or its new score is under 0.6× the median placed score). Pick from the bench plus a fresh top-up:

```
argmax over candidates x with x.artist ∉ banned ∪ runArtistsAtCap, x ∉ run:
   0.55 · musicalSim(x, r)        // SimilarityFamilies B + C (genre+era, genre+bpm+key) + timbre distance when both have vectors
                                  // NO artist family: "similar musically, different artist"
 + 0.35 · pocketFit(x)            // §4.2 score with the CURRENT tuning multipliers
 + 0.10 · flow(x, neighbours of r's slot)   // BPM/Camelot continuity with slot−1 and slot+1
```

This is a *slot-wise* substitution, so the run keeps its arc: tempo flow and collection quotas, re-checked on the post-swap queue. If nothing clears `pocketFit ≥ 0.3`, the row is removed and the run gets shorter. The cap still holds.

**Apply** with a new `SetlistPlayer.replaceUpcoming(_ replacements: [UUID: Item], removing: Set<UUID>) -> Int`. It runs on the main actor, keyed by uid (the `removeUpcoming` discipline), and the protected set is re-evaluated **at apply time**:

| Row | Rule |
|---|---|
| `queue[index]` (playing) | never touched |
| `queue[index+1]` | touched only if ≥ 30 s remain in the current track. Then `prefetchUpcoming()` is re-run immediately, so the AM pre-resolve and presign cover the new row. A skip-triggered re-plan lands at the *start* of the next track, so a full song of runway is normal. |
| `index+2 … index+3` (prefetch window) | replaceable; `prefetchUpcoming()` re-run after |
| rows in the **rip-ahead window** with a rip in flight | replaceable only by a row that `rowStartsInstantly` or `rowOnDevice` (burned / AM-resolvable / cached presign). An in-flight capture is never traded for another capture: that is real-time Music.app capture on the Mac and stalls the run (memory: rip-window skip cascade). |
| `plan == nil` or `pinned` | never touched |
| beyond | free |

The queue's `didSet` already reschedules the Stem Lock re-plan and the rip-window reconcile, so removed rows' rips are cancelled and new rows enter the window. Shuffle: the replacement takes the replaced uid's rank in `canonicalOrder` (swap in place), so shuffle-off ordering stays coherent. `persistSession()` runs after apply. Log `[pocketrun] replan run=… skips=… replaced=n removed=m banned=[artist…] ms=…` to `DiagLog`.

The `DeadAirMeter` already measures transitions per backend. A wheel run is a setlist-lane run, so it is covered. Verify after the first drive that run transitions don't regress the 10-24 baseline (`scripts/deadair-report.py`).

### 4.5 Drake, concretely

The run is Tue 8 AM CarPlay (Potential). Slots 3, 11, 19, 27 and 40 are Drake. Slot 3 is fast-skipped at 0:20/4:10 (fraction 0.08, signal −1.0), so the artist multiplier drops to 0.33 and Drake is banned. Slot 4 is playing and protected. Slot 5 is protected only if under 30 s are left; it isn't. The re-plan then:
- replaces slots 11, 19, 27 and 40 with, for example, Bryson Tiller, 6LACK, dvsn and Majid Jordan, chosen by genre+era+BPM+timbre nearness to *each Drake row* and their fit to Potential's centroid. Any candidate *featuring* Drake is excluded too, because the ban is on `creditArtistKeys`;
- drops hip-hop genre by one notch (multiplier 0.67), which shifts a couple of marginal hip-hop rows;
- barely moves the Potential collection weight.

The Up Next list updates in place, with a subtle "Re-tuned ✦" badge on the swapped rows for a few seconds.

### 4.6 Persistence into future runs (R8)

**The learned state is derived from history, not stored as mutable state.**
- Every run play carries `pocketRun.momentKey`. `PocketTuning.fold(events:now:)` rebuilds per-moment feature evidence (`pos_f`, `neg_f`) from the append-only log.
- It therefore survives relaunch, merges across devices for free (the history union by event id), is erased with "Delete history", and needs no new CloudSync document.
- Run-play songs are joined to the catalog for features at fold time.

**Applying it to a new run of moment k:**

```
evidence_f = Σ_{runs of k} decay(age, 30 d) · strength          (own moment, ×1.0)
           + Σ_{related moments (§1.6 smoothing kernel)} … ×0.5   (Tue 8 AM CarPlay also informs Wed 8 AM CarPlay)
           + Σ_{all moments} … ×0.15                              (a global artist aversion leaks in gently)
```

The same multiplier formulas then apply, but **bans don't persist**. A banned artist enters the next run at its multiplier (for example 0.33): rare, not forbidden. Tastes change, and the 30-day half-life lets them relax back to 1.

Cost and caps: the fold is O(run events), at most a few thousand, and is cached alongside the moment cache. History's 20k cap bounds it naturally, matching the cloud's 180-day retention.

**Run state that must survive a relaunch mid-run** goes in `pocketdj-pocket-run.json` (device-local, one active run): `runId`, `momentKey`, `seed`, profile snapshot, bench ids and scores, banned set, and the slot counter. The queue itself already persists through `PlaybackSessionStore`. That store needs the `plan` field in its `Row` projection: additive-optional, the mix-deck-loop "optional fields, no schema bump" lesson.

### 4.7 Run start mechanics

`PocketRunStore` is app-scoped (the `InThePocketStore` pattern). It:
1. builds the profile and plan off-main;
2. calls `CollectionsStore.playNow(songIds:…, source: .pocket, originId: nil)` with variants, or directly `SetlistPlayer.play(items, sourceSetlistId: "pwr_<id>")` as games do, passing pre-tagged items;
3. starts the 1 Hz observation (the same ticker approach as In the Pocket).

The first 3 rows are deliberately biased toward `rowStartsInstantly` rows. Instant first audio is the most visible dead-air moment.

---

## 5. Where it computes

**On device, entirely, in v1.** Reasons:
- **Inputs are local.** Playability (rip manifest, burned files, AM store ids), raw motion, and location context are all on the device, and raw motion/location must never leave it.
- **Latency and offline.** The re-plan must land within one track, in a CarPlay dead zone. The Lambda round trip and its async compute model (upload → compute → GET) make it unfit for live control.
- **Data size is trivial.** ≤ 20k events, about 15k timbre vectors already cached by `TimbreCatalog`, and the catalog in memory.
- **History already syncs across devices**, so per-device computation converges without a server.

**The cloud's role is unchanged: priors.** The `listening-pockets` Lambda continues to supply patterns, `collectionCandidates` and round learning, used in §3.2, §3.3 T2 and §4.2.

**Optional Phase 6 cloud work** (not required):
- add `mode` (derived, coarse: carPlay/trip/surface only, *not* motion unless Q4 says yes) to upload events;
- add `mode` as a context dim in `analyze.mjs` (lift ≥ 1.25);
- add `pocketRun` plays as `contextKind: "wheel"` with `contextId = rowCollectionId`;
- let `learnFromRounds` accept PocketRun outcomes as weak labels: completed ≥ 80 of 100 counts as positive.

All of this is additive in the upload/results contract. Regenerate the app↔cloud goldens in the documented order. Deploy to GREEN only.

---

## 6. Phased plan

Each phase is its own feature branch off `feat/pocket-wheel`: drive → merge → TestFlight → verify. Gates for every phase:
- iOS unit suite with the **test count moved** (the XcodeGen trap);
- macOS and visionOS archive builds (the platform-fence trap: shared models must not land inside `#if os(iOS)`; only CoreMotion/CarPlay adapters do);
- async tests wait on the asserted condition, never on sleeps.

### Phase 0: attribution fixes and event fields (small, ship first; it improves the existing cloud pockets too)

- `Intents/IntentServices.swift`: `playSongIds(_:name:shuffle:source:originId:)` forwards `originId`.
- `CarPlay/CarPlayModel.swift` `playPlaylist`, `Views/CollectionPlayMenu.swift`, and the Browse Favorites play path: pass the source playlist id or `fav_songs`.
- `PocketDJApp.swift` (Mix record hook around line 970): stamp `originCollectionId` from the Auto-DJ `MixSource` id.
- `State/PlayHistoryStore.swift`: `motion`, `pocketRun` fields, plus `stampMotion(...)` write-once, own-install-only (mirrors `stampContexts`).
- `State/CollectionsStore.swift`: let `historyContext`/`originCollection` resolve `pl_…` and `fav_songs`.
- **Tests:** `PlayHistoryStoreTests` (decode old docs, write-once motion, a peer event untouched); `CarPlayModelTests` (source-playlist play stamps origin); a new `PlayAttributionTests`.

### Phase 1: motion

- New `apple/PocketDJ/Location/MotionActivityProviding.swift` (protocol + Noop), `CoreMotionActivitySource.swift` (iOS only), `ListeningMotionSettingsSection.swift`.
- `project.yml`: `INFOPLIST_KEY_NSMotionUsageDescription`. Check `PrivacyInfo.xcprivacy`; there is no required-reason API for motion.
- `SettingsStore`: `listeningMotionEnabled` (default false).
- **Tests:** `MotionSettleTests` uses a fake provider with scripted segments: overlap winner, confidence filter, the 7-day horizon, ties, and pending under 2 min.

### Phase 2: the moment engine and palette (pure)

- New folder `apple/PocketDJ/Services/PocketWheel/`:
  - `PocketMode.swift`;
  - `PocketMomentEngine.swift` (§1.3/1.5/1.6);
  - `PocketMomentCache.swift` (off-main build, revision-debounced, disk cache);
  - `PocketPaletteStore.swift` (+ CloudSync registration in `PocketDJApp`, and the key added to `AccountDeletionService`'s list).
- **Fixture:** `apple/Tests/Fixtures/pocket-wheel-history.json`. A deterministic 3-week scenario:
  - weekdays 08:00 CarPlay from Potential;
  - Sat 09:00 running with Favorites;
  - evenings Mix from the "Late Night" crate;
  - Browse singles at lunch;
  - one trip A→B;
  - a mega-collection;
  - sprinkled skips and one-offs.

  It is shared byte-for-byte with Android (§7).
- **Tests:** `PocketMomentEngineTests`:
  - mode precedence;
  - local-hour/tz across a zone change;
  - decay;
  - smoothing weights and `distinctDays`, which count direct credit only;
  - dominant collection, mega-collection exclusion, and the "mixed" threshold;
  - run plays at 0.5× and their skips at 1×.

  `PocketPaletteStoreTests`: slot stability across rebuilds, the free-after-30-days rule, the merge rule, and overflow hashing.

### Phase 3: wheel UI

- New `apple/PocketDJ/Views/PocketWheel/`:
  - `PocketWheelView.swift` (Canvas, from a precomputed `WheelLayout`);
  - `WheelLayout.swift` (pure geometry and hit-testing);
  - `PocketMomentCard.swift`;
  - `PocketWheelLegend.swift`;
  - `PocketWheelAccessibility.swift`.
- `Views/HistoryView.swift`: Wheel|List segment and the relaxed Pockets tab gate. `ListeningPocketsView` is unchanged inside List.
- Seed variant `PDJ_SEED_POCKET_WHEEL` for screenshots and XCUITest (the `showcase` seed precedent).
- **Tests:** `WheelLayoutTests` (polar hit-test at ring and hour boundaries, fisheye radii, sliver widths and minimum width); an XCUITest that taps a seeded cell, sees the card, opens VoiceOver's adjustable value, and checks the a11y identifiers. Run this on a baseline-clean simulator UDID.

### Phase 4: best match and cold start

- `Services/PocketWheel/PocketBestMatch.swift` (§3, pure), `PocketProfile.swift` (one value for all tiers, reusing `InThePocketScorer` profile builders; refactor them out as `internal static` helpers rather than copying).
- CarPlay "Pocket for now" row (`CarPlay/CarPlayModel.swift`, `CarPlayForYou.swift`) and an App Intent `PlayPocketForNowIntent` (`Intents/PlaybackIntents.swift`, `PocketDJShortcuts.swift`).
- **Tests:** `PocketBestMatchTests` (each kernel; continuity, including its negation on a skip streak; each cold-start tier from fixtures trimmed to size; alternatives with distinct collections); `CarPlayModelTests` (row present and titled).

### Phase 5: the adaptive run (the biggest phase; split it in two)

**5a: plan, play, learn, persist**
- `Services/PocketWheel/PocketRunPlanner.swift` (pure: plan, replan, replacement rule);
- `PocketTuning.swift` (fold from history, multipliers);
- `State/PocketRunStore.swift` (app-scoped, run file, observation, apply).
- `Playback/SetlistPlayer.swift`:
  - `Item.plan`;
  - `replaceUpcoming(_:removing:)` with the protection rules (§4.4);
  - re-run `prefetchUpcoming()` after an apply that touched the prefetch window;
  - keep `pwr_` on `restore`;
  - force repeat-off for `pwr_`;
  - mark `pinned` in `moveUpcomingNext`/`moveUpcoming`/`insert*`.
- `PlaybackSessionStore.Row`: optional `plan`. `PocketDJApp.historyContext`: the `pwr_` branch.
- **Tests:**
  - `PocketRunPlannerTests`: 100 slots; the collection quota; the artist cap and spacing; the newcomer floor; determinism by seed; exclusions.
  - **`PocketRunReplanTests`**: the Drake scenario end to end on the fixture, including feature credit and banned propagation; the slot flow kept; rows removed when there is no candidate.
  - `SetlistPlayerReplaceUpcomingTests`: the protection invariants as a property test over random index/queue states, which **never** mutate `≤ index`, `plan == nil`, `pinned`, or rows with an in-flight rip unless the replacement is instant. Also canonicalOrder under shuffle, a stale uid as a no-op, and persistence.
  - `PocketTuningTests`: the fold, the 30-day decay, neighbour leak weights, and that bans don't persist.
  - `PocketRunStoreTests`: restore mid-run, and the 100-cap stop.

**5b: adapt to activity mid-run (opt-in).** Live `startActivityUpdates` during a run. A sustained change (≥ 3 min running) re-targets the run's *remaining* slots toward the best moment for the new mode, using the same replace path.

### Phase 6: cloud (optional) — §5.

---

## 7. Android follow-up (mapping onto modules that exist now)

| iOS piece | Android home |
|---|---|
| PlayEvent `motion` / `pocketRun` | `data/history/PlayHistoryModels.kt`, `PlayHistoryStore.kt` (merge: first non-null wins, like `carPlay` at line 317) |
| Attribution fixes | the Android playNow/origin paths in `data/collections/CollectionsStore.kt`, `auto/AutoBrowseTree.kt`, `screens/collections/*` |
| CoreMotion | **new `data/motion/ActivityTransitionSource.kt`**, using the Play Services Activity Recognition **Transition API** (`play-services-location` is already a dependency). It needs the `ACTIVITY_RECOGNITION` runtime permission (API 29+) in `AndroidManifest.xml`. There is **no 7-day retroactive query** on Android, so transitions must be recorded continuously, via a PendingIntent `BroadcastReceiver`, into a small device-local timeline (`MotionTimelineStore.kt`, 7-day ring). The settle pass then works the same. Battery is low (batched, sensor hub). |
| Moment engine, palette, best match, planner, tuning | **new `data/pockets/wheel/`**: `PocketMomentEngine.kt`, `PocketPaletteStore.kt`, `PocketBestMatch.kt`, `PocketRunPlanner.kt`, `PocketTuning.kt`; reuse `data/recs/SimilarityFamilies.kt`, `TimbreCatalog.kt`, and `data/games/inthepocket/InThePocketScorer.kt` profile helpers |
| Run store | `data/pockets/wheel/PocketRunStore.kt`; wired in `di/GamesGraph.kt` next to `pocketsBridge`, or a new `di/PocketsGraph.kt` (cleaner) |
| `replaceUpcoming` | `playback/sequencer/SetlistSequencer.kt`: a public `replaceUpcoming(...)` over the existing private `replaceTail`, honouring `NextRowPreloader`'s window; `QueueItem.kt` gets `plan` |
| Wheel UI | `screens/history/PocketWheelScreen.kt` (Compose `Canvas` + `pointerInput` polar hit-test; `semantics` with a custom `CustomAccessibilityAction` per ring for TalkBack), toggled from `ListeningPocketsScreen.kt` |
| CarPlay row | `auto/AutoBrowseTree.kt`: a playable "Pocket for now" root item; `carConnected` already feeds `history.carPlayProbe` (`PocketsPlayListener.kt`) |
| Tests | `android/app/src/test/java/com/levi/pocketdj/data/pockets/wheel/*Test.kt`, reading the **same** `apple/Tests/Fixtures/pocket-wheel-history.json` and a generated `pocket-wheel-parity.json` (expected moments, best match, the first 100 for a seed, the post-Drake re-plan). This is the `timbre-parity.json` precedent, with goldens at 1e-9 so the ports can't drift. |

---

## 8. Risks I'm designing around

- **Timbre coverage.** About 15k of about 100k songs have vectors, and Apple Music rows have 0% BPM/key. For an AM-heavy pocket, the "similar musically" replacement leans on genre + era (+ the cloud's soft membership). It will feel good on vinyl/digital pockets and coarser on AM-only ones until rips land. `timbrePrior = 2` shrinkage stays load-bearing; don't drop it.
- **Feedback loop.** Runs could paint the wheel with their own picks. Mitigated by the 0.5× weight for run plays and the 1× weight for their skips (§1.6).
- **Dead air.** Re-plans never touch the playing row. The next row is touched only with runway, followed by an immediate re-prefetch, and an in-flight capture is never traded for another. Verify with the dead-air report after the first drive.
- **Main-thread cost.** All builds are off-main with memoised results, and the Canvas draws only from a precomputed layout (the repo's recurring perf bug class).

---

## 9. Open product questions (only the real ones)

1. **Where does the wheel live?** I assumed History ▸ Pockets (Wheel | List), because cells come from listening history. Did you mean the Pockets *collection* tab instead, or both?
2. **What counts toward the 100?** I assumed tracks *started*, skips included, with replacements substituting rather than extending. The alternative is 100 *played-through* songs, which makes heavy skipping lengthen the run. And at 100: stop, or offer "keep the pocket going" (a fresh run)?
3. **Collection colours.** Automatic stable palette only, or can you pick a colour per playlist/pocket (for example Potential always green)?
4. **Should running/walking leave the device?** v1 keeps motion device-only, so there is no App Privacy label change. Uploading it to the cloud pockets would need "Fitness" on the label.
5. **How hard is the artist ban, within a run and across runs?** I assumed 1 fast skip (under about 15%) or 2 normal skips bans an artist for the rest of *that* run, including songs they feature on, and in future runs that artist is only rarer (×0.33, relaxing over about 30 days). Is that right, or should a ban stick across runs of the same pocket until you un-ban it?
6. **Mode set and labels.** Should cycling be its own mode (I fold it into Trip)? Is "Home" the right name for plays from a playlist/pocket when not driving or moving, or does that mode not deserve a ring sliver at all?
7. **A Mix-mode pocket.** When the best match is a Mix cell, should ▶ load the run into the Mix tab's Auto-DJ (crossfades, decks), or always play through the regular player (my v1 assumption)?
