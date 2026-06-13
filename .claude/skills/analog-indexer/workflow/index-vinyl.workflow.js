// PocketDJ analog indexer — enrichment workflow (self-contained; no imports,
// the Workflow sandbox can't read the filesystem). The deterministic parse/merge
// steps run in the main loop via lib/cli.mjs; THIS script only fans out the
// networked enrichment + Haiku sentiment.
//
// args: {
//   candidates: Candidate[],     // from `cli.mjs parse` (each has spacedBlob, artistGuess, …)
//   batchSize?: number,          // default 10  -> ceil(N/10) batches, 2 agents each
//   completedBatches?: number[]  // batch indices already written to disk (resume)
// }
// returns: { batches: Shard[], count, batchCount } where Shard = { batchIndex, albums: EnrichedAlbum[] }

export const meta = {
  name: 'analog-indexer',
  description: 'Enrich parsed vinyl candidates into a PocketDJ music index (iTunes + web/Wikipedia fallback, MusicBrainz country, lyrics.ovh, Haiku sentiment)',
  phases: [
    { title: 'Enrich', detail: 'iTunes match + lookup; web/Wikipedia fallback; MusicBrainz country; lyrics' },
    { title: 'Sentiment', detail: 'Haiku sentiment keywords per song', model: 'haiku' },
  ],
};

const candidates = (args && args.candidates) || []; /* __CANDIDATES_INJECTION__ */
const batchSize = (args && args.batchSize) || 10; /* __BATCHSIZE_INJECTION__ */
const completed = new Set((args && args.completedBatches) || []); /* __COMPLETED_INJECTION__ */

function chunk(arr, size) {
  const out = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

// Tag each candidate with its global index, then split into batches.
const indexed = candidates.map((c, i) => ({ ...c, candidateIndex: i }));
const batches = chunk(indexed, batchSize).map((items, bi) => ({ bi, items }));

log(`indexing ${candidates.length} albums in ${batches.length} batches of ${batchSize} (${batches.length * 2} agent calls)`);

// ---- Agent output schemas (mirrors of schema/*.output.schema.json) ----
const ENRICH_SCHEMA = {
  type: 'object',
  required: ['albums'],
  properties: {
    albums: {
      type: 'array',
      items: {
        type: 'object',
        required: ['candidateIndex', 'status', 'artist', 'name', 'tracks', 'sources'],
        properties: {
          candidateIndex: { type: 'integer' },
          status: { enum: ['matched', 'unmatched'] },
          matchConfidence: { enum: ['strong', 'weak'] },
          score: { type: 'number' },
          itunesCollectionId: { type: 'integer' },
          sources: { type: 'array', items: { type: 'string' } },
          artist: { type: 'string' },
          name: { type: 'string' },
          coverArt: { type: 'string' },
          genre: { type: 'string' },
          year: { type: 'integer' },
          country: { type: 'string' },
          tracks: {
            type: 'array',
            items: {
              type: 'object',
              required: ['trackNumber', 'name'],
              properties: {
                discNumber: { type: 'integer' },
                trackNumber: { type: 'integer' },
                name: { type: 'string' },
                artist: { type: 'string' },
                year: { type: 'integer' },
                lengthMs: { type: 'integer' },
                explicit: { type: 'boolean' },
                lyrics: { type: ['string', 'null'] },
                lyricsStatus: { enum: ['found', 'notfound', 'error'] },
              },
            },
          },
        },
      },
    },
  },
};

const SENT_SCHEMA = {
  type: 'object',
  required: ['results'],
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object',
        required: ['ci', 'track', 'keywords', 'source'],
        properties: {
          ci: { type: 'integer' },
          track: { type: 'integer' },
          keywords: { type: 'array', items: { type: 'string' } },
          source: { enum: ['lyrics', 'inferred'] },
        },
      },
    },
  },
};

