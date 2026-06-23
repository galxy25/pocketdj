# Design: Rip from Cloud Source

## Overview

This feature adds a persisted native setting, **"Rip from cloud source"**
(`SettingsStore.ripFromCloud`). When it is ON, every rip the app requests —
`POST /rip`, `POST /rip-collection`, and (transitively) Burn — carries
`ripFromCloud: true`.

On the server, an **ANALOG** song whose artist/title *exactly* matches an Apple
Music library entry is captured from Apple Music via the existing digital
worker (`rip-one.mjs` → `rip` skill → Audio Hijack → `rips/<songId>.mp3` plus
per-song bpm/key analysis). It falls back to the analog vinyl `ffmpeg` path:

- **Tier 1** (accept time): when there is no exact library match.
- **Tier 2** (worker-terminal time): when a matched capture fails to produce
  audio.

Cloud-ripped analog songs are **indistinguishable from analog rips** to the
app, because the app resolves playback purely by `manifest[songId].key`
(`RipsStore.cachedURL`, lines 134-136) and never branches on source.

**DIGITAL** songs are unaffected — the flag is a harmless no-op, since they
already rip per-song from Apple Music.

### Key product decisions (resolved per reviewer)

- Cloud is chosen **only** on an EXACT library match. A loose match falls back
  to analog, to avoid capturing the wrong audio.
- Collection cloud rips are allowed, but the app warns about real-time cost.
- `runAnalogJob` skips clobbering an existing per-song cloud manifest entry.

All line numbers below are verified against current code on `main`.

---

## The cloud wire flag

Three distinct names exist for the same concept at different layers; keeping
them straight is load-bearing.

| Layer | Name | Notes |
|-------|------|-------|
| Client / persisted | `ripFromCloud` | matches localStorage/PWA naming + the `SettingsStore` field |
| Request body field | `"ripFromCloud"` | sent **only when true**, omitted when false (older-server compat + minimal bodies) |
| Server job field | `job.preferCloud` | stores the **RESOLVED** boolean (post-probe `wantCloud`), NOT the raw request flag |

### Flow

```
SettingsStore.ripFromCloud  (Bool, persisted in pdj.settings.v1)
  -> RipsStore computed:  var ripFromCloud: Bool { settings?.ripFromCloud ?? false }
  -> injected as ["ripFromCloud": true] into the JSON body of
        POST /rip             (RipsStore.swift ensureURL:188, requestRipIfNeeded:331)
        POST /rip-collection  (ripCollection:381)
     ONLY when true
  -> rip-server reads:
        /rip            const { songId, ripFromCloud }  = await readJson(req)   (rip-server.mjs:429)
        /rip-collection const { songIds, ripFromCloud } = await readJson(req)   (:442)
  -> acceptRip(songId, ripFromCloud) PROBES the library:
        wantCloud = ripFromCloud
                 && song.sourceType === 'analog'
                 && findInLibrary(loadLibIndex(), song.artist, song.name).match === 'exact'
  -> sets job.preferCloud = wantCloud   (the RESOLVED value)
  -> persistQueue writes preferCloud into the durable record
  -> resumePending reconstructs job.preferCloud = rec.preferCloud
       and recomputes resourceKey FROM IT (no re-probe)
  -> runJob routes on job.preferCloud
```

### Critical naming distinction (reviewer finding: H-durable-queue)

Persist the **RESOLVED** `preferCloud` (`wantCloud`), not the raw
`ripFromCloud` request flag. This guarantees persist-time and resume-time
`resourceKey` can never disagree: a track later deleted from the library does
not flip the key on restart; it simply resumes as a cloud job that Tier-2
falls back if capture fails. **The probe runs EXACTLY ONCE, at accept time.**

---

## Server cloud-rip routing + Apple Music matching

Routing for an ANALOG song with `ripFromCloud=true` (resolved once at accept
time, EXACT-match only):

