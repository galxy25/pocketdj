# Listening pockets (v1): cloud detection and analysis

A **listening pocket** is a stretch where the user is in a groove: three or more songs in a row with no skip, continuing for as long as they stay in it. The cloud job finds pockets in a profile's uploaded plays, works out what defines each one against the user's own baseline, and groups pockets that recur across days into named patterns. The app shows them under **History ▸ Pockets**.

Code: `scripts/lambda/listening-pockets/`. Every knob is in `params.mjs`.

| Module | Role |
|---|---|
| `params.mjs` | `POCKET_PARAMS` (the algorithm, echoed as `algo.params`) and `POCKET_LIMITS` (storage/wire caps) |
| `detect.mjs` | pure: `normalizeEvents` → `sessionize` → `detectPockets` |
| `analyze.mjs` | pure: `buildBaseline`, `analyzeMembers`, `titleFor`, `clusterPatterns`, `computeResults` |
| `collections.mjs` | pure: collection membership vectors (hard + soft + add-time recency), add sessions, pattern `collectionCandidates` — see `pockets-collections.md` |
| `features.mjs` | `loadFeatures` (CDN, 15 min TTL, `POCKETS_FEATURES_FILE` seam), `indexFeatures`, `resolveSong` |
| `store.mjs` | S3 / local-dir objects, ETag-conditional puts; the stored row (`cleanEvent`) and per-id merge (`mergeEvents`) |
| `index.mjs` | HTTP routes, auth, async compute job, nightly job |
| `run-local.mjs` | the job with zero AWS (upload batch, event array, or a raw `pocketdj-play-history.json`) |
| `deploy.sh` | creates the function, routes, and nightly rule. **Not run yet; needs approval.** |

## Detection

1. **Normalize.** Drop `game` plays. A play's stream is its originating install. An outcome of `skipped` is a skip. `completed`, `partial` and `unknown` count as plays by default; `partialIsPlay` and `unknownIsPlay` control the last two. Sort by `(stream, atMs, ord, id)`.
2. **Sessionize** each stream. A new session starts when consecutive starts are **more than** 30 minutes apart. A gap of exactly 30 minutes stays in the same session.
3. **State machine** per session:
   - A pocket opens at 3 consecutive plays.
   - A later play joins the pocket.
   - A single skip is excluded from the members and counted in `skippedCount`, but it does not end the pocket.
   - **2 skips in a row** end the pocket, and scanning restarts after them. The pocket also ends at the end of the session.
   - Skips at the end of a pocket are not counted.
