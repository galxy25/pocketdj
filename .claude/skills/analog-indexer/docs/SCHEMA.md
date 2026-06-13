# Index schema — fields & provenance

Canonical JSON Schema: `../schema/index.schema.json`. App-side types:
`src/types/index-json.ts`. Loader rules: `LOADER_CONTRACT.md`.

## Album item

| Field | Type | Source |
| --- | --- | --- |
| `id` | `alb_<12hex>` | `sha1(normArtist|normAlbum|dupIndex)` (stable, idempotent) |
| `artist`, `name` | string | iTunes (or web fallback) |
| `coverArt` | url | iTunes `artworkUrl100` → `600x600bb` (app caches the blob) |
| `genre` | string | iTunes `primaryGenreName` |
| `year` | int | iTunes `releaseDate` |
| `country` | string | MusicBrainz artist area (best-effort) |
| `trackList` | `sng_*[]` | ordered song refs |
| `fileType` | mp3/aiff/m4a | filename |
| `pointer` | `{fileLocation, originalFilename}` | filename |
| `enrichment` | `{status, matchConfidence, itunesCollectionId, score, sources}` | match audit |

## Song item

| Field | Type | Source |
| --- | --- | --- |
| `id` | `sng_<12hex>` | `sha1(albumId|disc|track)` |
| `albumId` | `alb_*` | ref |
| `artist`, `name` | string | iTunes track (or web) |
| `trackNumber`, `year` | int | iTunes track |
| `length` | int (ms) | iTunes `trackTimeMillis` |
| `explicit` | bool | iTunes `trackExplicitness` |
| `lyrics` | string\|null | lyrics.ovh (often null) |
| `lyricsStatus` | found/notfound/error | — |
| `sentimentKeywords` | string[] | **Haiku** |
| `sentimentSource` | lyrics/inferred/failed | — |
| `bpm`, `key` | null | **DEFERRED** (needs audio) |
| `pointer.timestamps` | null | **DEFERRED** (needs audio split) |
| `pointer` | `{fileLocation, filename, disc, track, timestamps}` | filename + iTunes |

## Manifest

`{ source, generatedAt, schemaVersion, sourceType:"analog", sourceName, counts{…},
deferredFields:["song.bpm","song.key","song.pointer.timestamps"], batches{size,count,completed} }`
