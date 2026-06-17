---
name: burn-setlist
description: Burn a PocketDJ setlist export (CSV) into a folder of ready-to-mix audio files — one per song — by carving each song out of its raw vinyl rip using the segment boundaries stored in the music index. Each audio file gets a same-named .txt sidecar with BPM, keys (pitch + Camelot), sentiment keywords, album name, and full song/album metadata. Triggers on "burn the setlist", "burn this setlist", "run burn-setlist", "render the setlist to audio".
---

# Burn Setlist

Turns a setlist CSV export (the `#,Artist,Title,BPM,Key,Length,Source,Sequence,Song ID`
shape PocketDJ produces) into a folder you can drop onto a device and mix live. For each
row it looks the song up in the index by **Song ID**, finds its raw vinyl rip and the
in-rip segment boundaries (`pointer.filename` + `pointer.startMs`/`endMs`), and uses
`ffmpeg` to carve out just that song. Every audio file is paired with a `.txt` sidecar of
the same basename holding the metadata.

## What it produces

In `<out>/<setlist name>/`:

- `NN - Artist - Title.<ext>` — the carved audio (default `mp3` @ 320k).
- `NN - Artist - Title.txt` — sidecar. **Top of file, in this order:** BPM · Key (pitch +
  Camelot) · Sentiment keywords · Album. Then the setlist position, the segment
  (source rip + start/end/duration), full song metadata, full album metadata, and a raw
  JSON dump.
- `setlist.m3u8` — the play order.
- `burn-manifest.json` — machine-readable summary of every burned track.

`NN` is the setlist position (zero-padded), so the folder sorts in play order and names
stay unique even when several songs come off the same rip.

## Requirements

- `ffmpeg` / `ffprobe` on PATH (`brew install ffmpeg`).
- The raw rips mounted at the `--source` dir (this index's rips live on
  `/Volumes/RipBurnMix/`; the filename per song is `song.pointer.filename`).
- The index JSON the app loads (`public/current-index.json`). Each song needs a
  `pointer` with `filename`, `startMs`, `endMs` — these are written by the analog-indexer
  audio stage (`apply-audio.mjs`), derived from the album's `audioTracks` segments.

## Usage

```bash
node .claude/skills/burn-setlist/burn-setlist.mjs \
  --setlist "/path/to/export.csv" \
  --out .                       # base dir; a <setlist name>/ subfolder is created inside
```

Common options (run with no args, or read the header of `burn-setlist.mjs`, for the full list):

| flag | default | meaning |
| --- | --- | --- |
| `--setlist <csv>` | — (required) | the setlist export; must have a `Song ID` column |
| `--index <json>` | `public/current-index.json` | music index to resolve songs against |
| `--source <dir>` | `/Volumes/RipBurnMix` | folder holding the raw vinyl rips |
| `--out <dir>` | cwd | base output dir (subfolder named after the setlist is created) |
| `--name <str>` | CSV basename | override the output subfolder name |
| `--format <ext>` | `mp3` | `mp3` \| `wav` \| `aiff` \| `flac` \| `m4a` |
| `--bitrate <rate>` | `320k` | bitrate for lossy formats |
| `--codec copy` | (re-encode) | stream-copy instead — keeps source format, fast, cuts on nearest frame |
| `--jobs <n>` | `4` | parallel ffmpeg jobs |
| `--limit <n>` | all | only the first n songs (test runs) |
| `--dry-run` | off | write sidecars + m3u8 + manifest, skip the audio |
| `--overwrite` | off | re-burn audio even if the output file already exists |

## How it works (segmentation)

`pointer.startMs`/`endMs` are **absolute offsets into the raw rip** (an album side is one
file containing several tracks). The burn is just an accurate seek + trim:

```
ffmpeg -ss <start>s -t <duration>s -i <source rip> -map 0:a:0 -vn \
       -c:a libmp3lame -b:a 320k -metadata title=... <out>.mp3
```

Re-encoding (the default) gives sample-accurate cut points; `--codec copy` is faster but
cuts on the nearest frame and keeps the source container. ID3 tags (title/artist/album/
track/date/genre + a BPM·key·sentiment comment) are written so the files self-describe on
a device; DJ software still does its own analysis.

## Notes

- **Burned audio is large and host-local — never commit it.** The `.gitignore` ignores
  `/burned-setlists/` and the per-run folder; add new output dirs there if you change `--out`.
- The job is idempotent: existing audio files are skipped unless `--overwrite`. Sidecars,
  the m3u8, and the manifest are always (re)written, so a `--dry-run` first is a cheap way
  to preview coverage and catch any songs missing a rip or timestamps before encoding.
- Rows whose Song ID isn't in the index, or whose song has no rip/timestamps, are reported
  and skipped (listed under `skippedSongs` in the manifest) rather than failing the run.