1. **`acceptRip(songId, ripFromCloud)`** — after the manifest-skip, probe:
   ```js
   wantCloud = ripFromCloud
            && song.sourceType === 'analog'
            && findInLibrary(libIndex, song.artist, song.name).match === 'exact'
   ```
   EXACT-ONLY is deliberate (reviewer high finding on wrong-match false
   positives): a loose subset match can capture the WRONG track
   ("Intro"/"Interlude"/cover-by-different-artist), and because the result is
   by design indistinguishable from a real rip, the user gets no signal —
   whereas vinyl is always the correct cut, so loose → analog is a benign
   missed opportunity.
   - If `wantCloud`: `resourceKey = songId` (per-song single-flight),
     `job.preferCloud = true`.
   - Else: `resourceKey = albumId` (per-album, unchanged),
     `job.preferCloud = false` (immediate Tier-1 fallback before any capture).

2. **`runJob`** (line 233):
   ```js
   if (song.sourceType !== 'analog' || job.preferCloud) return runDigitalJob(job, song);
   return runAnalogJob(job, song);
   ```
   `runDigitalJob` spawns `rip-one.mjs` with `song.artist`/`song.name` (no
   worker change — `rip-one` captures an arbitrary artist/title from its
   synthesized 1-song index, lines 46-53).

3. **`rip-one`** drives the rip skill → Audio Hijack capture →
   `rips/<songId>.mp3` → status phase `'uploaded'`. On no audio it writes
   status `reason:'no-match'`; on a skill/ffmpeg/aws failure it writes
   `reason:'system'`.

4. **`runDigitalJob`** writes the digital manifest entry
   (`key: rips/<songId>.mp3`, `source:'digital'`, `startMs:null`) and enqueues
   analysis with `withKey=true` (fresh per-song bpm/key/camelot from the
   captured audio, via the unchanged `withKey = e.source !== 'analog'` gate at
   line 340).

DIGITAL-source songs route to `runDigitalJob` exactly as today (flag is a
no-op). Non-cloud ANALOG songs route to `runAnalogJob` exactly as today.

### Library file

The server's accept-time probe and the worker capture **both** use
`CFG.libraryXml` (`~/Downloads/Library.xml`, present at 161MB, single-line
plist that `loadLibraryXML` parses unchanged). `rip-one` is already passed
`--library-xml CFG.libraryXml` (line 281). Do NOT switch to
`index-out/apple-music-library.xml` (ABSENT on this branch).

### Known asymmetry (reviewer medium finding, accepted)

The worker additionally has a live AppleScript `searchAndPlay` fallback that
the static-XML probe lacks, so the probe ("exact in XML") and the worker
("XML + live Music") are not identical:

- A probe `none` that live Music could have played is a benign missed
  opportunity (→ analog).
- A probe `exact` that Music can no longer play wastes one real-time attempt,
  then Tier-2 falls back.

Do **not** add a live `osascript` probe at accept time (per-rip Music
focus-stealing for marginal accuracy); the probe is XML-only and Tier-2 covers
staleness.

---

## Fallback-to-analog rule (two tiers)

### Tier 1 — accept-time, cheap