function enrichPrompt(batch) {
  const slim = batch.items.map((c) => ({
    candidateIndex: c.candidateIndex,
    lookup: c.spacedBlob, // NEVER contains "Raw"
    artistGuess: c.artistGuess,
    albumGuess: c.albumGuess,
    altSplits: c.altSplits,
    dupIndex: c.dupIndex,
  }));
  return [
    'You are a music metadata enrichment worker for PocketDJ. Enrich each vinyl album candidate below into structured metadata. Return ONLY data via the StructuredOutput tool — no prose.',
    '',
    'For EACH candidate (keyed by candidateIndex), use its `lookup` string as the search term. The `lookup` is "Artist Album" with the recording marker already removed — never add the word "Raw".',
    '',
    'PIPELINE per album:',
    '1) iTunes album search (keyless):',
    '   GET https://itunes.apple.com/search?term=<URL-encoded lookup>&entity=album&limit=8&country=US',
    '   Choose the BEST matching album by comparing the combined "artistName collectionName" to the lookup. Rules:',
    '   - Compilations are EXPECTED ("Greatest Hits", "Best Of", "Anthology") — do NOT reject them.',
    '   - Ignore a leading "The", apostrophes, and treat "&" == "and".',
    '   - If a confident match: status="matched", matchConfidence="strong", set itunesCollectionId, score 0..1.',
    '   - If plausible but unsure: status="matched", matchConfidence="weak".',
    '   - If nothing fits (score < ~0.45): status="unmatched" (see fallback in step 4).',
    '2) iTunes lookup for the matched album tracklist:',
    '   GET https://itunes.apple.com/lookup?id=<collectionId>&entity=song&country=US',
    '   Map album: artist=artistName, name=collectionName, genre=primaryGenreName, year=year(releaseDate),',
    '   coverArt = artworkUrl100 with "/100x100bb." replaced by "/600x600bb.".',
    '   Map each track: trackNumber, discNumber, name=trackName, lengthMs=trackTimeMillis,',
    '   explicit = (trackExplicitness === "explicit"), year=year(track releaseDate).',
    '3) Country (best-effort, optional): GET https://musicbrainz.org/ws/2/artist/?query=artist:<artist>&fmt=json&limit=1',
    '   with header User-Agent: "PocketDJ-Indexer/1.0 (levismschoen@gmail.com)". Use area/country. Make at most ONE MusicBrainz call per album and skip silently on any error/rate-limit.',
    '4) FALLBACK when iTunes did NOT match (status="unmatched") OR returned no tracks:',
    '   Use a plain web search / Wikipedia to find the album tracklist + year + genre.',
    '   Search e.g. "<artist> <album> album wikipedia tracklist"; fetch the Wikipedia page and read the track listing.',
    '   Fill tracks (trackNumber + name at minimum; lengthMs if shown). Add "wikipedia" or "web" to sources.',
    '   If you find the album this way, you may set status="matched", matchConfidence="weak".',
    '   If truly nothing is found, return status="unmatched" with tracks: [] and artist/name from the guess.',
    '5) Lyrics per track (best-effort, SINGLE attempt each):',
    '   GET https://api.lyrics.ovh/v1/<artist>/<title>. On 200 with non-empty "lyrics": set lyrics (trim to ~1500 chars), lyricsStatus="found". On 404/empty/error: lyrics=null, lyricsStatus="notfound". Do NOT retry.',
    '6) Do NOT fill bpm or key (deferred — need the audio file).',
    '',
    'Always include every candidate in your output (one album object per candidateIndex). Put the data sources you actually used in `sources` (e.g. ["itunes","musicbrainz","lyrics.ovh"]).',
    '',
    'CANDIDATES:',
    JSON.stringify(slim),
  ].join('\n');
}

function sentimentPrompt(songs) {
  return [
    'You are a lyrics SENTIMENT analyst for PocketDJ. For each song, output 3 to 7 lowercase mood/theme keywords capturing its emotional tone.',
    '- If `lyrics` is present and non-empty: derive keywords FROM the lyrics; set source="lyrics".',
    '- If `lyrics` is null/empty: INFER keywords from the artist, album, genre, and era; set source="inferred".',
    'Keep keywords short (1-2 words), evocative, no punctuation, no song titles, no explicit-content judgements.',
    'Echo back ci (candidateIndex) and track (trackNumber) exactly so results can be matched. Return ONLY via StructuredOutput.',
    '',
    'SONGS:',
    JSON.stringify(songs),
  ].join('\n');
}

// ---- Pipeline: enrich -> sentiment, per batch (no barrier; each batch flows independently) ----
const results = await pipeline(
  batches,
  // Stage 1: enrichment
  async (batch) => {
    if (completed.has(batch.bi)) return null; // already written to disk on a prior run
    const out = await agent(enrichPrompt(batch), {
      label: `enrich:b${batch.bi}`,
      phase: 'Enrich',
      schema: ENRICH_SCHEMA,
    });
    const byCi = new Map(batch.items.map((c) => [c.candidateIndex, c]));
    const albums = ((out && out.albums) || []).map((a) => {
      const c = byCi.get(a.candidateIndex) || {};
      return {
        ...a,
        originalFilename: c.originalFilename,
        fileLocation: c.fileLocation,
        fileType: c.fileType,
        dupIndex: c.dupIndex ?? null,
      };
    });
    return { bi: batch.bi, albums };
  },
  // Stage 2: Haiku sentiment
  async (enriched) => {
    if (!enriched) return null;
    const songs = [];
    for (const a of enriched.albums) {
      for (const t of a.tracks || []) {
        songs.push({
          ci: a.candidateIndex,
          track: t.trackNumber,
          artist: t.artist || a.artist,
          album: a.name,
          title: t.name,
          genre: a.genre,
          year: t.year || a.year,
          lyrics: t.lyrics || null,
        });
      }
    }
    if (songs.length > 0) {
      const sent = await agent(sentimentPrompt(songs), {
        label: `sentiment:b${enriched.bi}`,
        phase: 'Sentiment',
        model: 'haiku',
        schema: SENT_SCHEMA,
      });
      const map = new Map();
      for (const r of (sent && sent.results) || []) map.set(`${r.ci}|${r.track}`, r);
      for (const a of enriched.albums) {
        for (const t of a.tracks || []) {
          const r = map.get(`${a.candidateIndex}|${t.trackNumber}`);
          if (r) {
            t.sentimentKeywords = r.keywords;
            t.sentimentSource = r.source;
          } else {
            t.sentimentKeywords = [];
            t.sentimentSource = 'failed';
          }
        }
      }
    }
    return { batchIndex: enriched.bi, albums: enriched.albums };
  },
);

const shards = results.filter(Boolean);
log(`enriched ${shards.length}/${batches.length} batches`);
return { batches: shards, count: shards.length, batchCount: batches.length };
