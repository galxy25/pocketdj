---
name: rip
description: Record a PocketDJ setlist out of Apple Music — play each song in Music.app and capture its output with Audio Hijack, one audio file per song, into a "<unix>_<setlist>_ripped" folder. Finds each song via the exported Apple Music library XML (Persistent ID) with an AppleScript search fallback. Triggers on "rip the setlist", "rip this setlist", "run rip", "record the setlist from Apple Music".
---

# rip

Records a setlist out of **Apple Music** by playing each song in Music.app and capturing
the playback with **Audio Hijack**, producing one audio file per song. Most of the library
streams (no file to copy), so "ripping" = real-time recording of playback.

For each setlist row it: resolves the PocketDJ **Song ID → canonical artist/title** (via
the index), finds the matching Apple Music track in the **exported library XML** to get its
**Persistent ID**, then drives Audio Hijack + Music to record it.

- **Capture:** Audio Hijack (real-time recording of Music's output).
- **Per song:** full track, start to finish.
- **Scope:** only rows found in the Apple Music library; others are skipped and logged.
- **Output:** `<unixSeconds>_<setlist name>_ripped/` containing `NN - Artist - Title.<ext>`
  per song + `rip-manifest.json`.

## Permissions & prerequisites

**Permissions (Automation only — NOT Accessibility):**
- **Music** — already granted; used to `play` and poll playback.
- **Audio Hijack** is driven through **macOS Shortcuts** (`shortcuts run …`), which needs no
  Automation prompt and no Accessibility.

The optional UI-automation fallback the spec mentions *would* need Accessibility — this
skill never does that silently. If AppleScript `play` fails, it logs `play-failed` and moves
on rather than reaching for Accessibility.

**Why Shortcuts:** external `.ahcommand` files can run shell commands but **cannot control
sessions** — Audio Hijack only exposes session control (`event.session` / `app.sessions`) to
in-app Script-Library scripts. The supported external path is AH's **"Run/Stop Session"**
Shortcuts action, triggered from the CLI.

**One-time setup:**
1. In **Audio Hijack**, have a **Session** whose source is the **Music** app + a **Recorder**
   block (e.g. the default `Application Audio` session). Note its Recorder output folder
   (default `~/Music/Audio Hijack`).
2. In the **Shortcuts** app, create two shortcuts (names overridable via flags):
   - **`Rip Start`** → action **Audio Hijack ▸ "Run/Stop Session"** → **Run**, Session =
     `Application Audio`.
   - **`Rip Stop`** → **"Run/Stop Session"** → **Stop**, Session = `Application Audio`.
3. Enable **AH ▸ Settings ▸ Advanced ▸ "Allow execution of external scripts"** (lets the
   Shortcuts JavaScript/Run-Session action work).

Run `--probe` to verify the shortcuts + recordings dir are detected.

**Data prerequisite:** the Apple Music library export must exist
(`index-out/apple-music-library.xml`, built by `scripts/dump-apple-music-library.mjs`).

## Usage

```bash
# 1. Verify the Audio Hijack control shortcuts + recordings dir:
node .claude/skills/rip/rip.mjs --probe

# 2. Preview which setlist songs are in the library (no Music/AH control):
node .claude/skills/rip/rip.mjs --setlist "<csv>" --dry-run

# 3. Live rip (test a couple first):
node .claude/skills/rip/rip.mjs --setlist "<csv>" --limit 2
node .claude/skills/rip/rip.mjs --setlist "<csv>"
```

| flag | default | meaning |
| --- | --- | --- |
| `--setlist <csv>` | — (required) | setlist export; needs a `Song ID` column |
| `--ah-start-shortcut <name>` | `Rip Start` | Shortcut that Runs the AH session |
| `--ah-stop-shortcut <name>` | `Rip Stop` | Shortcut that Stops the AH session |
| `--ah-session <name>` | `Application Audio` | session name (for messages/probe hints) |
| `--ah-recordings-dir <dir>` | `~/Music/Audio Hijack` | the Recorder's output folder |
| `--index <json>` | `public/current-index.json` | resolves Song ID → artist/title |
| `--library-xml <xml>` | `index-out/apple-music-library.xml` | library export (Persistent IDs) |
| `--library-tsv <tsv>` | `index-out/apple-music-library.tsv` | fallback if XML absent |
| `--out-base <dir>` | cwd | where the `<unix>_<name>_ripped/` folder is created |
| `--limit <n>` | all | rip only the first n matched songs (test runs) |
| `--settle-ms <ms>` | `1500` | pause between start-record and play / after stop |
| `--tail-ms <ms>` | `1200` | extra capture past the track's end |
| `--play-start-timeout-ms <ms>` | `20000` | how long to wait for Music to actually reach `playing` |
| `--ah-file-timeout-ms <ms>` | `15000` | how long to wait for AH's file to appear (`0` disables) |
| `--dry-run` | off | resolve matches + write a planned manifest only |
| `--probe` | off | check the control shortcuts + recordings dir |

## How it works

Per song:
1. **Start** — `shortcuts run "Rip Start"` runs the AH session (recording begins to the
   Recorder's folder).
2. **Play** — AppleScript: `play (first track of library playlist 1 whose persistent ID is …)`.
   Fallback: search Music by name+artist (`whose name contains … and artist contains …`).
3. **Confirm playback** — poll `player state` / `player position` until the player is
   *demonstrably* playing (state `playing`, and the position advancing). `play` being accepted
   proves nothing: on 2026-08-12 Music's playback engine wedged after ~25 days of uptime and
   accepted every `play` without error while the player stayed `stopped` with a `missing value`
   position — forever. `duration of t` still answered, because that is library metadata. If the
   player never starts, the song fails as **`play-not-started`** in ~20s instead of recording
   silence for its whole length.
4. **Wait** — keep polling until the track ends (capped at its duration + tail).
5. **Stop** — `shortcuts run "Rip Stop"`, pause Music, then take the newest file from the
   Recorder folder and move it into the output folder as `NN - Artist - Title.<ext>`,
   tagging it (artist/title/album/track) via an `ffmpeg -c copy` remux when ffmpeg is present.

A run is **real-time**: ripping N songs takes roughly the sum of their durations. Use
`--limit` to validate the pipeline on a few songs first.

## Notes

- Depends on the library export being complete. Re-run `dump-apple-music-library.mjs`
  incrementally to pick up newly-added songs before ripping.
- Don't run a rip while the library export is still running — both drive Music and will
  collide.
- Output audio is large/host-local; keep `*_ripped/` folders out of git.
- If `--probe` shows a shortcut MISSING: create it in the Shortcuts app (see setup above).
  Test the shortcuts directly with `shortcuts run "Rip Start"` / `shortcuts run "Rip Stop"`.

## Per-track failure statuses (in `rip-manifest.json`)

"No file was produced" has several distinct causes that used to share one name. They are now
separated, because the remedy differs and guessing cost 38 hours once:

| status | what it means | remedy |
| --- | --- | --- |
| `play-not-started` | `play` accepted; the player never reached `playing` | **restart Music.app** (the rip server does this automatically, once, per `HEAL` in its log) |
| `ah-not-recording` | Music is playing; Audio Hijack wrote no file | check the AH session is running and its Recorder points at `--ah-recordings-dir` |
| `play-failed` | the track could not be played at all | not in the library / no search match |
| `no-recording` | played and AH armed, yet no file at the end | check the Recorder folder + disk space |

The skill **exits non-zero when it captured nothing** (partial success still exits 0), so a
caller cannot read total failure as success. The precise per-track reason is always in
`rip-manifest.json` — read that rather than inferring from the exit code.