If the analog song has NO EXACT Apple Music match
(`findInLibrary().match !== 'exact'`, or the library index isn't warm yet),
`wantCloud` is false from the start: `resourceKey` stays `albumId`,
`job.preferCloud = false`, `runJob` takes `runAnalogJob` (ffmpeg-from-vinyl).
This avoids spinning up a real-time capture that is certain to find nothing.

### Tier 2 — worker-terminal

If there WAS an exact match but the worker did not reach phase `'uploaded'`
(no audio → status `reason:'no-match'`; or skill/ffmpeg/aws error →
`reason:'system'`), the **restructured** `runDigitalJob` terminal branch (NOT
the old `else fail()` — see the critical fix) does, for a
`job.preferCloud && song.sourceType === 'analog'` job:

- log a WARN if `reason === 'system'`,
- then `return runAnalogJob(job, song)` **without touching `inflight`**
  (`runAnalogJob` owns the terminal `inflight.delete`).

It does NOT call `fail()` (which would delete `inflight`) and there is NO
unconditional post-`if` `inflight.delete` anymore — every terminal branch (ok
/ fallback / fail) owns its own cleanup. For non-cloud digital songs the
`else` branch keeps `fail(job, st.error)` unchanged.

### Rationale for falling back on BOTH reasons

The product requirement is that the user always gets a playable song; cloud is
best-effort. `reason:'system'` still falls back (so a broken Audio Hijack
doesn't leave the song unplayable) but logs a WARN so the operator can see the
rig is misconfigured rather than silently attributing it to "no cloud match".

Because Tier-2 runs `runAnalogJob` under the per-SONG `resourceKey` (set when
`wantCloud` was true at accept), the fallback produces the full per-album mp3 +
manifest fan-out for all album songs as usual (minus any already-cloud-ripped
sibling, per the clobber-guard); the per-song `resourceKey` simply means
sibling cloud requests on the same album won't have collapsed into this one
job.

**Worst-case latency:** a matched-but-uncapturable song waits through a full
real-time capture attempt before the vinyl transcode starts. Acceptable, and
surfaced in the Settings footer.

---

## Manifest / idempotency handling

### resourceKey / single-flight (cloud-aware in BOTH sites)

The `resourceKey` MUST be cloud-aware in **both** `acceptRip` (line 141) and
`resumePending` (line 188), computed from the RESOLVED `preferCloud`:

```js
perSong     = (preferCloud && analog && exact-match) || sourceType !== 'analog';
resourceKey = perSong ? songId : albumId;
```

A cloud rip captures ONE track → `rips/<songId>.mp3`, so two cloud rips of
different songs on the same album must NOT dedup under `albumId` (they would
falsely inflight-join and the second would never capture). **Changing only one
of the two sites reintroduces the collision after a restart.**

### Durable queue

- `persistQueue` (line 161) MUST persist `preferCloud` (the resolved
  `wantCloud`, not the raw request flag).
- `resumePending` (line 188) reconstructs `job.preferCloud = rec.preferCloud`
  and recomputes `resourceKey` FROM IT **without re-probing** the library
  (reviewer high finding): re-probing at resume could find the song no longer
  matches (library re-exported / track deleted) and flip `resourceKey` between
  persist and resume, mis-keying single-flight. By persisting the resolved
  boolean and not re-probing, a now-deleted track resumes as a cloud job that
  simply Tier-2 falls back at capture (correct + collision-free).
- `queueFile` is already keyed by `songId` (line 159), independent of
  `resourceKey`, so per-song queue files are fine; only `resourceKey`
  reconstruction matters.

### Manifest entry shape (per-song cloud = existing DIGITAL shape, unchanged)

```js
{
  key: 'rips/<songId>.mp3',
  ext: 'mp3',
  bytes,
  source: 'digital',
  albumId,
  startMs: null,                 // REQUIRED — a per-song file must not inherit the album offset
  durationMs: song.length ?? null,
  rippedAt
}
```

Analysis then adds `bpm` / `musicalKey` / `camelot` / `durationMs` /
`waveform` / `analyzed:true` (`withKey=true` because `source !== 'analog'`).
The app reads `manifest[songId].key` only (`cachedURL` line 134-136), so this
is fully indistinguishable from an analog rip.

### Per-song vs per-album

- **Cloud (analog, exact match):** per-SONG. `resourceKey = songId`, S3 object
  `rips/<songId>.mp3`, manifest pointer set for that one song only.
- **Analog (no/loose match):** per-ALBUM. `resourceKey = albumId`, S3 object
  `rips/<albumId>.mp3`, manifest fan-out across all album songs.
- **Digital:** per-SONG, as today.

### Collision cases (resolved, not deferred)

- **(A) Manifest-skip** (line 140): a song with ANY existing manifest entry
  returns `'ready'` and is skipped, so enabling `ripFromCloud` only affects
  not-yet-ripped songs (it will not re-rip an already-analog-ripped song). This
  is the intended semantics (open question noted; default = no override).
- **(B) Album re-rip clobber:** `runAnalogJob`'s per-album fan-out now SKIPS
  overwriting an entry that is already a per-song cloud rip
  (`source !== 'analog' && key === rips/<songId>.mp3`), so a sibling-triggered
  analog album rip preserves prior cloud entries. Orphaned `rips/<songId>.mp3`
  cleanup remains out of scope (none exists today).
  ```js
  for (const s of songsByAlbum.get(album.id) || []) {
    const ex = manifest[s.id];
    if (ex && ex.source !== 'analog' && ex.key === `rips/${s.id}.mp3`) continue;
    manifest[s.id] = {
      key, ext: 'mp3', bytes, source: 'analog', albumId: album.id,
      startMs: s.pointer?.startMs ?? null, durationMs: s.length ?? null, rippedAt
    };
  }
  ```
- **(C) S3 objects** for analog (`rips/<albumId>.mp3`) and cloud
  (`rips/<songId>.mp3`) never overwrite each other; the manifest pointer is
  last-writer-wins per `songId`, now guarded by (B).

---

## S3 upload + bpm/key analysis parity

The analysis pipeline (`enqueueAnalysis` / `pumpAnalysis` /
`analyzeManifestSong`, `resumeAnalysis`) needs **ZERO changes**:

- `audioBase` derives from `e.key` (= `songId` for a cloud file).
- `withKey` from `source !== 'analog'` (line 340) — a cloud rip is
  `source:'digital'`, so it gets fresh per-song bpm/key.
- waveform path is `rips/waveforms/<songId>.png`.

All per-song-correct, no cross-contamination. A cloud-ripped analog song gets
the same bpm/key/camelot/waveform treatment as a native digital rip — full
parity.

S3: cloud rips upload to `rips/<songId>.mp3`; analog rips upload to
`rips/<albumId>.mp3`. The two key spaces are disjoint, so uploads never
overwrite each other.

---

## Server changes

### `scripts/lib/am-match.mjs` (NEW shared module)

Mirrors `scripts/lib/audio-analyze.mjs` (imported at `rip-server.mjs:26`). Move
the matcher out of `.claude/skills/rip/rip.mjs` (it is top-level consts in a
file that runs `main()` on import, so it is NOT importable as-is).

Export: `stripD`, `normTitle` (rip.mjs:112), `normArtist` (:117),
`subsetEither` (:124), `unesc` (:131), `loadLibraryXML` (:132),
`loadLibraryTSV` (:150), `indexLibrary` (:156), `findInLibrary` (:167).

IMPORTANT: `rip.mjs` uses `fs.readFileSync` via `import fs from 'node:fs'`; in
the shared module switch to `import { readFileSync } from 'node:fs'` so
`loadLibraryXML`/`loadLibraryTSV` call `readFileSync` directly. Then refactor
`rip.mjs` to `import { ... } from '../../../scripts/lib/am-match.mjs'` (adjust
relative path) and DELETE its local copies, so there is ONE matcher.

`findInLibrary(lib, artist, title)` returns
`{ hit, match: 'exact' | 'loose' | 'none' }`; the cloud probe treats ONLY
`match === 'exact'` as cloud-eligible.

### `scripts/rip-server.mjs`

1. Import `{ findInLibrary, loadLibraryXML, loadLibraryTSV, indexLibrary }`
   from `./lib/am-match.mjs` (next to the audio-analyze import at line 26).
2. Add a lazily-warmed, cached library index OFF the request path:
   ```js
   let libIndex = null, libIndexLoading = false;
   function warmLibIndex() {
     if (libIndex || libIndexLoading) return;
     libIndexLoading = true;
     setImmediate(() => {
       try {
         const xml = CFG.libraryXml;
         let entries = [];
         if (existsSync(xml)) entries = loadLibraryXML(xml);
         else {
           const tsv = xml.replace(/\.xml$/, '.tsv');
           if (existsSync(tsv)) entries = loadLibraryTSV(tsv);
         }
         libIndex = indexLibrary(entries);
         console.error(`  library index: ${libIndex.count} tracks`);
       } catch (e) {
         console.error('  library index failed', e.message);
         libIndex = indexLibrary([]);
       } finally {
         libIndexLoading = false;
       }
     });
   }
   function hasExactAMMatch(song) {
     if (!libIndex) return false;
     try { return findInLibrary(libIndex, song.artist || '', song.name || '').match === 'exact'; }
     catch { return false; }
   }
   ```
   Call `warmLibIndex()` at startup right after `loadCatalog()` (line 474) so
   the index is ready before the first cloud rip. If a cloud rip arrives before
   it's ready, `hasExactAMMatch` returns false → analog (acceptable; the next
   request after warm will go cloud). Use `CFG.libraryXml` as the single source
   of truth.
3. `acceptRip` signature → `function acceptRip(songId, ripFromCloud = false)`
   (line 137). After the manifest-skip (line 140, unchanged):
   ```js
   const wantCloud = !!ripFromCloud && song.sourceType === 'analog' && hasExactAMMatch(song);
   const perSong = wantCloud || song.sourceType !== 'analog';
   const resourceKey = perSong ? songId : song.albumId;
   ```
   Set the RESOLVED flag on the job at creation (line 147):
   ```js
   const job = { jobId: randomUUID(), songId, resourceKey, preferCloud: wantCloud, phase: 'queued', createdAt: Date.now() };
   ```
4. `persistQueue` (line 161): add `preferCloud` to the persisted record:
   ```js
   JSON.stringify({ songId: job.songId, jobId: job.jobId, resourceKey: job.resourceKey, preferCloud: !!job.preferCloud, createdAt: job.createdAt })
   ```
5. `resumePending` (lines 188-190): reconstruct WITHOUT re-probing:
   ```js
   const preferCloud = !!rec.preferCloud;
   const perSong = preferCloud || song.sourceType !== 'analog';
   const resourceKey = perSong ? songId : song.albumId;
   ```
   and set `preferCloud` on the rebuilt job (line 190).
6. Factor the inline analog path (lines 234-268) into
   `async function runAnalogJob(job, song)` that owns its own terminal
   `inflight.delete(job.resourceKey)` (the existing line 266) — return it from
   `runJob`'s analog branch AND call it from the Tier-2 fallback.
7. `runJob` fork (line 233):
   ```js
   if (song.sourceType !== 'analog' || job.preferCloud) return runDigitalJob(job, song);
   return runAnalogJob(job, song);
   ```
8. `runAnalogJob` clobber-guard (reviewer medium finding B): in the per-album
   manifest loop (lines 256-261), SKIP overwriting a song whose existing entry
   is a per-song cloud rip — see "(B)" under Collision cases above.
9. `runDigitalJob` terminal section RESTRUCTURE (reviewer critical finding —
   the literal `else fail()` already deletes `inflight` at line 127, and line
   317 deletes again, so a one-line swap is broken). Replace lines 305-317 with
   explicit per-branch cleanup:
   ```js
   const ok = st.phase === 'uploaded' && st.key;
   if (ok) {
     manifest[song.id] = {
       key: st.key, ext: 'mp3', bytes: st.bytes || 0, source: 'digital',
       albumId: song.albumId, startMs: null, durationMs: song.length ?? null, rippedAt: Date.now()
     };
     await saveManifest();
     job.url = publicUrl(st.key);
     setPhase(job, 'ready', { message: `${song.name} ready` });
     enqueueAnalysis(song.id);
     inflight.delete(job.resourceKey);
   } else if (job.preferCloud && song.sourceType === 'analog') {
     if (st.reason === 'system')
       console.error(`  WARN cloud capture system failure for ${song.id} (${st.error}); falling back to analog`);
     return runAnalogJob(job, song);   // runAnalogJob owns inflight.delete; do NOT touch inflight here
   } else {
     fail(job, st.error || 'rip failed');   // fail() deletes inflight
   }
   ```
   Note `runAnalogJob`'s `resourceKey` is the per-SONG key (set when
   `wantCloud` was true), so the fallback still fans out the whole album's
   manifest entries but sibling cloud requests on that album won't have
   collapsed into this job.
