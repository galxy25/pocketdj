# Sentiment agent prompt (reference) — Haiku

Human-readable copy of the sentiment prompt (`workflow/index-vinyl.workflow.js` →
`sentimentPrompt`). Runs on **Haiku** (`model:'haiku'`), per the project spec
("for sentiment analysis on the lyrics use haiku").

Input: songs `[{ ci, track, artist, album, title, genre, year, lyrics|null }]`.

For each song output **3–7 lowercase mood/theme keywords**:
- `lyrics` present → derive FROM the lyrics, `source:"lyrics"`.
- `lyrics` null/empty → INFER from artist/album/genre/era, `source:"inferred"`.

Keywords are short (1–2 words), evocative, no punctuation, no titles, no
explicit-content judgements. Echo `ci` and `track` exactly for matching.

Output (via StructuredOutput): `{ results: [{ ci, track, keywords, source }] }`,
matching `schema/sentiment.output.schema.json`. The workflow stitches each result
into its track by `ci|track`; misses default to `keywords:[], source:"failed"`.
