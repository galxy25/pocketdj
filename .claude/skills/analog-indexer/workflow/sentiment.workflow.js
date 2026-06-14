// PocketDJ sentiment workflow — Haiku-only. Songs are injected by
// build-sentiment.mjs (the Workflow sandbox can't read files). Each song carries
// a global ordinal `sk` so results stitch back deterministically.
//
// returns: { results: [{ sk, keywords, source }] }

export const meta = {
  name: 'analog-sentiment',
  description: 'Derive mood/theme sentiment keywords for songs using Haiku (from lyrics, or inferred from context)',
  phases: [{ title: 'Sentiment', detail: 'Haiku keywords per song batch', model: 'haiku' }],
};

const songs = []; /* __SONGS_INJECTION__ */
const batchSize = 50; /* __BATCHSIZE_INJECTION__ */

function chunk(arr, size) {
  const out = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

const SCHEMA = {
  type: 'object',
  required: ['results'],
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object',
        required: ['sk', 'keywords', 'source'],
        properties: {
          sk: { type: 'integer' },
          keywords: { type: 'array', items: { type: 'string' } },
          source: { enum: ['lyrics', 'inferred'] },
        },
      },
    },
  },
};

function prompt(batch) {
  return [
    'You are a lyrics SENTIMENT analyst for PocketDJ. For each song output 3 to 7 lowercase mood/theme keywords capturing its emotional tone.',
    '- If `lyrics` is present and non-empty: derive keywords FROM the lyrics; source="lyrics".',
    '- If `lyrics` is null/empty: INFER from artist/album/genre/era; source="inferred".',
    'Short keywords (1-2 words), evocative, no punctuation, no titles, no explicit-content judgements.',
    'Echo back each `sk` exactly. Return ONLY via StructuredOutput.',
    '',
    'SONGS:',
    JSON.stringify(batch),
  ].join('\n');
}

log(`sentiment for ${songs.length} songs in ${Math.ceil(songs.length / batchSize)} Haiku batches`);

const batches = chunk(songs, batchSize);
const out = await parallel(
  batches.map((batch, bi) => async () => {
    const r = await agent(prompt(batch), { label: `sentiment:b${bi}`, phase: 'Sentiment', model: 'haiku', schema: SCHEMA });
    return (r && r.results) || [];
  }),
);

const results = out.filter(Boolean).flat();
log(`got ${results.length}/${songs.length} sentiment results`);
return { results };