10. NO change to `analyzeManifestSong`: `withKey = e.source !== 'analog'` (line
    340) already gives a cloud rip (`source:'digital'`) fresh per-song bpm/key.
11. Read the flag in both endpoints:
    - `/rip` (line 429):
      `const { songId, ripFromCloud } = await readJson(req); const r = acceptRip(songId, ripFromCloud);`
    - `/rip-collection` (line 442):
      `const { songIds, ripFromCloud } = await readJson(req); ... results = ids.map((id) => { const r = acceptRip(id, ripFromCloud); ... });`

### `scripts/rip-one.mjs`

Emit a match-class reason in the status file so the server can distinguish a
legitimate no-match from a broken capture rig.

- (a) Change the no-audio fail at line 132 to tag `reason:'no-match'`. Extend
  `fail` to accept an optional reason:
  ```js
  const fail = (msg, reason) => {
    status('error', { error: msg, ...(reason ? { reason } : {}) });
    console.log('RESULT ' + JSON.stringify({ ok: false, error: msg, ...(reason ? { reason } : {}) }));
    process.exit(1);
  };
  ```
  and call
  `fail('no audio captured — is the track in the library and audio routed to system output?', 'no-match')`
  at line 132.
- (b) Tag the rip-skill-failed path (line 120) and the ffmpeg/aws upload
  failures (lines 139, 143) as `reason:'system'`
  (`fail('rip skill failed: ' + e.message, 'system')`, etc.).

