# PocketDJ Index — Loader Contract

This is the **fixed interface** between the `analog-indexer` skill (producer) and
the PocketDJ app (consumer). The indexer writes `index-out/index.json`; the app
imports it via `src/storage/importIndex.ts`. The mock generator
(`scripts/generate-mock-index.ts`) emits the *same* shape so real and mock data
are interchangeable.

Authoritative types: `src/types/index-json.ts`.
Authoritative schema: `.claude/skills/analog-indexer/schema/index.schema.json`.

## Top-level shape

```jsonc
{
  "manifest": { … },   // counts, schemaVersion, deferred fields
  "albums":   [ … ],   // flat array, ids prefixed "alb_"
  "songs":    [ … ]    // flat array, ids prefixed "sng_"
}
```

Albums and songs are **flat arrays** (not nested), so the app can build
`Map<id>` lookups and virtualize large lists. Refs wire them together:
`album.trackList` is an ordered array of `song.id`; `song.albumId` points back.

## Rules the loader MUST follow

1. **Version gate.** Assert `manifest.schemaVersion`'s MAJOR equals the app's
   `INDEX_SCHEMA_MAJOR` (currently `1`). Reject mismatched majors.
2. **Build id maps.** Index songs by `id`; resolve `album.trackList[]` → song
   records through the map. Do not assume array order equals track order — use
   `trackList` (and `song.trackNumber` within it).
3. **Stable ids.** `alb_*`/`sng_*` ids are content-derived and stable across
   re-runs. The loader reuses them as the in-app item `id`, so re-importing an
   updated index upserts in place (idempotent).
4. **Deferred = null, not missing.** `song.bpm`, `song.key`, and
   `song.pointer.timestamps` are always `null` this iteration ("pending audio
   analysis"). They are listed in `manifest.deferredFields`. The loader/UI must
   treat `null` here as *pending*, never as *absent data to hide*.
5. **Cover art is a URL to cache.** `album.coverArt` is a cacheable image URL
   (typically iTunes `…/600x600bb.jpg`). The app downloads it into an IndexedDB
   blob (`artCache`) for offline use; it may be absent (→ placeholder star).
6. **Length is milliseconds.** `song.length` is an integer in ms. Format to
   mm:ss only for display.
7. **Lyrics may be absent.** `song.lyrics` may be `null`; `song.lyricsStatus`
   says why. `song.sentimentKeywords` is still populated (Haiku infers from
   context when lyrics are missing), with `song.sentimentSource` =
   `"lyrics" | "inferred" | "failed"`.
8. **Unmatched albums.** An album with `enrichment.status == "unmatched"` may
   have an empty `trackList` (no songs found). The app must render it (from the
   parser-derived artist/name) and let the user fill metadata manually.

## Field provenance (where each datum comes from)

| App field | Source |
| --- | --- |
| album.artist / name / genre / year / coverArt | iTunes Search + Lookup |
| album.country | MusicBrainz (artist area); may be absent |
| album.fileType / pointer.originalFilename | filename parser |
| song.name / trackNumber / length / explicit | iTunes Lookup (per track) |
| song.lyrics | lyrics.ovh (best-effort; often absent) |
| song.sentimentKeywords / sentimentSource | Haiku |
| song.bpm / key / pointer.timestamps | DEFERRED (needs the audio file) |

## Mapping to the internal model

`importIndex.ts` maps this shape onto `src/types/model.ts`:
`IndexAlbum → AlbumItem` (`coverArt → coverArtUrl`, `trackList → trackIds`),
`IndexSong → SongItem` (`length → lengthMs`, `albumId → albumId`), assigning the
owning `sourceId` and `createdAt/updatedAt` at import time.
