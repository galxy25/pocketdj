# Listening pockets (v1): cloud detection and analysis

A **listening pocket** is a stretch where the user is in a groove: three or more songs in a row with no skip, continuing for as long as they stay in it. The cloud job finds pockets in a profile's uploaded plays, works out what defines each one against the user's own baseline, and groups pockets that recur across days into named patterns. The app shows them under **History ▸ Pockets**.

Code: `scripts/lambda/listening-pockets/`. Every knob is in `params.mjs`.

| Module | Role |
|---|---|
| `params.mjs` | `POCKET_PARAMS` (the algorithm, echoed as `algo.params`) and `POCKET_LIMITS` (storage/wire caps) |
| `detect.mjs` | pure: `normalizeEvents` → `sessionize` → `detectPockets` |
| `analyze.mjs` | pure: `buildBaseline`, `analyzeMembers`, `titleFor`, `clusterPatterns`, `computeResults` |
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
| `DELETE /pockets/state` | Accepts the bound key **or** the enroll secret. Deletes both objects. |
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
- `{job:'nightly'}` runs from EventBridge at 04:30 PDT. It recomputes profiles that are dirty or whose results are older than 20 hours, and chains a continuation when the run is short on time.

`fixtures/results.sample.json` is generated by `run-local.mjs` from `fixtures/upload.sample.json` with `--now 1791831600000`. It is the reference example of results.v1. The test suite checks it against a dependency-free validator of every required key and type.

## Running it

```
node --test scripts/lambda/listening-pockets/test-listening-pockets.mjs
node scripts/lambda/listening-pockets/run-local.mjs \
  --events ~/Library/Containers/com.levi.pocketdj/Data/Library/Application\ Support/pocketdj-play-history.json \
  --features public/rec-features.json --out /tmp/pockets.json
```