The server falls back to analog for BOTH reasons on a `preferCloud` analog job
(so the user always gets a playable song), but logs a WARN for
`reason === 'system'`. No other worker change is needed — `rip-one` already
synthesizes a 1-song index from `--artist`/`--title` (lines 46-53) and captures
an arbitrary track regardless of source type.

---

## Native changes

### `apple/PocketDJ/Settings/SettingsStore.swift`

Add the persisted toggle across the `@Observable` class AND the `Codable`
snapshot, with `Bool?` back-compat (reviewer critical Codable finding — `load()`
at line 117 uses `try?` and falls back to `.default` on ANY decode error, so a
non-optional `Bool` would SILENTLY wipe `sources`/`ripServerURL`).

1. Add `var ripFromCloud: Bool` to the `@Observable` class after `ripToken`
   (line 23).
2. `init` (line 36): `self.ripFromCloud = data.ripFromCloud ?? false`.
3. `persist()` `SettingsData(...)` snapshot (lines 95-98): add
   `ripFromCloud: ripFromCloud`.
4. `resetEverything()` (line 110): add `ripFromCloud = d.ripFromCloud ?? false`.
5. `struct SettingsData` (lines 124-131): add `var ripFromCloud: Bool?`
   (OPTIONAL — synthesized `Decodable` treats a missing key as nil, so old
   `pdj.settings.v1` blobs decode fine and preserve `sources`/URL).