4. **Pocket id.** `pk_` + 12 hex characters of sha256(first member's event id). The id survives appended plays and re-ordered uploads.

## Analysis

Each play gets attributes from `rec-features.json`, matched by any of the song's ids (`_clean`/`_explicit` resolve to the base id, `amrec_<id>` resolves through `am`). When the catalog has no row, the play's artist snapshot is used.

| Attribute | Derived from |
|---|---|
| artist | `a` |
| genre | `g` |
| mood | `s` (multi-valued) |
| camelot | `c` |
| bpm | `b`, folded into [80, 160) |
| energy | mean of `t.loud` and `t.punch` |
| year | `y` |
| source, carPlay, place, trip | the play event |
| local hour, dow, dayType, timeBucket | `atMs + tzOffsetMin`. A play with no offset uses the profile's most common offset. |

The **baseline** is every play (not skip) from the last 90 days.

**Categorical features** count as defining when they are concentrated in the pocket compared with the baseline. Define `share = in/n`, `baselineShare = (base + 1)/(N + K)` and `lift = share/baselineShare`. A feature is defining when all of these hold:

- `share ≥ 0.4`;
- `lift ≥ 1.5` for musical dimensions (artist, genre, mood, camelot), or `lift ≥ 1.25` for context dimensions (timeBucket, dayType, dow, source, place, trip, carPlay);
- `count ≥ 2`, for musical dimensions only.

`score = share · ln(lift)`. The top 8 features by score are kept.

**Numeric features** (bpm, energy, year) are defining when all of these hold:

- coverage ≥ 0.6;
- at least 3 values;
- `std_in / std_baseline ≤ 0.5`.

**Harmonic flow** is defining when, across at least 2 consecutive keyed transitions, the share of neighbouring Camelot moves is at least 0.5 **and** at least twice the baseline's chance rate.

The **title** is built from these parts, in order:

1. the time phrase;
2. the place or trip label, if it is defining;
3. `lo–hi BPM`, if BPM is defining;
4. the top defining genre, or the top defining artist if no genre is defining.

For example: "Weekday morning · A → B · 118–124 BPM · Electronic". If no parts apply, the title is "Listening pocket".

**Patterns** are built in two passes:

1. Group by `dayType|timeBucket|ctx|genre`. The context is the trip or place id; the genre is the one holding at least half of the pocket.
2. Group the pockets left over by `dayType|timeBucket|*|genre`.

A group becomes a pattern when it has at least 2 pockets on at least 2 distinct local dates. The pattern id is `pt_` + sha256(key)[0:12]. A→B and B→A are separate trip ids, so they form separate patterns.

## HTTP contract

The function is mounted on the rec-engine HTTP API (`Config.recEngineBase`) under `ANY /pockets` and `ANY /pockets/{proxy+}`. The handler strips a leading `/pockets` and trailing slashes.

Auth matches the rec engine: a bearer key, a scoped `X-PocketDJ-Profile`, and `X-PocketDJ-Enroll` to create state. Creating state is capped at `MAX_PROFILES`. This service keeps its own trust-on-first-use key binding.

| Route | Result |
|---|---|
| `POST /pockets/events` (upload.v1, ≤ 2000 events, ≤ 4 MB) | `200 {ok, accepted, updated, unchanged, rejected, total, dirty}` |
| `GET /pockets/results` | the results.v1 document, `stale = events changed since the last compute`. Before any upload it returns the empty shape. |
| `POST /pockets/rounds` (rounds.v1, ≤ 50 rounds, ≤ 4 MB) | "In the Pocket" game rounds — see [In the Pocket](#in-the-pocket-the-game-that-labels-pockets). `200 {ok, accepted, updated, unchanged, rejected, total, dirty}` |
| `DELETE /pockets/state` | Accepts the bound key **or** the enroll secret. Deletes both objects (rounds included). |
| `GET /pockets/health` | Unauthenticated. `{ok:true, service:'listening-pockets', version:1}` |

**Merge rules, per event id:**

- `atMs`, `ord`, `songId` and `installId` cannot change after the first upload.
- `outcome` keeps the highest rank: skipped > completed > partial > unknown.
- `fraction` keeps the maximum.
- The first non-null `ctx` wins.
- `tz`, `artist`, `carPlay` and `source` keep the first value received.

Storage limits: 20k events per profile, 180-day retention, and every string capped at 256 bytes.

**Objects**, stored in `pocketdj-rec-011183829623`:

- `pockets/events/<sha256(profileId)>.json`
- `pockets/results/<…>.json`

**Jobs:**

- `{job:'compute', p}` runs as an async self-invoke after an upload that changed something.
- `{job:'nightly'}` runs from EventBridge at 04:30 PDT. It recomputes profiles that are dirty or whose results are older than 20 hours, and chains a continuation when the run is short on time. A full run (no explicit `hashes`) first deletes any results object whose events object is gone.

**Results never go backwards or outlive their events.** Every upload that changes something bumps the events document's `rev`. A compute stamps its results with the `createdAtMs` and `rev` it read (`_source`, stripped from GET) and writes them conditionally on the results ETag. If the stored results come from a newer `rev` of the same document, it does not write. After writing it re-reads the events: if they are gone (a "Delete cloud data" landed mid-compute) or are a new document, it deletes the results it just wrote.

**App-side consent and deletion.** "Find my listening pockets" is its own opt-in, off by default (`SettingsStore.listeningPocketsChoice`: nil = never asked, which History ▸ Pockets offers once). "Delete cloud data" stores `uploadFloorMs` in the device's sync document, and plays before it never upload again; no flush can start while the DELETE is in flight. When pockets or the engine turn off, places & trips turn off too (`ListeningPocketsService.onDisabled`).

**Location settle rule.** A recent time (inside `pendingHorizon`) that falls inside a stay with no reported departure (still open, or ended only by the next arrival or a movement hint) is `.pending`, not that place: CLVisit departures arrive late and back-dated, and settling is write-once, so a commute play must not be stamped with the place just left.

`fixtures/results.sample.json` is generated by `run-local.mjs` from `fixtures/upload.sample.json` with `--now 1791831600000`. It is the reference example of results.v1. The test suite checks it against a dependency-free validator of every required key and type.

**App ↔ cloud contract, enforced from both suites.** Two goldens in `apple/Tests/Fixtures/` close the loop:

1. `listening-pockets-upload.app.json` is what the app actually POSTs for a deterministic three-week commuter scenario. `ListeningPocketsContractTests.testAppUploadMatchesGolden` builds it from real `PlayEvent`s, the real verdict calls, the settle pass and the real `ListeningPocketsService` flush, and fails when the body drifts.
2. `listening-pockets-results.app.json` is what the cloud computes for (1). The node "app contract" tests send (1) through the handler (POST, inline compute, GET) and through `run-local.mjs`, and fail when either output differs from it.
3. `ListeningPocketsContractTests.testCloudResultsForTheAppUploadDecode` decodes (2) with the app's own decoder and checks it against the scenario.

After an intended change, regenerate in order: the Swift golden first (`TEST_RUNNER_PDJ_REGEN_POCKETS_CONTRACT=1 xcodebuild test … -only-testing:PocketDJTests/ListeningPocketsContractTests/testAppUploadMatchesGolden` on an iOS simulator), then `POCKETS_REGEN_CONTRACT=1 node --test …`.

`ord` is the play's position among the plays in the same stream and floored minute, counted over the device's whole history rather than per upload. The server keeps `ord` from the first insert, so a same-minute play uploaded by a later flush still gets the next number instead of tying at 0.

## In the Pocket: the game that labels pockets

**Games ▸ In the Pocket** turns pocket detection into a prediction the user can grade. A round bets on 3–4 songs the user will play straight through *right now, here*; whatever happens is a labelled example the analysis learns from. The game needs **Find my listening pockets** on (it shows the same opt-in offer — `ListeningPocketsOptInView` — and never flips it).

App code: `apple/PocketDJ/Games/InThePocket/`.

| File | Role |
|---|---|
| `InThePocketModels.swift` | `InThePocketContext` (the cloud's time buckets), round / song / outcome types, the rounds.v1 wire |
| `InThePocketScorer.swift` | pure, seeded round builder; `InThePocketLearning` (the cloud formula, on device) |
| `InThePocketRoundEvaluator.swift` | pure outcome state machine over the play-history log |
| `InThePocketStore.swift` | app-scoped: build off-main, play via `SetlistPlayer` (`itp_<round id>` run tag → History "Game · In the Pocket"), 1 Hz tracking, local file, scoreboard, upload rows |
| `FeedbackDictation.swift` | the feedback mic: `SFSpeechRecognizer`, `requiresOnDeviceRecognition` always (no mic where the device can't) |
| `InThePocketView.swift` | the screen |

**Context.** Time bucket + weekday/weekend + day of week from the device clock and UTC offset (the same buckets as `params.mjs`), plus — only while places & trips is on — a *guess* at the current place or trip: `ListeningPlaceEngine.currentGuess` (inside an open stay → that place; left within 4 h → the trip most often taken from there, else "Leaving A"). A guess is never stamped onto a play; settling stays write-once.

**Building a round** (`InThePocketScorer`, deterministic given its seed, which is stored and uploaded):

1. **Profile.** `cloud`: every pattern and pocket whose time bucket matches now, weighted `2 (+1 same day type) (+2 same place/trip)`, patterns × `1 + ln(occurrences)`. Their *musical* defining features (genre, artist, mood, camelot) become weighted targets; their BPM range a band; their member/top songs "seed songs". `history`, when there are no matching cloud results: the same profile from this device's own non-skipped plays in this context (bucket + day type, else bucket). `cold`: from all non-skipped plays.
2. **Round learning** multiplies target weights for this context (the cloud's `rounds` section, exact context key then relaxed; else the same formula over this device's finished rounds) and adds targets with multiplier ≥ 1.25 on ≥ 2 positive rounds.
3. **Score** every playable candidate (rip manifest, burned, or Apple Music with a store id): matched target weights + `0.6 ·` BPM fit + `0.8 ·` seed strength + familiarity (play-through rate, play count). Candidates related to nothing are dropped; anything played in the last 48 h, or in the last three rounds, is excluded.
4. **Pick** a seeded weighted draw from the top 8, then for each next song re-rank for coherence (+0.3 same genre, +0.3·e^(−ΔBPM/10)) and diversity (−1 per same artist) and draw from the top 6. **4 songs in `cloud` mode, 3 otherwise.**

The UI shows *why* as opaque chips: "Weekday evening · Location A · 118–126 BPM · Funk/Soul", and says when the round came from history instead of pocket results.

**Tracking** reuses the app's one skip machinery: `SkipTracker` writes `wasSkipped` / `listenedFraction` onto the `PlayHistoryStore` events every surface records, and `InThePocketRoundEvaluator` reads the log since ▶. Song *k* starts when the next event is song *k*; a replay of an earlier round song (⏮) is ignored; any other song is foreign. A skip verdict breaks the round at once ("Broke at song *k*"). A song is played through when the next round song starts unskipped, or it reaches 90 %, or — once the round has ended — it reached 50 % or its fraction is unknown. All played through = **in the pocket**. A foreign play, the sequencer no longer running the round's tag, "End round", or 3 h idle ends the round; anything unresolved is **abandoned**. End signals settle for 8 s (a skip verdict can land one track late; the last song's fraction lands with the stop checkpoint). Pausing produces no events, so it is never a skip. The store's ticker runs app-scoped, so leaving the screen does not stop tracking.

**Feedback.** During or after a round: an optional 1–5 rating and a free-text field (typed or dictated; capped at 2000 UTF-16 units on device and again on the server). Dictation appends the live transcript to what was typed; denied permission disables the mic with an explanation; tvOS has no mic.

**Upload.** Finished rounds ride `ListeningPocketsService`'s flush after the plays, under the same gate, key and enrollment. Each round is acknowledged by fingerprint only on 2xx (a later feedback edit moves `updatedAtMs` and re-sends). **A 404 — a backend without the route — leaves every round queued, silently, for the next flush**; so does any other failure. Rounds before the "Delete cloud data" floor never upload. The local file `pocketdj-in-the-pocket.json` is device-local (never CloudSync'd) and is erased with the account. Scoreboard rows (`GameKind.inThePocket`, score = songs played through, `detail.outcome`) sync like every game; the Games card shows rounds played, pocket rate (pocket ÷ decided rounds) and best streak.

### `POST /pockets/rounds` (rounds.v1)

```
{ v:1, installId, deviceId?, sentAtMs, rounds:[{
    id (UUID), originInstallId?, startedAtMs, endedAtMs?, updatedAtMs, tzOffsetMin,
    context:{ timeBucket, dayType, dow, ctx: {kind:'place',placeId} | {kind:'trip',tripId,origin,destination} | null },
    mode: cloud|history|cold, seed, algoVersion,
    targets:[{dim, value, weight}],              // what the prediction was built from (bpm as "lo-hi")
    songs:[{songId, artist, score, outcome: completed|skipped|partial|notPlayed, fraction}],
    outcome: pocket|broke|abandoned, brokeAt (1-based, required for broke), rating 1–5?, feedback?, appVersion }] }
```

Same auth, enrollment, profile cap, 4 MB body limit and ETag read-merge-write as `/events` (one shared `upsertProfile` path). `cleanRound` floors times to the minute, bounds every string, caps feedback at 2000 characters (no split surrogate pairs, control characters stripped), degrades unknown optional tokens and rejects non-labels (bad id, unknown outcome, no songs, a break without a position, outside retention). Rounds are stored in the **same events object** (`doc.rounds`, created only when the first round arrives — an events-only profile keeps its exact document shape), merged per id with the newer `updatedAtMs` replacing the row, 180-day retention, 500 per profile oldest first. A change marks the document dirty and recomputes, exactly like plays. `DELETE /state` removes them with everything else.

### How rounds feed the analysis

`learnFromRounds` (analyze.mjs; knobs in `ROUND_PARAMS`, kept OUT of `POCKET_PARAMS` so `algo.params` — and every results document of a profile that never played — is unchanged):

- **Labels.** `pocket` = positive; `broke` at song ≤ 2 = negative (the prediction missed early); a late break or an abandoned round = neutral.
- **Contexts.** Each round credits `dayType|timeBucket|*`, and also `dayType|timeBucket|place:<id>` / `trip:<id>` when it had one.
- **Weights.** Every target of a labelled round gets `pos`/`neg` in each of its contexts; `multiplier = clamp(2·(pos+1)/(pos+neg+2), 0.25, 2)` — exactly 1 with no evidence, 1.6 after three pockets, 0.4 after three early breaks.
- **Output.** Results gain `rounds: {v, params, total, pocket, broke, abandoned, positives, negatives, pocketRate, contexts:[{key, dayType, timeBucket, ctx, rounds, positives, negatives, weights:[{dim, value, pos, neg, multiplier}]}]}` — present only once the profile has rounds. The app multiplies its next round's target weights by them (`InThePocketLearning` is the same formula on device, used until the cloud has recomputed).

Game plays are recorded with source `game`, which detection already excludes (`excludeSources`): a round never manufactures the pockets it is graded against; its label reaches the analysis only through `/rounds`.

## Running it

```
node --test scripts/lambda/listening-pockets/test-listening-pockets.mjs
node scripts/lambda/listening-pockets/run-local.mjs \
  --events ~/Library/Containers/com.levi.pocketdj/Data/Library/Application\ Support/pocketdj-play-history.json \
  --features public/rec-features.json --out /tmp/pockets.json
```
