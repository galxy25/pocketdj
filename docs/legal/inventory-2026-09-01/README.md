# Pre-deletion inventory snapshot — 2026-09-01

Taken per `docs/legal/legal-posture-conformance.md` MUST-0c, six weeks after the audit
(2026-07-20) because MUST-0 was not executed at the time. Versioning is off on the source
buckets, so this snapshot is the only record of state prior to any MUST-1/6 deletion.

## Contents

- `manifest.json` — verbatim copy of `s3://pocketdj-rips-011183829623/rips/manifest.json`
  (5,584 entries) as of this snapshot.
- `rips-bucket-listing.json` — full `s3api list-objects-v2` dump (key/size/etag/last-modified)
  of every object in `pocketdj-rips-011183829623` (45,124 objects: mp3s, waveforms, stems,
  derived assets).
- `pocketdj-dev-web-011183829623-lyrics-listing.json` / `-art-listing.json` — same dump for the
  `/lyrics/` and `/art/` prefixes of the dev web bucket (9,945 lyrics / 1,187 art objects).
- `pocketdj-prod-web-011183829623-lyrics-listing.json` / `-art-listing.json` — same for prod
  (6,256 lyrics / 1,160 art objects).
- `join-analysis.json` — best-effort join identifying which `manifest.json` entries are Apple
  Music captures, computed by intersecting manifest keys (filtered to `source:"digital"`)
  against the song-id sets in `public/apple-music-index.json` ("Apple Music (Local)") and
  `public/digital-index.json` ("My Digital").

## Headline numbers vs. the audit (2026-07-20 → 2026-09-01, six weeks)

| Metric | Audit (07-20) | This snapshot (09-01) |
|---|---|---|
| Apple Music (Local) captures in `rips/manifest.json` | 277 | **4,127** |
| `amrec_` ad-hoc catalog captures | 4 | **49** |
| Tier-3 estimate (the two rows above, summed) | 281 | **4,176** |
| Lyrics objects (dev + prod web buckets) | 9,945 + 6,256 = 16,201 | 9,945 + 6,256 = 16,201 (unchanged) |
| Re-hosted art objects (prod web bucket) | 1,160 | 1,160 (unchanged) |

**The Apple Music capture count grew roughly 15x since the audit, while the lyrics/art
surfaces the audit also flagged did not move at all.** That pattern — flat everywhere the audit
found a static publishing bug, sharply up only where the audit found an *active, reachable
capture path* — is consistent with the capture path having stayed live and in continued use
after the audit was written, not with a one-time miscount. This snapshot does not establish
*why* the count grew (a backfill campaign vs. organic use vs. something else); that is a
question for whoever reviews this snapshot next, not a conclusion this file draws.

## Methodology caveats

- The `join-analysis.json` categorization is new work product from this snapshot session, not
  a rerun of whatever method the original audit used (no committed script for that join was
  found in the repo). The two numbers It should be treated as **best-effort**, not verified
  against the audit's original methodology.
- The audit's full 369-object figure also included 88 songs affected by the retired "Rip from
  cloud source" (`preferCloud`) toggle. That subset isn't recoverable from the static index
  dumps used here and is not recomputed in this snapshot.
- `uncategorizedDigital_count` (220 objects) are `source:"digital"` manifest entries whose id
  matched neither index file's song-id set — not yet attributed to a source.

## Off-machine copy

A copy of this directory was also uploaded to `s3://pocketdj-logs-011183829623/inventory-2026-09-01/`
(private bucket, Public Access Block enabled) as the off-machine copy the audit calls for.