6. `SettingsData.default` (lines 132-138): add `ripFromCloud: false`.

The `@Observable` class property stays non-optional `Bool`; only the `Codable`
struct field is `Bool?`, coalesced at the two read sites (init +
resetEverything).

### `apple/PocketDJ/State/RipsStore.swift`

Add `var ripFromCloud: Bool { settings?.ripFromCloud ?? false }` alongside
`serverUrl`/`token`/`hasServer` (lines 100-102). Inject the flag into all THREE
POST bodies, only when true (omit when false for older-server compat):

- `ensureURL` (line 188) and `requestRipIfNeeded` (line 331):
  ```swift
  let body: [String: Any] = ripFromCloud ? ["songId": songId, "ripFromCloud": true] : ["songId": songId]
  post.httpBody = try JSONSerialization.data(withJSONObject: body)
  ```
- `ripCollection` (line 381):
  ```swift
  let body: [String: Any] = ripFromCloud ? ["songIds": ids, "ripFromCloud": true] : ["songIds": ids]
  ```

Adding it to `requestRipIfNeeded` covers BOTH the play-time async rip
(`RipServerPlaybackProvider.requestAsyncRip` delegates to it) and
`ripCollectionFallback`'s per-song loop.

**Play-time + analog (reviewer low finding):** `requestRipIfNeeded` is the
play-time target; an analog song with `ripFromCloud=on` that reaches it would
kick a real-time capture. Verify in `PlaybackCoordinator` that the play-time
async rip only fires for songs streamed from a play-time (digital) source; if
analog songs can reach it, the existing cachedURL/in-flight/requesting guards
(lines 316-318) already suppress repeats, and Tier-1 (exact-match-only) limits
it to analog songs that genuinely exist in the library.

No `ManifestEntry`/`cachedURL` change — a cloud entry (`key rips/<songId>.mp3`,
`source:'digital'`, `startMs:null`) is already indistinguishable.

### `apple/PocketDJ/Views/SettingsView.swift`

