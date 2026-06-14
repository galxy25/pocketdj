// Claude/Haiku SENTIMENT-UPGRADE workflow — Opus orchestrates, Haiku does per-song
// sentiment analysis from real lyrics. Use this to upgrade `inferred` sentiment to
// `lyrics`-sourced for songs that already have lyrics (a quality pass), or for any
// fresh sentiment over lyric-bearing songs.
//
// Pipeline:
//   1. node lib/extract-sentiment-targets.mjs --index <index.json> --dir /tmp/sent-upgrade
//      -> shards candidates into /tmp/sent-upgrade/batches/batch-NNN.json (lyrics on DISK,
//         not in workflow args/return)
//   2. Workflow({ scriptPath: this file, args: { numBatches: <b>, dir: "/tmp/sent-upgrade" } })
//      -> N Haiku agents each read one batch and WRITE /tmp/sent-upgrade/out/out-NNN.jsonl
//   3. node lib/apply-sentiment-upgrade.mjs --index <index.json> --dir /tmp/sent-upgrade
//      -> folds {songId, keywords, source} back into the index in place (idempotent)
//
// Why Haiku + disk batches: lyrics can be long, and Claude handles long lyrics well
// (do NOT size-cap the Claude path). Reading/writing batch files on disk keeps the large
// text off the args/return channels, so the orchestration payload stays tiny.
export const meta = {
  name: 'sentiment-upgrade',
  description: 'Upgrade inferred->lyrics-sourced sentiment for lyric-bearing songs via Haiku per-song analysis (Opus orchestrates)',
  phases: [
    { title: 'Analyze', detail: 'Each Haiku agent reads a batch of lyric-bearing songs and writes per-song sentiment keywords', model: 'haiku' },
  ],
}

// args may arrive as an object OR a JSON string — parse defensively.
const A = typeof args === 'string' ? (() => { try { return JSON.parse(args) } catch { return {} } })() : (args || {})
const N = Number(A.numBatches) || 0
const DIR = A.dir || '/tmp/sent-upgrade'
if (!N) {
  log('sentiment-upgrade: numBatches is 0 — run lib/extract-sentiment-targets.mjs first, then pass {numBatches, dir}.')
  return { batchesReturned: 0, numBatches: 0, totalWritten: 0, perBatch: [] }
}

phase('Analyze')
const SUMMARY = {
  type: 'object',
  properties: {
    batch: { type: 'integer' },
    written: { type: 'integer', description: 'number of JSONL lines written to the out file' },
    note: { type: 'string', description: 'optional short note (e.g. any songs that failed)' },
  },
  required: ['batch', 'written'],
  additionalProperties: false,
}

const tasks = []
for (let i = 0; i < N; i++) {
  const id = String(i).padStart(3, '0')
  const prompt = [
    `You are a precise music sentiment analyst. Read the JSON file ${DIR}/batches/batch-${id}.json with the Read tool — it is an array of songs, each {songId, artist, title, genre, year, lyrics}.`,
    ``,
    `For EACH song, produce 3 to 7 lowercase mood/theme keywords (1-2 words each, evocative — moods, themes, imagery, vibe).`,
    `- If the lyrics field contains REAL song lyrics (even long or lightly duplicated ones — read the whole thing), derive the keywords FROM THE LYRICS and set "source" to "lyrics".`,
    `- Only if the lyrics are an instrumental marker (e.g. "[Instrumental]"), empty, or clearly a scrape artifact / not actual lyrics for THIS song, INFER keywords from the title/artist/genre/era and set "source" to "inferred".`,
    ``,
    `Write the results to ${DIR}/out/out-${id}.jsonl using the Write tool — ONE compact JSON object PER LINE, exactly this shape:`,
    `{"songId":"<echoed EXACTLY from input>","keywords":["kw1","kw2","kw3"],"source":"lyrics"}`,
    `One line per input song; do not skip any song; echo each songId exactly. Overwrite the file if it already exists. Do not wrap the file in an array or markdown — raw JSONL only.`,
    ``,
    `Then return {batch: ${i}, written: <number of lines you wrote>}.`,
  ].join('\n')
  tasks.push(() => agent(prompt, { label: `haiku-sentiment:${id}`, phase: 'Analyze', model: 'haiku', schema: SUMMARY }))
}

const res = (await parallel(tasks)).filter(Boolean)
const totalWritten = res.reduce((s, r) => s + (r.written || 0), 0)
log(`sentiment-upgrade: ${res.length}/${N} batches returned, ${totalWritten} songs written -> ${DIR}/out/`)
return { batchesReturned: res.length, numBatches: N, totalWritten, perBatch: res.map((r) => ({ batch: r.batch, written: r.written, note: r.note })) }
