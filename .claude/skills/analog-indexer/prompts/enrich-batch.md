# Enrich-batch agent prompt (reference)

This is a human-readable copy of the enrichment prompt the workflow builds at
runtime (`workflow/index-vinyl.workflow.js` → `enrichPrompt`). Keep in sync.

The agent receives a batch of candidates `[{ candidateIndex, lookup, artistGuess,
albumGuess, altSplits, dupIndex }]` where `lookup` is `"Artist Album"` with the
`Raw` marker already removed.

Per album:
1. **iTunes search** `GET https://itunes.apple.com/search?term=<enc(lookup)>&entity=album&limit=8&country=US`.
   Pick the best album by comparing combined `artistName collectionName` to `lookup`.
   - Compilations ("Greatest Hits", "Best Of", "Anthology") are expected — don't reject.
   - Ignore leading "The", apostrophes; treat `&` == `and`.
   - Confident → `status:"matched", matchConfidence:"strong"`, set `itunesCollectionId`, `score`.
   - Plausible → `matchConfidence:"weak"`. Nothing fits → `status:"unmatched"` (see 4).
2. **iTunes lookup** `GET https://itunes.apple.com/lookup?id=<collectionId>&entity=song&country=US`.
   Album: artist, name, genre=`primaryGenreName`, year from `releaseDate`,
   coverArt = `artworkUrl100` with `/100x100bb.` → `/600x600bb.`.
   Track: trackNumber, discNumber, name=`trackName`, lengthMs=`trackTimeMillis`,
   explicit=`trackExplicitness==="explicit"`, year from track `releaseDate`.
3. **MusicBrainz** (optional, ≤1 call/album, User-Agent required) for Country; skip on error.
4. **Web/Wikipedia FALLBACK** when iTunes misses or has no tracks — search
   `"<artist> <album> album wikipedia tracklist"`, read the track listing, fill tracks,
   add `wikipedia`/`web` to `sources`. May upgrade to `matched`/`weak`. Else `unmatched`, `tracks:[]`.
5. **lyrics.ovh** per track `GET https://api.lyrics.ovh/v1/<artist>/<title>` — single attempt;
   200 → `lyrics` (≤1500 chars), `lyricsStatus:"found"`; else `null`, `"notfound"`.
6. **Never** fill `bpm`/`key` (deferred). **Never** emit the word "Raw".

Output (via StructuredOutput): `{ albums: [...] }` — one album per `candidateIndex`,
matching `schema/enrich-batch.output.schema.json`.