In `ripSection` (Section at lines 247-276), add after the Token TextField (line
258):
```swift
Toggle("Rip from cloud source", isOn: $settings.ripFromCloud)
  .accessibilityIdentifier("settings-rip-from-cloud")
```
The view binds `@Bindable settings` so `$settings.ripFromCloud` works. Persist
on change for immediate save (matches the Test button calling
`settings.persist()` at line 261):
```swift
.onChange(of: settings.ripFromCloud) { settings.persist() }
```
Update the Section footer (line 274) to mention cloud capture, e.g.:

> When "Rip from cloud source" is on, songs that match your Apple Music library
> are captured from Apple Music (real-time, one at a time) and fall back to
> vinyl otherwise.

### `apple/PocketDJ/Views/CollectionRipBurn.swift`

Verified **NO code change required** for Burn transitivity: `controller.rip`
(line 61) and `controller.burn` (line 85) both call `rips.ripCollection(...)`,
which now carries `ripFromCloud` — so Burn-triggered rip enqueues honor
cloud-with-analog-fallback automatically.

OPTIONAL UX (reviewer high finding): when `rips.ripFromCloud` is true and the
collection has many not-yet-ripped songs, prepend a note to the summary (e.g.
"cloud rips capture in real time, one at a time") in `rip()` (line 69) and
`burn()` (line 91) so the user understands the duration.

### `apple/Tests/Unit/SettingsTests.swift`

1. Add a `ripFromCloud` round-trip to `testPersistAndReload` (lines 18-33).
2. Add a REGRESSION test that hand-rolls a v1 JSON blob WITHOUT the
   `ripFromCloud` key, writes it to `pdj.settings.v1`, constructs
   `SettingsStore`, and asserts `sources`/`ripServerURL` survive AND
   `ripFromCloud == false`. (This is the real guard for the Codable back-compat
   trap, not just a new-field round-trip.)
3. Confirm `testResetRestoresDefaults` (lines 56-65) resets `ripFromCloud` to
   false.

Also update any exact-POST-body assertions in `RipsStoreTests.swift` /
`RipsStoreAsyncRipTests.swift` / `BurnStaleTests.swift` — the flag is now
conditionally present; default-off bodies are unchanged so most assertions
still pass; add a `ripFromCloud=true` case asserting the body contains
`"ripFromCloud"`. Add a `SettingsUITests` case for the `settings-rip-from-cloud`
toggle id.

---

## Risks

- **Tier-2 fallback requires the `runDigitalJob` terminal RESTRUCTURE**
  (per-branch inflight cleanup), not a one-line swap: `fail()` at line 127
  deletes `inflight` and the old unconditional line-317 delete must be REMOVED,
  or `runAnalogJob` will set `inflight` then line 317 deletes it mid-job and a
  duplicate sibling job can start. Add a test forcing `st.phase !== 'uploaded'`
  for an analog+preferCloud job asserting exactly one `inflight` entry during
  the run + a `source:'analog'` `rips/<albumId>.mp3` manifest entry.
- **`resourceKey` must change in TWO places** (`acceptRip` line 141 and
  `resumePending` line 188) in lockstep — fixing one reintroduces same-album
  cloud-rip collisions only after a restart, easy to miss in testing.
- **Persist the RESOLVED `preferCloud`** (`wantCloud`) not the raw request
  flag, and do NOT re-probe in `resumePending` — re-probing can flip
  `resourceKey` between persist and resume (library re-exported / track deleted)
  and mis-key single-flight.
- **Extracting the matcher** to `scripts/lib/am-match.mjs` must refactor
  `rip.mjs` to import from it (`rip.mjs` runs `main()` on import, so importing
  `rip.mjs` directly would execute a rip) AND switch
  `loadLibraryXML`/`TSV` from `fs.readFileSync` to a direct `readFileSync`
  import.
- **EXACT-only cloud gating** means analog songs present in the library under a
  slightly different artist/title (loose match) silently rip from vinyl instead
  of cloud — intentional (vinyl is always correct) but means the feature
  "misses" some cloud-eligible songs; documented, with the live `searchAndPlay`
  providing no help since the probe gates first.
- **Library freshness:** `~/Downloads/Library.xml` is a manual Export Library
  file (Jun 17, 161MB) and can be stale; a newly-added analog song not yet
  exported reports no exact match and falls back to vinyl. Re-export / run
  `dump-apple-music-library.mjs` to refresh; Tier-2's live `searchAndPlay` does
  not help because the accept-time probe gives up first.
