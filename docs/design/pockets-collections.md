# Pockets × collections: shared spec (Levi's request, 2026-10-13)

Levi's words: "pocket detection, analysis and recommendation should take into account collection membership and collection
membership vector (e.g. playing a song that is similar to other songs in a playlist increases the probability that those
collection songs or similar ones will be considered for pocket recommendation to match the vibe), re-using the history data
of when a song is added to a collection for that feature set and for the collection recommendations data set."

## Concepts
- **Membership vector m(s)**: for song s, a sparse map collectionId → weight.
  - Hard membership = 1.0 (song is directly in the collection, incl. via an album node or a child pocket, flattened).
    Membership is **CURRENT and retroactive** (Levi, 2026-10-13): a song's hard memberships are its memberships in the
    LATEST snapshot, for every play old or new. Adding a song to a playlist today re-labels the older pockets it played
    in (their `membership` and `collection` features) on the next compute; a removal stops counting the same way. A
    snapshot upload that changes anything marks the profile dirty and kicks a compute, so this happens right away, not
    only nightly.
  - **Soft membership** (the "similar to other songs in a playlist" part): for a song NOT in collection c, weight =
    `SOFT_MAX (0.6) × sim(s, centroid(c))` when sim ≥ SOFT_MIN (0.55), else 0. `sim` blends what we already have per song in
    rec-features: genre share in c, BPM gaussian vs c's median (fold 80–160), Camelot neighbour fraction, timbre-profile fit
    (reuse the rec-engine's `timbreProfile`/`timbreFit` math — copy, don't import across lambdas), mood Jaccard. Weights live in
    params so they're tunable. Collections with < 3 resolvable members get no centroid (hard membership only).
  - **Add-time recency**: hard weight is scaled by `0.5 + 0.5·exp(-ageDays/ADD_HALF_LIFE_DAYS (45))` with
    `ageDays = max(0, (now − addAt) / 1 day)` measured from the ANALYSIS time (never the play time), i.e. a song that was
    freshly added to a playlist expresses that playlist more strongly. Unknown add time → 0.75.
- **Pocket membership vector M(P)** = mean of m(s) over the pocket's non-skipped members (L1-normalised top 12 kept).
- **Add sessions**: songs added to any collection within 30 min of each other by the same install form an add session;
  co-added pairs are an affinity signal ("the user thought these went together").

## Upload contract: app → listening-pockets `POST /pockets/events` (upload.v1, additive, all optional)
```jsonc
{
  "v": 1, "deviceId": "…", "installId": "…", "sentAtMs": 0, "events": [ /* existing */ ],
  // per event, NEW optional:
  //   "contextId":   "<opaque collection id the play started from>",   (PlayEvent.contextId; omit when nil)
  //   "contextKind": "pocket" | "playlist" | "setlist" | "source",
  "collections": [            // NEW optional membership snapshot; send when its content hash changed or ≥ 24 h since last send
    {
      "id": "<opaque collection id>",          // same ids as contextId; NEVER names
      "kind": "pocket" | "playlist" | "source",
      "songIds": ["…"],                        // flattened effective song membership (albums expanded, child pockets flattened, dedup)
      "adds": [ { "songId": "…", "atMs": 0 } ] // when each CURRENT member was last added (from CollectionActivityStore add
                                               // events, latest add not followed by a remove; album/child-pocket adds credit
                                               // their expanded songs with the album/pocket add time). Omit unknowns.
    }
  ],
  "addEvents": [               // NEW optional: song-level add history (last 365 d, cap 5000, newest first) for add sessions
    { "songId": "…", "collectionId": "…", "atMs": 0, "kind": "add" | "remove" }
  ]
}
```
Caps (mirror rec-engine cleanSnapshot): ≤ 500 collections, ≤ 5000 songs each, ≤ 100k songs total. The server must accept
uploads without these fields (old clients) and must not break on unknown fields.

## Results contract: `GET /pockets/results` additions (all optional; old clients ignore)
- Each pocket: `membership: [{ "collectionId", "weight" }]` (M(P), top 12, desc), and the `collection` / `playContext`
  categorical dims can appear in `features[]` like any other dim (dim names exactly `collection` and `playContext`).
- Each pattern: `membership` (mean of its pockets' M, top 12) and
  `collectionCandidates: [{ "songId", "score", "via": ["collectionId"…] }]` (≤ 40): songs that are hard members of the
  pattern's top collections (weighted by the pattern vector), or co-added with the pattern's topSongs, that are NOT already
  in topSongs; score = cosine(m(song), pattern.membership) blended with add-session affinity and the pattern's musical
  features (reuse the analyze.mjs feature match). This is "those collection songs or similar ones considered for pocket recommendation".
- Top level: `collectionsSeen: <n>`; `algo.version` bumped.

## Rounds learning
`TARGET_DIMS` (store.mjs) and `learnFromRounds` must accept `collection` targets so game rounds re-weight collections too.