- **Whole-collection cloud rips** serialize at concurrency-1 and are REAL-TIME
  (a 4-min song takes ~4 min); a large Burn could take hours and there is no
  cancel endpoint. Mitigated only by the Settings-footer + summary warnings; a
  server-side cap / cancel is left as an open question.
- **Codable back-compat:** `SettingsData.ripFromCloud` MUST be `Bool?` (`load()`
  at lines 117-118 falls back to `.default` via `try?` on any decode error,
  silently wiping `sources`/`ripServerURL` if a non-optional `Bool` fails to
  decode an old blob). The regression test must use a hand-rolled key-less blob,
  not just a round-trip.
- **Live progress:** a cloud rip of an analog song with `length:null` yields
  `totalMs:null` (`--length-ms 0`), so the HLS job view shows indeterminate
  progress instead of a percentage. Cosmetic.
- **Library index memory:** caching the 161MB library index in memory adds RSS
  and first-warm CPU; warming off the request path at startup avoids stalling
  `/rip`, but an mtime-based rebuild-in-background invalidation is left
  unspecified (current design warms once at startup; a library re-export
  requires a server restart to pick up — acceptable, documented).

---

## Deferred / open questions

- **Re-rip override:** Should enabling `ripFromCloud` RE-RIP songs already
  cached as analog (override), or only apply to not-yet-ripped songs? Current
  `acceptRip` manifest-skip (line 140) means only not-yet-ripped songs go cloud;
  an override would require making the skip source-aware (skip only when the
  existing entry already satisfies the request).
- **Collection cloud rip cost:** Keep collections cloud-eligible (current
  design, with UX warnings) or cap/skip cloud for collections and apply
  `ripFromCloud` only to single `/rip` + play-time? And do we add a
  cancel/queue-drain endpoint so a runaway real-time cloud collection can be
  stopped (none exists today)?
- **Library-index invalidation:** warm-once-at-startup (current design — a
  library re-export needs a server restart) vs an mtime-based background
  rebuild. Restart-only is simplest; confirm acceptable.
- **Persist timing:** persist the toggle on change (current design, immediate
  via `onChange`) vs only on Settings disappear (the URL/token pattern). Chose
  immediate to match the Test button's persist; confirm UX preference.
- **`reason:'system'` surfacing:** Should `reason:'system'` capture failures
  (Audio Hijack down) surface a user-visible error instead of silently falling
  back to vinyl? Current default: fall back (always playable) + WARN log;
  revisit if silent fallback hides setup problems.

---

## Matching philosophy — prefer tight matching (the user's personal recordings)

`am-match` resolves an analog song to an Apple Music recording, and that decision
governs both **cloud-rip routing** (capture from Apple Music vs vinyl) and the
**cloud re-index** (overwrite length/bpm/key from the cloud source of truth). We
deliberately match **tightly**:

- A **recording/version parenthetical** must **agree** for a match to count as
  `exact`: mix, remix, edit, radio/LP/album/single version, 7″/12″, instrumental,
  live, acoustic, dub, extended, club, a cappella, reprise, demo, sped-up/slowed,
  rework, vip, bootleg.
- **Cosmetic markers are ignored** (they don't change the recording): remaster,
  deluxe, anniversary, bonus, mono/stereo, explicit/clean, and `feat.`/credits.

**Why:** PocketDJ is built around the user's *own* collection. The specific club
mix, 7″ edit, or single version they own on vinyl is an intentional, personal
choice — that exact cut is the music we want to bring into the pocket so they can
produce and play lists of *their* music. Collapsing it onto the catalog's standard
recording loses what makes it theirs **and** corrupts its length/bpm/key (a club
mix is not the radio edit — e.g. *Living In Danger (For The Big Clubs Only Mix)*
620s vs the standard 193s).

**Consequence:** on any version-marker disagreement we do **not** match — we keep
the personal/analog source (cloud rip falls back to vinyl; the re-index leaves the
analog value untouched). Lower match coverage is the accepted price of fidelity.
Tightening the matcher dropped exact matches 2594 → 2298 (~11%) and cut spurious
>60s length overwrites 153 → 70, where all 70 survivors are genuine same-recording
length corrections.
