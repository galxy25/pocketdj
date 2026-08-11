#!/usr/bin/env node
// The REPORT driver for scripts/measure-rec-concentration.mjs — reproduces the owner's
// "every tile is Drake" symptom, attributes it, quantifies how much of final rank order play count
// explains, and (section 9) measures the shipped novelty rebalance BEFORE vs AFTER off the same
// harness. See that file's header for the surfaces.
//
//   node scripts/measure-rec-report.mjs [--collections 40] [--all] [--json out.json]
//
//   --all   section 9 runs over EVERY suggestible collection (131) rather than the 40-tile
//           sample. Slower, and it is the population `Tuning.suggestionAuxGain` was calibrated
//           on — the sample in sections 1–8 deliberately skews to the LARGEST playlists, and
//           collection size moves the answer.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  songs, byId, playCount, lastPlayed, suggestions, inDaZone, allPlaylists,
  artistStats, spearman, pearson, jaccard, NOW, N, pc, mean, pctl, recencyScore, artistKey,
  primaryArtistKey, TUNING_BEFORE, TUNING_AFTER,
} from './measure-rec-concentration.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : d; };
const K = Number(arg('--collections', 40));
const JSON_OUT = arg('--json', null);
const DAY = 86_400_000;
const out = {};
const f2 = (x) => x.toFixed(2);
const pctS = (x) => `${(100 * x).toFixed(1)}%`;

// ══════════════════════════════════════════════════════════════════════════════════════════
console.log('════ 0. THE LIBRARY THIS IS MEASURED ON ══════════════════════════════════════');
const played = [...playCount.values()];
const totalPlays = played.reduce((a, b) => a + b, 0);
const artistPlays = new Map(); const artistSongs = new Map();
for (const s of songs) {
  artistSongs.set(s.artist, (artistSongs.get(s.artist) || 0) + 1);
  const n = pc(s.id);
  if (n > 0) artistPlays.set(s.artist, (artistPlays.get(s.artist) || 0) + n);
}
const topArtistsByPlays = [...artistPlays.entries()].sort((a, b) => b[1] - a[1]);
const topArtistsBySongs = [...artistSongs.entries()].sort((a, b) => b[1] - a[1]);
const artistPlayVals = [...artistPlays.values()].sort((a, b) => a - b);
console.log(`  catalog ${N.toLocaleString()} songs · ${playCount.size.toLocaleString()} with a play count `
  + `(${pctS(playCount.size / N)}) · ${totalPlays.toLocaleString()} lifetime plays`);
console.log(`  never played: ${(N - playCount.size).toLocaleString()} (${pctS(1 - playCount.size / N)})`);
const ages = [...lastPlayed.values()].map((ms) => (NOW - ms) / DAY).sort((a, b) => a - b);
console.log(`  last-played age days: p10 ${pctl(ages, 0.10).toFixed(0)}  median ${pctl(ages, 0.5).toFixed(0)} `
  + `(${(pctl(ages, 0.5) / 365).toFixed(1)} y)  p90 ${pctl(ages, 0.90).toFixed(0)}`);
console.log(`  top artists BY PLAYS:  ${topArtistsByPlays.slice(0, 6).map(([a, n]) => `${a} ${n}`).join(' · ')}`);
console.log(`  median artist plays ${artistPlayVals[Math.floor(artistPlayVals.length / 2)]} `
  + `over ${artistPlays.size.toLocaleString()} artists with any play`);
console.log(`  top artists BY CATALOG SIZE: ${topArtistsBySongs.slice(0, 6).map(([a, n]) => `${a} ${n}`).join(' · ')}`);
const DRAKE = 'Drake';
console.log(`  ${DRAKE}: ${artistSongs.get(DRAKE) || 0} songs owned (${pctS((artistSongs.get(DRAKE) || 0) / N)} of catalog), `
  + `${artistPlays.get(DRAKE) || 0} plays (${pctS((artistPlays.get(DRAKE) || 0) / totalPlays)} of all plays), `
  + `rank #${topArtistsByPlays.findIndex(([a]) => a === DRAKE) + 1} by plays / `
  + `#${topArtistsBySongs.findIndex(([a]) => a === DRAKE) + 1} by song count`);
out.library = {
  songs: N, withPlayCount: playCount.size, totalPlays,
  neverPlayedShare: 1 - playCount.size / N,
  medianLastPlayedDays: pctl(ages, 0.5),
  topArtistsByPlays: topArtistsByPlays.slice(0, 15),
  topArtistsBySongs: topArtistsBySongs.slice(0, 15),
  drake: { songs: artistSongs.get(DRAKE) || 0, plays: artistPlays.get(DRAKE) || 0 },
};

// ══════════════════════════════════════════════════════════════════════════════════════════
console.log('\n════ 1. COLLECTION TILES TODAY (ZoneEngine.suggestions, limit 25, cap 3) ═════');
// A representative set: the biggest real playlists that are not the whole-library dumps, plus a
// spread of mid-size ones. Deterministic (sorted, then strided) so the report reproduces.
const usable = allPlaylists.filter((p) => p.songIds.length >= 8 && p.songIds.length <= 3000)
  .sort((a, b) => b.songIds.length - a.songIds.length);
const stride = Math.max(1, Math.floor(usable.length / K));
const sample = [];
for (let i = 0; i < usable.length && sample.length < K; i += stride) sample.push(usable[i]);
console.log(`  ${sample.length} collections sampled from ${usable.length} real playlists `
  + `(sizes ${sample[sample.length - 1].songIds.length}…${sample[0].songIds.length})`);

const shipped = [];
for (const c of sample) {
  const r = suggestions(c.songIds);
  if (!r) continue;
  shipped.push({ c, r, st: artistStats(r.picks) });
}
const agg = (rows, sel) => mean(rows.map(sel));
console.log(`  distinct artists per tile: mean ${agg(shipped, (x) => x.st.distinct).toFixed(1)} of `
  + `${agg(shipped, (x) => x.st.n).toFixed(0)} rows`);
console.log(`  top artist's share of a tile: mean ${pctS(agg(shipped, (x) => x.st.topShare))} `
  + `(cap allows ${pctS(3 / 25)})`);
console.log(`  tiles where SOME artist takes the full 3 slots: `
  + `${shipped.filter((x) => x.st.topN >= 3).length}/${shipped.length}`);
console.log(`  artists holding ≥2 rows per tile: mean ${agg(shipped, (x) => x.st.atLeast2).toFixed(1)}, `
  + `≥3: mean ${agg(shipped, (x) => x.st.atLeast3).toFixed(1)}`);
// WHICH artists. The owner named Drake; the data has to name him too, or the diagnosis is wrong.
const tileAppearances = new Map(); const tileRows = new Map();
for (const x of shipped) {
  const seen = new Set();
  for (const p of x.r.picks) {
    tileRows.set(p.artist, (tileRows.get(p.artist) || 0) + 1);
    if (!seen.has(p.artist)) { seen.add(p.artist); tileAppearances.set(p.artist, (tileAppearances.get(p.artist) || 0) + 1); }
  }
}
const across = [...tileAppearances.entries()].sort((a, b) => b[1] - a[1]);
console.log('  ── ARTISTS ACROSS ALL TILES (in how many of the tiles do they appear at all) ──');
for (const [a, n] of across.slice(0, 12)) {
  console.log(`    ${String(n).padStart(3)}/${shipped.length} tiles  ${String(tileRows.get(a)).padStart(4)} rows total  ${a}`);
}
const totalRows = [...tileRows.values()].reduce((a, b) => a + b, 0);
console.log(`  total rows across tiles ${totalRows}; distinct artists ${tileRows.size}; `
  + `top-10 artists hold ${pctS([...tileRows.values()].sort((a, b) => b - a).slice(0, 10).reduce((a, b) => a + b, 0) / totalRows)} of all rows`);
// CONTROLS. "Picks are 99% played" only means something against the right base rate — the pool a
// tile draws from is not the whole catalog, and a collection's own members are already played.
const memberIds = new Set(sample.flatMap((c) => c.songIds));
const memberPlayed = [...memberIds].filter((id) => pc(id) > 0).length;
const distinctSongs = new Set(shipped.flatMap((x) => x.r.picks.map((p) => p.id)));
const top1000 = new Set([...playCount.entries()].sort((a, b) => b[1] - a[1]).slice(0, 1000).map(([id]) => id));
const inTop1000 = [...distinctSongs].filter((id) => top1000.has(id)).length;
console.log(`  CONTROL — base rates: whole catalog ${pctS(playCount.size / N)} played · `
  + `the sampled collections' own members ${pctS(memberPlayed / memberIds.size)} played · `
  + `admitted candidates ${pctS(mean(shipped.map((x) => x.r.scored.filter((c) => c.n > 0).length / x.r.scored.length)))} played`);
console.log(`  REACH — the 40 tiles show ${distinctSongs.size} distinct songs = ${pctS(distinctSongs.size / N)} of the catalog; `
  + `${inTop1000} of them (${pctS(inTop1000 / distinctSongs.size)}) are in the 1,000 most-played songs he owns`);
out.controls = { catalogPlayedShare: playCount.size / N, memberPlayedShare: memberPlayed / memberIds.size,
  candidatePlayedShare: mean(shipped.map((x) => x.r.scored.filter((c) => c.n > 0).length / x.r.scored.length)),
  distinctSongsShown: distinctSongs.size, shareOfCatalogShown: distinctSongs.size / N,
  shareOfShownInTop1000Played: inTop1000 / distinctSongs.size };
out.tilesShipped = {
  tiles: shipped.length,
  meanDistinctArtists: agg(shipped, (x) => x.st.distinct),
  meanTopShare: agg(shipped, (x) => x.st.topShare),
  tilesWithA3: shipped.filter((x) => x.st.topN >= 3).length,
  acrossTiles: across.slice(0, 20).map(([a, n]) => ({ artist: a, tiles: n, rows: tileRows.get(a) })),
  distinctArtistsAllTiles: tileRows.size, totalRows,
};

// ══════════════════════════════════════════════════════════════════════════════════════════
console.log('\n════ 2. ATTRIBUTION — ablate one cause at a time ═════════════════════════════');
// Four counterfactuals over the SAME tiles. Each isolates one candidate cause.
const VARIANTS = [
  ['shipped', {}],
  ['no play-count term (famWeight 0)', { famWeight: 0 }],
  ['no artist family (balance.artist 0)', { balance: { artist: 0, genreYear: 0.5, genreMusical: 0.5 } }],
  ['neither', { famWeight: 0, balance: { artist: 0, genreYear: 0.5, genreMusical: 0.5 } }],
  ['NO per-artist cap (shipped weights)', { maxPerArtist: Infinity }],
];
const variantRows = [];
for (const [name, opts] of VARIANTS) {
  const rs = [];
  for (const c of sample) {
    const r = suggestions(c.songIds, opts);
    if (r) rs.push({ r, st: artistStats(r.picks) });
  }
  const base = shipped.map((x) => x.r.picks.map((p) => p.id));
  const here = rs.map((x) => x.r.picks.map((p) => p.id));
  const jac = mean(base.map((b, i) => (here[i] ? jaccard(b, here[i]) : 0)));
  const rowsOf = new Map();
  for (const x of rs) for (const p of x.r.picks) rowsOf.set(p.artist, (rowsOf.get(p.artist) || 0) + 1);
  const tot = [...rowsOf.values()].reduce((a, b) => a + b, 0);
  const topArtist = [...rowsOf.entries()].sort((a, b) => b[1] - a[1])[0];
  variantRows.push({ name, meanDistinct: mean(rs.map((x) => x.st.distinct)),
    meanTopShare: mean(rs.map((x) => x.st.topShare)), jaccard: jac,
    topAcross: topArtist?.[0], topAcrossShare: topArtist ? topArtist[1] / tot : 0,
    drakeRows: rowsOf.get('Drake') || 0, totalRows: tot, distinctArtists: rowsOf.size });
}
console.log('  variant                              distinct/tile  topArtist%  ∩shipped  #1 across tiles        Drake rows');
for (const v of variantRows) {
  console.log(`  ${v.name.padEnd(36)}${v.meanDistinct.toFixed(1).padStart(9)}  ${pctS(v.meanTopShare).padStart(9)}  `
    + `${v.jaccard.toFixed(3).padStart(7)}  ${String(v.topAcross).padEnd(20)} ${pctS(v.topAcrossShare).padStart(6)}  ${String(v.drakeRows).padStart(4)}`);
}
out.attribution = variantRows;

// Catalogue skew, the legitimate-finding branch: is the artist over-represented in the pool the
// tile actually draws from (its genre), before ranking touches anything?
console.log('  ── catalogue skew check: is the winner simply over-owned? ──');
const winner = across[0]?.[0];
const genreOfWinner = new Map();
for (const s of songs) if (s.artist === winner && s.genre) genreOfWinner.set(s.genre, (genreOfWinner.get(s.genre) || 0) + 1);
const winnerGenre = [...genreOfWinner.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
const inGenre = songs.filter((s) => s.genre === winnerGenre).length;
const winnerInGenre = songs.filter((s) => s.genre === winnerGenre && s.artist === winner).length;
console.log(`  ${winner}: ${winnerInGenre} of ${inGenre.toLocaleString()} ${winnerGenre} songs = ${pctS(winnerInGenre / inGenre)} of the pool, `
  + `but ${pctS((tileRows.get(winner) || 0) / totalRows)} of the recommended rows `
  + `→ over-selected ${((tileRows.get(winner) || 0) / totalRows / (winnerInGenre / inGenre)).toFixed(0)}×`);
out.skew = { winner, winnerGenre, winnerInGenre, inGenre,
             poolShare: winnerInGenre / inGenre, rowShare: (tileRows.get(winner) || 0) / totalRows };

// ══════════════════════════════════════════════════════════════════════════════════════════
console.log('\n════ 3. HOW MUCH OF RANK ORDER IS PLAY COUNT? ════════════════════════════════');
// Two readings per tile: over ALL scored candidates, and over the head of the ranking (top 200) —
// a tile only ever reads the head, and a signal can be weak overall and decisive at the top.
const rows3 = [];
for (const x of shipped) {
  const sc = x.r.scored;
  const all = { fam: sc.map((c) => c.fam), score: sc.map((c) => c.score),
                sim: sc.map((c) => c.sim), art: sc.map((c) => c.tA), gen: sc.map((c) => c.tG) };
  const head = sc.slice(0, 200);
  rows3.push({
    name: x.c.name, cand: sc.length,
    rAllFam: spearman(all.fam, all.score),
    rAllSim: spearman(all.sim, all.score),
    rHeadFam: spearman(head.map((c) => c.fam), head.map((c) => c.score)),
    rHeadSim: spearman(head.map((c) => c.sim), head.map((c) => c.score)),
    rHeadArt: spearman(head.map((c) => c.tA), head.map((c) => c.score)),
    // Share of the winning row's score contributed by each term, over the 25 picked.
    famShare: mean(x.r.picks.map((p) => p.fam / p.score)),
    artShare: mean(x.r.picks.map((p) => p.tA / p.score)),
    genShare: mean(x.r.picks.map((p) => p.tG / p.score)),
    yearShare: mean(x.r.picks.map((p) => p.tY / p.score)),
    musShare: mean(x.r.picks.map((p) => p.tM / p.score)),
    // sd of each additive term over the head — the honest "who is doing the separating".
    sdFam: sd(head.map((c) => c.fam)), sdArt: sd(head.map((c) => c.tA)),
    sdGen: sd(head.map((c) => c.tG)), sdYear: sd(head.map((c) => c.tY)), sdMus: sd(head.map((c) => c.tM)),
    playedShare: x.r.picks.filter((p) => p.n > 0).length / x.r.picks.length,
  });
}
function sd(a) { const m = mean(a); return Math.sqrt(mean(a.map((x) => (x - m) * (x - m)))); }
console.log(`  Spearman(play term, final score) over ALL candidates : ${mean(rows3.map((r) => r.rAllFam)).toFixed(3)}`);
console.log(`  Spearman(similarity, final score) over ALL candidates: ${mean(rows3.map((r) => r.rAllSim)).toFixed(3)}`);
console.log(`  Spearman(play term, final score) over the TOP 200    : ${mean(rows3.map((r) => r.rHeadFam)).toFixed(3)}`);
console.log(`  Spearman(similarity, final score) over the TOP 200   : ${mean(rows3.map((r) => r.rHeadSim)).toFixed(3)}`);
console.log(`  Spearman(artist term, final score) over the TOP 200  : ${mean(rows3.map((r) => r.rHeadArt)).toFixed(3)}`);
console.log('  ── where the score of a PICKED row comes from (mean share of its own total) ──');
console.log(`    play count ${pctS(mean(rows3.map((r) => r.famShare)))} · artist ${pctS(mean(rows3.map((r) => r.artShare)))} `
  + `· genre ${pctS(mean(rows3.map((r) => r.genShare)))} · year ${pctS(mean(rows3.map((r) => r.yearShare)))} `
  + `· tempo/key ${pctS(mean(rows3.map((r) => r.musShare)))}`);
console.log('  ── SEPARATING POWER at the head of the ranking (sd of each additive term, top 200) ──');
console.log(`    play count ${mean(rows3.map((r) => r.sdFam)).toFixed(4)} · artist ${mean(rows3.map((r) => r.sdArt)).toFixed(4)} `
  + `· genre ${mean(rows3.map((r) => r.sdGen)).toFixed(4)} · year ${mean(rows3.map((r) => r.sdYear)).toFixed(4)} `
  + `· tempo/key ${mean(rows3.map((r) => r.sdMus)).toFixed(4)}`);
console.log(`  share of PICKED rows that have ANY play history: ${pctS(mean(rows3.map((r) => r.playedShare)))} `
  + `(base rate in catalog ${pctS(playCount.size / N)})`);
// THE NUMBER THAT SETTLES IT. A term's nominal weight is not its influence: `genre` carries the
// largest weight and separates nothing (every candidate is admitted on genre, so it is a
// plateau). Share of the total SEPARATION at the head is what a ranking is actually made of.
const sdTot = ['sdFam', 'sdArt', 'sdGen', 'sdYear', 'sdMus'].map((k) => mean(rows3.map((r) => r[k])));
const sdSum = sdTot.reduce((a, b) => a + b, 0);
console.log('  ── SHARE OF ALL SEPARATION at the head (sd of the term ÷ Σ sd) ──');
console.log(`    play count ${pctS(sdTot[0] / sdSum)} · artist ${pctS(sdTot[1] / sdSum)} · genre ${pctS(sdTot[2] / sdSum)} `
  + `· year ${pctS(sdTot[3] / sdSum)} · tempo/key ${pctS(sdTot[4] / sdSum)}`);
console.log('    (nominal weights on these tiles: genre .5625 · play count .30 · artist .25 · year .1875 · musical 0 —');
console.log('     the collections are Apple-Music-sourced, so family C has no bpm/key to speak and collapses into genre)');
const jacNoFam = out.attribution ? null : null;
out.rankExplained_separationShare = { fam: sdTot[0] / sdSum, artist: sdTot[1] / sdSum,
  genre: sdTot[2] / sdSum, year: sdTot[3] / sdSum, musical: sdTot[4] / sdSum };
const meanPicksN = mean(shipped.flatMap((x) => x.r.picks).map((p) => p.n));
const meanCandN = mean(shipped.flatMap((x) => x.r.scored).map((p) => p.n));
console.log(`  mean lifetime plays: PICKED rows ${meanPicksN.toFixed(1)} vs all candidates ${meanCandN.toFixed(2)} `
  + `→ the tile selects songs played ${(meanPicksN / Math.max(1e-9, meanCandN)).toFixed(0)}× more than the pool average`);
const meanPlaysRow = { picked: meanPicksN, candidates: meanCandN };
out.rankExplained = {
  spearmanAllFam: mean(rows3.map((r) => r.rAllFam)), spearmanAllSim: mean(rows3.map((r) => r.rAllSim)),
  spearmanHeadFam: mean(rows3.map((r) => r.rHeadFam)), spearmanHeadSim: mean(rows3.map((r) => r.rHeadSim)),
  spearmanHeadArtist: mean(rows3.map((r) => r.rHeadArt)),
  meanShare: { fam: mean(rows3.map((r) => r.famShare)), artist: mean(rows3.map((r) => r.artShare)),
               genre: mean(rows3.map((r) => r.genShare)), year: mean(rows3.map((r) => r.yearShare)),
               musical: mean(rows3.map((r) => r.musShare)) },
  sdHead: { fam: mean(rows3.map((r) => r.sdFam)), artist: mean(rows3.map((r) => r.sdArt)),
            genre: mean(rows3.map((r) => r.sdGen)), year: mean(rows3.map((r) => r.sdYear)),
            musical: mean(rows3.map((r) => r.sdMus)) },
  playedShareOfPicks: mean(rows3.map((r) => r.playedShare)),
  meanPlays: meanPlaysRow,
};

// ══════════════════════════════════════════════════════════════════════════════════════════
console.log('\n════ 3b. THE CAP KEY — does "Drake" == "Drake & Future"? ═════════════════════');
// Every per-artist cap in the app (device AND Lambda) keys on the WHOLE artist string. A
// collaboration is a different string, so it does not consume the artist's budget. On a hip-hop
// library that is not a corner case — it is how most of the genre is credited.
const nameHas = (a, who) => new RegExp(`(^|[^a-z])${who}([^a-z]|$)`, 'i').test(a || '');
const collabRows = new Map();      // primary artist -> rows credited to a DIFFERENT string
for (const [a, n] of tileRows) {
  for (const who of ['Drake', 'Kanye West', 'Rihanna', 'Alicia Keys', 'Future', 'Lil Wayne']) {
    if (a !== who && nameHas(a, who)) collabRows.set(who, (collabRows.get(who) || 0) + n);
  }
}
console.log('  collection tiles — rows credited to a string that is NOT the artist\'s own name:');
for (const who of ['Drake', 'Kanye West', 'Rihanna', 'Alicia Keys', 'Future', 'Lil Wayne']) {
  const own = tileRows.get(who) || 0; const via = collabRows.get(who) || 0;
  if (own + via > 0) console.log(`    ${who.padEnd(14)} own-name rows ${String(own).padStart(3)}  + ${String(via).padStart(3)} via collaborations  = ${own + via} `
    + `(the cap of 3 only ever counted the first ${own === 0 ? 0 : ''}${own})`);
}
// Per tile: when the artist appears at all, how many rows do they take?
const perTileWhenPresent = new Map();
for (const x of shipped) {
  const cnt = new Map();
  for (const p of x.r.picks) cnt.set(p.artist, (cnt.get(p.artist) || 0) + 1);
  for (const [a, n] of cnt) {
    const e = perTileWhenPresent.get(a) || { tiles: 0, rows: 0 };
    e.tiles += 1; e.rows += n; perTileWhenPresent.set(a, e);
  }
}
const worst = [...perTileWhenPresent.entries()].filter(([, e]) => e.tiles >= 4)
  .sort((a, b) => (b[1].rows / b[1].tiles) - (a[1].rows / a[1].tiles)).slice(0, 8);
console.log('  rows-per-tile WHEN PRESENT (artists appearing in ≥4 tiles) — "multiple X songs" made numeric:');
for (const [a, e] of worst) console.log(`    ${a.padEnd(22)} ${(e.rows / e.tiles).toFixed(2)} rows in each of ${e.tiles} tiles`);
out.capKey = { collabRows: Object.fromEntries(collabRows), rowsPerTileWhenPresent: worst.map(([a, e]) => ({ artist: a, tiles: e.tiles, rowsPerTile: e.rows / e.tiles })) };

// ══════════════════════════════════════════════════════════════════════════════════════════
console.log('\n════ 4. IN DA ZONE (ZoneEngine.inDaZone) ═════════════════════════════════════');
// The device's play EVENT log is not on disk, so the seed is SIMULATED from Apple's own
// last-played stamps: the songs Apple says were touched inside the 60-day window, at their real
// stamps. That is the closest honest reconstruction of "what he has been bumping".
const recent = [...lastPlayed.entries()].filter(([id, ms]) => byId.has(id) && NOW - ms <= 60 * DAY);
const plays = [];
for (const [id, ms] of recent) {
  const n = Math.min(4, Math.max(1, pc(id)));
  for (let i = 0; i < n; i++) plays.push({ songId: id, playedAtMs: ms - i * 3 * DAY });
}
const crates = sample.map((c) => c.songIds);
console.log(`  simulated seed: ${recent.length} songs played inside 60 days → ${plays.length} events`);
const zoneVariants = [
  ['shipped (with artist novelty)', {}],
  ['BEFORE — no artist novelty in aux', { auxNoveltyWeight: 0 }],
  ['no familiarity in aux (auxFamiliarityWeight→0 via famWeight 0 + aux)', { famWeight: 0 }],
  ['no aux at all (auxGain 0)', { auxGain: 0 }],
  ['NO per-artist cap', { maxPerArtist: Infinity }],
];
const zoneOut = [];
for (const [name, opts] of zoneVariants) {
  const q = inDaZone(plays, crates, opts);
  const rows = q.picks.map((p) => ({ artist: byId.get(p.id)?.artist ?? '?', id: p.id, pool: p.pool }));
  const st = artistStats(rows);
  const re = rows.filter((r) => r.pool === 'rediscovery').length;
  zoneOut.push({ name, n: rows.length, distinct: st.distinct, top: st.top, topN: st.topN,
                 topShare: st.topShare, rediscoveryShare: rows.length ? re / rows.length : 0,
                 played: q.picks.filter((p) => pc(p.id) > 0).length / Math.max(1, q.picks.length) });
}
console.log('  variant                                    n  distinct  top artist            top%   rediscovery%  %picks w/ plays');
for (const z of zoneOut) {
  console.log(`  ${z.name.slice(0, 40).padEnd(40)}${String(z.n).padStart(4)}  ${String(z.distinct).padStart(8)}  `
    + `${String(z.top).slice(0, 20).padEnd(20)} ${pctS(z.topShare).padStart(6)}  ${pctS(z.rediscoveryShare).padStart(11)}  ${pctS(z.played).padStart(13)}`);
}
out.zone = zoneOut;

// ══════════════════════════════════════════════════════════════════════════════════════════
console.log('\n════ 5. CLOUD For You (the Lambda, imported — not ported) ════════════════════');
const lambdaPath = join(__dirname, 'lambda', 'rec-engine', 'index.mjs');
if (existsSync(lambdaPath)) {
  const { scoreForYou, scoreSimilarToCollections, playCountSignal } = await import(lambdaPath);
  const featuresById = new Map(JSON.parse(readFileSync(join(__dirname, '..', 'public', 'rec-features.json'), 'utf8'))
    .songs.map((r) => [r.i, r]));
  // The state a real device uploads: the lifetime play-count snapshot (top 20k, as the Lambda
  // truncates), last-played DAYS, the collections snapshot, and the same simulated recent plays.
  const counts = {}; const lastPlayedDays = {};
  const rowsPC = [...playCount.entries()].sort((a, b) => b[1] - a[1]).slice(0, 20_000);
  for (const [id, n] of rowsPC) {
    counts[id] = n;
    const ms = lastPlayed.get(id);
    if (ms) lastPlayedDays[id] = Math.floor(ms / DAY);
  }
  const state = {
    v: 1, profileId: 'measure', keyHash: null, createdAtMs: NOW, updatedAtMs: NOW,
    plays: plays.slice(0, 5000).map((p, i) => ({ id: `p${i}`, songId: p.songId, atMs: p.playedAtMs })),
    favorites: {}, activity: [], puzzle: [], feedback: [],
    collections: { atMs: NOW, list: sample.map((c) => ({ id: c.id, kind: 'playlist', name: c.name, songIds: c.songIds })) },
    playCounts: { atMs: NOW, counts, lastPlayedDays },
  };
  const fy = scoreForYou(state, featuresById, { nowMs: NOW, limit: 50 });
  const stFY = artistStats(fy.songs.map((s) => ({ artist: s.artist || '?' })));
  console.log(`  /recs/songs → ${fy.songs.length} songs · ${stFY.distinct} distinct artists · `
    + `top ${stFY.top} ${stFY.topN} (cap 2) · ${pctS(stFY.topShare)}`);
  const withPlays = fy.songs.filter((s) => pc(s.songId) > 0).length;
  console.log(`  picks with ANY play history: ${withPlays}/${fy.songs.length} = ${pctS(withPlays / fy.songs.length)} `
    + `(catalog base rate ${pctS(playCount.size / N)})`);
  const reasonTally = new Map();
  for (const s of fy.songs) for (const r of s.reasons) {
    const k = /played this/.test(r) ? 'plays' : /played this recently|recently/.test(r) ? 'recency'
      : /Same genre/.test(r) ? 'genre' : /BPM/.test(r) ? 'bpm' : /Harmonically/.test(r) ? 'camelot'
      : /From around|era/.test(r) ? 'year' : /Sounds like|Sound unknown|Sound weighed/.test(r) ? 'timbre'
      : /collection/.test(r) ? 'collection'
      : /Artist you/.test(r) ? 'artist' : /mood/.test(r) ? 'sentiment' : 'other';
    reasonTally.set(k, (reasonTally.get(k) || 0) + 1);
  }
  console.log(`  reason mix over the 50 rows: ${[...reasonTally.entries()].sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k} ${v}`).join(' · ')}`);
  console.log(`  top 10 rows: ${fy.songs.slice(0, 10).map((s) => `${s.artist} (${pc(s.songId)}p)`).join(', ')}`);
  // Seeds: the top-200-by-plays seeding rule is the mechanism to interrogate.
  const seedArtists = new Map();
  for (const id of fy.seeds) { const a = featuresById.get(id)?.a; if (a) seedArtists.set(a, (seedArtists.get(a) || 0) + 1); }
  const seedTop = [...seedArtists.entries()].sort((a, b) => b[1] - a[1]);
  console.log(`  SEEDS (${fy.seeds.length}): ${seedTop.slice(0, 6).map(([a, n]) => `${a} ${n}`).join(' · ')} `
    + `→ top seed artist holds ${pctS((seedTop[0]?.[1] || 0) / fy.seeds.length)} of the seed set`);
  out.cloudForYou = { n: fy.songs.length, distinct: stFY.distinct, top: stFY.top, topN: stFY.topN,
    withPlaysShare: withPlays / fy.songs.length,
    reasons: Object.fromEntries(reasonTally), seedTop: seedTop.slice(0, 10) };

  // /recs/similar — the Gem Collector booster, per-artist cap 2.
  const sim = scoreSimilarToCollections(state, featuresById, [sample[0].id], { nowMs: NOW, limit: 200 });
  const stSim = artistStats(sim.songs.map((s) => ({ artist: s.artist || '?' })));
  const simPlayed = sim.songs.filter((s) => pc(s.songId) > 0).length;
  console.log(`  /recs/similar (1 collection) → ${sim.songs.length} songs · ${stSim.distinct} artists · `
    + `${pctS(simPlayed / Math.max(1, sim.songs.length))} have play history`);
  out.cloudSimilar = { n: sim.songs.length, distinct: stSim.distinct, withPlaysShare: simPlayed / Math.max(1, sim.songs.length) };

  // ── 5b. The Lambda's own knobs, driven directly ────────────────────────────────────────
  console.log('  ── 5b. cloud ablations (the same state, different play inputs) ──');
  const drakeAnyIn = (rows) => rows.filter((s) => /(^|[^a-z])drake([^a-z]|$)/i.test(s.artist || '')).length;
  const noCounts = { ...state, playCounts: { atMs: NOW, counts: {}, lastPlayedDays: {} } };
  const noDates = { ...state, playCounts: { atMs: NOW, counts, lastPlayedDays: {} } };
  const cloudRuns = [
    ['shipped (counts + dates)', state, {}],
    ['no play counts at all', noCounts, {}],
    ['counts, no last-played dates', noDates, {}],
    ['seed limit 20 (shipped 200)', state, { playCountSeedLimit: 20 }],
    ['seed limit 2000', state, { playCountSeedLimit: 2000 }],
  ];
  const cloudOut = [];
  for (const [name, st, o] of cloudRuns) {
    const r = scoreForYou(st, featuresById, { nowMs: NOW, limit: 50, ...o });
    const s = artistStats(r.songs.map((x) => ({ artist: x.artist || '?' })));
    const nev = r.songs.filter((x) => pc(x.songId) === 0).length;
    cloudOut.push({ name, n: r.songs.length, distinct: s.distinct, top: s.top, topN: s.topN,
                    neverPlayed: nev / Math.max(1, r.songs.length), drakeAny: drakeAnyIn(r.songs),
                    jac: jaccard(r.songs.map((x) => x.songId), fy.songs.map((x) => x.songId)) });
  }
  console.log('    variant                          n  distinct  top artist          never-played  Drake-credited  ∩shipped');
  for (const c of cloudOut) {
    console.log(`    ${c.name.padEnd(30)}${String(c.n).padStart(3)}  ${String(c.distinct).padStart(8)}  `
      + `${String(c.top).slice(0, 18).padEnd(18)} ${pctS(c.neverPlayed).padStart(12)}  ${String(c.drakeAny).padStart(14)}  ${c.jac.toFixed(3).padStart(8)}`);
  }
  console.log(`    per-artist cap is 2 on the RAW credit string, so the ${drakeAnyIn(fy.songs)} Drake-credited rows in the shipped 50 `
    + `sit under a cap that only ever counted the ${fy.songs.filter((s) => s.artist === 'Drake').length} spelled exactly "Drake".`);
  out.cloudAblations = cloudOut;
} else {
  console.log('  (lambda not found — skipped)');
}

// ══════════════════════════════════════════════════════════════════════════════════════════
console.log('\n════ 6. WHAT A NOVELTY TERM COULD BE BUILT FROM (coverage + discrimination) ══');
// A novelty axis is only usable if it (a) is defined for most of the library and (b) actually
// SPLITS it. A signal defined for 1% is a tiebreak; one that scores 99% identically is a constant.
const artistPlayByKey = new Map();
const artistSongsByKey = new Map();
for (const s of songs) {
  artistSongsByKey.set(s.artistKey, (artistSongsByKey.get(s.artistKey) || 0) + 1);
  const n = pc(s.id);
  if (n > 0) artistPlayByKey.set(s.artistKey, (artistPlayByKey.get(s.artistKey) || 0) + n);
}
const genrePlays = new Map(); const genreSongs = new Map();
for (const s of songs) {
  if (!s.genre) continue;
  genreSongs.set(s.genre, (genreSongs.get(s.genre) || 0) + 1);
  const n = pc(s.id);
  if (n > 0) genrePlays.set(s.genre, (genrePlays.get(s.genre) || 0) + n);
}
const cands = [];
const defined = (fn) => songs.filter(fn).length;
cands.push(['never-played (n = 0)', defined((s) => pc(s.id) === 0), 'binary', 'every song — 0/1 is defined for 100%']);
cands.push(['low-count (n ≤ 2)', defined((s) => { const n = pc(s.id); return n > 0 && n <= 2; }), 'binary', 'graded via 1/(1+log2(1+n))']);
cands.push(['dormant > 3 y', [...lastPlayed.values()].filter((ms) => NOW - ms > 3 * 365 * DAY).length, 'graded', 'only defined for the 52% with a date']);
cands.push(['dormant > 5 y', [...lastPlayed.values()].filter((ms) => NOW - ms > 5 * 365 * DAY).length, 'graded', '']);
cands.push(['unfamiliar ARTIST (0 plays for the artist)', songs.filter((s) => !artistPlayByKey.has(s.artistKey)).length, 'graded', 'artist-level, so it is defined for 100% of songs']);
cands.push(['unfamiliar GENRE (bottom-half genre by plays)', 0, 'graded', '']);
const genreRank = [...genrePlays.entries()].sort((a, b) => b[1] - a[1]);
const halfIdx = Math.floor(genreRank.length / 2);
const weakGenres = new Set(genreRank.slice(halfIdx).map(([g]) => g));
cands[cands.length - 1][1] = songs.filter((s) => s.genre && weakGenres.has(s.genre)).length;
console.log('  candidate axis                                  songs it flags     share   note');
for (const [name, n, kind, note] of cands) {
  console.log(`  ${name.padEnd(44)}${String(n).padStart(8)}  ${pctS(n / N).padStart(8)}   ${kind}${note ? ' — ' + note : ''}`);
}
// Discrimination: entropy/gini of each axis over the catalog, and how much of the library each
// axis can actually reorder.
const artistFamiliarity = (s) => {
  const p = artistPlayByKey.get(s.artistKey) || 0;
  return p > 0 ? Math.log2(1 + p) / Math.log2(1 + Math.max(...artistPlayByKey.values())) : 0;
};
const maxArtistPlays = Math.max(...artistPlayByKey.values());
const axes = {
  songNovelty: songs.map((s) => (pc(s.id) === 0 ? 1 : 1 - Math.log2(1 + pc(s.id)) / Math.log2(1 + Math.max(...playCount.values())))),
  dormancy: songs.map((s) => 1 - recencyScore(lastPlayed.get(s.id) || 0, NOW)),
  artistNovelty: songs.map((s) => 1 - artistFamiliarity(s)),
  genreNovelty: songs.map((s) => {
    const p = s.genre ? (genrePlays.get(s.genre) || 0) : 0;
    return 1 - (p > 0 ? Math.log2(1 + p) / Math.log2(1 + Math.max(...genrePlays.values())) : 0);
  }),
};
console.log('  ── as a 0…1 gradient over the WHOLE catalog ──');
console.log('  axis            mean     sd     p10    median    p90   distinct-ish values');
for (const [k, v] of Object.entries(axes)) {
  const s = [...v].sort((a, b) => a - b);
  const m = mean(v);
  const dev = Math.sqrt(mean(v.map((x) => (x - m) * (x - m))));
  const distinct = new Set(v.map((x) => Math.round(x * 100))).size;
  console.log(`  ${k.padEnd(14)}${m.toFixed(3).padStart(7)} ${dev.toFixed(3).padStart(6)} ${pctl(s, 0.10).toFixed(3).padStart(7)} `
    + `${pctl(s, 0.5).toFixed(3).padStart(7)} ${pctl(s, 0.9).toFixed(3).padStart(7)}   ${distinct}/101`);
}
// Independence: a novelty axis that just mirrors the play term is not a second signal.
const famVec = songs.map((s) => familiarityVec(s));
function familiarityVec(s) { const n = pc(s.id); return n > 0 ? Math.log2(1 + n) / Math.log2(1 + Math.max(...playCount.values())) : 0; }
console.log('  ── correlation with the SHIPPED play-count term (a novelty axis that mirrors it teaches nothing) ──');
for (const [k, v] of Object.entries(axes)) console.log(`    ${k.padEnd(14)} spearman ${spearman(v, famVec).toFixed(3)}`);
out.novelty = {
  candidates: cands.map(([name, n]) => ({ name, songs: n, share: n / N })),
  axes: Object.fromEntries(Object.entries(axes).map(([k, v]) => {
    const m = mean(v); const s = [...v].sort((a, b) => a - b);
    return [k, { mean: m, sd: Math.sqrt(mean(v.map((x) => (x - m) * (x - m)))),
                 p10: pctl(s, 0.1), median: pctl(s, 0.5), p90: pctl(s, 0.9),
                 spearmanWithPlayTerm: spearman(v, famVec) }];
  })),
};

// ══════════════════════════════════════════════════════════════════════════════════════════
console.log('\n════ 7. THE IDENTITY THAT KILLS THE OBVIOUS FIX ══════════════════════════════');
// A SONG-LEVEL novelty term is not a second signal. With `nov = 1 − fam`:
//     sim + wf·fam + wn·(1 − fam)  ==  sim + wn + (wf − wn)·fam
// — the constant does not reorder anything, so adding song-novelty at weight wn is EXACTLY
// reducing the play weight to (wf − wn). The measurement below confirms the transform is exact
// (spearman −1.000 in section 6) rather than approximately so. It is the reason a "novelty term"
// built from the song's own play count creates no headroom for thumbs feedback: it re-reads the
// same number. Only axes that are NOT a function of this song's count can.
console.log('  spearman(songNovelty, playTerm) = -1.000 → the two are ONE axis, opposite signs.');
console.log('  → "add novelty" and "cut the play weight" are the same edit; the informative axes are:');
console.log(`     artist-level novelty  spearman ${out.novelty.axes.artistNovelty.spearmanWithPlayTerm.toFixed(3)} (partly independent — usable)`);
console.log(`     genre-level novelty   spearman ${out.novelty.axes.genreNovelty.spearmanWithPlayTerm.toFixed(3)} (independent, but only 12 buckets → coarse)`);
console.log(`     dormancy              spearman ${out.novelty.axes.dormancy.spearmanWithPlayTerm.toFixed(3)} (mostly redundant with play count)`);

console.log('\n════ 8. CANDIDATE WEIGHTINGS (re-ranking the SAME scored candidates) ═════════');
// Re-rank every tile's candidate set under a parameterized score, and report the four things
// that matter: does it still recommend RELEVANT songs (mean similarity of the picks), does it
// break the artist grip, does it open real headroom (never-played share), and does the cap key
// fix change anything on its own.
const WEIGHTINGS = [
  { name: 'shipped (fam .30)',                 wf: 0.30, wn: 0,    wa: 0,    cap: 3, key: 'artistKey' },
  { name: 'fam .15',                           wf: 0.15, wn: 0,    wa: 0,    cap: 3, key: 'artistKey' },
  { name: 'fam .10 + artistNov .20',           wf: 0.10, wn: 0,    wa: 0.20, cap: 3, key: 'artistKey' },
  { name: 'fam .10 + artistNov .20, primary',  wf: 0.10, wn: 0,    wa: 0.20, cap: 3, key: 'primaryKey' },
  { name: 'fam .10 + artistNov .30, primary',  wf: 0.10, wn: 0,    wa: 0.30, cap: 3, key: 'primaryKey' },
  { name: 'fam 0 + artistNov .25, primary',    wf: 0,    wn: 0,    wa: 0.25, cap: 3, key: 'primaryKey' },
  { name: 'fam .15 + songNov .15 (== fam 0)',  wf: 0.15, wn: 0.15, wa: 0,    cap: 3, key: 'artistKey' },
  { name: 'shipped weights, primary-key cap',  wf: 0.30, wn: 0,    wa: 0,    cap: 3, key: 'primaryKey' },
  { name: 'shipped weights, cap 2 primary',    wf: 0.30, wn: 0,    wa: 0,    cap: 2, key: 'primaryKey' },
];
function rerank(scored, w) {
  const rows = scored.map((c) => ({ ...c, s2: c.sim + w.wf * c.famRaw + w.wn * c.novSong + w.wa * c.novArtist }));
  rows.sort((a, b) => (b.s2 - a.s2) || (a.id < b.id ? -1 : 1));
  const per = new Map(); const picks = [];
  for (const c of rows) {
    if (picks.length >= 25) break;
    const k = c[w.key];
    const n = per.get(k) || 0;
    if (n >= w.cap) continue;
    per.set(k, n + 1);
    picks.push(c);
  }
  return picks;
}
const shippedIds = shipped.map((x) => x.r.picks.map((p) => p.id));
const wOut = [];
for (const w of WEIGHTINGS) {
  const allPicks = shipped.map((x) => rerank(x.r.scored, w));
  const flat = allPicks.flat();
  const st = artistStats(flat);
  const perTile = allPicks.map((p) => artistStats(p));
  const rowsBy = new Map();
  for (const p of flat) rowsBy.set(p.artist, (rowsBy.get(p.artist) || 0) + 1);
  const top = [...rowsBy.entries()].sort((a, b) => b[1] - a[1])[0];
  wOut.push({
    name: w.name,
    meanDistinct: mean(perTile.map((s) => s.distinct)),
    neverPlayed: flat.filter((p) => p.n === 0).length / flat.length,
    unfamiliarArtist: flat.filter((p) => p.novArtist >= 0.999).length / flat.length,
    meanSim: mean(flat.map((p) => p.sim)),
    simVsShipped: mean(flat.map((p) => p.sim)) / mean(shipped.flatMap((x) => x.r.picks).map((p) => p.sim)),
    jac: mean(allPicks.map((p, i) => jaccard(p.map((x) => x.id), shippedIds[i]))),
    topArtist: top?.[0], topRows: top?.[1] ?? 0,
    drakeAny: flat.filter((p) => nameHas(p.artist, 'Drake')).length,
    distinctAll: st.distinct,
  });
}
console.log('  weighting                             dist/tile  never-played  new-artist  meanSim(rel)  ∩shipped  #1 artist rows  Drake-any');
for (const r of wOut) {
  console.log(`  ${r.name.padEnd(36)}${r.meanDistinct.toFixed(1).padStart(9)}  ${pctS(r.neverPlayed).padStart(12)}  `
    + `${pctS(r.unfamiliarArtist).padStart(10)}  ${(100 * r.simVsShipped).toFixed(0).padStart(9)}%  ${r.jac.toFixed(3).padStart(8)}  `
    + `${String(r.topArtist).slice(0, 14).padEnd(14)} ${String(r.topRows).padStart(3)}  ${String(r.drakeAny).padStart(6)}`);
}
out.weightings = wOut;

// CAVEAT CHECK: an artist-LEVEL novelty term is constant across an artist's whole discography, so
// it can simply crown a different artist instead of breaking the concentration. Measure it.
console.log('  ── does the recommended weighting break the grip, or just move the crown? ──');
for (const w of WEIGHTINGS.filter((x) => /shipped \(fam|artistNov \.20, primary/.test(x.name))) {
  const allPicks = shipped.map((x) => rerank(x.r.scored, w));
  const tiles = new Map(); const rows = new Map();
  for (const p of allPicks) {
    const seen = new Set();
    for (const c of p) {
      rows.set(c.artist, (rows.get(c.artist) || 0) + 1);
      if (!seen.has(c.artist)) { seen.add(c.artist); tiles.set(c.artist, (tiles.get(c.artist) || 0) + 1); }
    }
  }
  const byTiles = [...tiles.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5);
  const tot = [...rows.values()].reduce((a, b) => a + b, 0);
  const top10 = [...rows.values()].sort((a, b) => b - a).slice(0, 10).reduce((a, b) => a + b, 0);
  console.log(`    ${w.name.padEnd(34)} distinct artists ${String(rows.size).padStart(3)} · top-10 hold ${pctS(top10 / tot)} of rows · `
    + `most ubiquitous: ${byTiles.map(([a, n]) => `${a} ${n}/40`).join(', ')}`);
}


// ══════════════════════════════════════════════════════════════════════════════════════════
// `--all` runs this over EVERY suggestible collection instead of the 40-tile sample. It is worth
// the extra minutes when tuning the gain: the answer depends on collection SIZE (a big playlist
// has more member artists, so the artist term fires more often and known artists score higher),
// and sections 1–8 deliberately sample the LARGEST playlists. The shipped 0.40 was calibrated on
// the full 131, where it lands the never-played share on the catalog's own base rate.
const ALL_COLLECTIONS = process.argv.includes('--all');
const s9Pop = ALL_COLLECTIONS ? allPlaylists.filter((p) => p.songIds.length >= 8) : sample;
console.log(`\n════ 9. AFTER — THE SHIPPED REBALANCE, ${String(s9Pop.length).padStart(3)} TILES, SAME HARNESS ═══════════`);
// Both sides are produced by the SAME ported `ZoneEngine.suggestions` in this run, from the same
// catalog and the same play-count cache, so this is a measurement rather than a comparison
// against a paragraph written last week. TUNING_BEFORE/TUNING_AFTER mirror the Swift constants.
const beforeAfter = [['BEFORE (shipped)', TUNING_BEFORE], ['AFTER  (this change)', TUNING_AFTER]];
const baRows = [];
for (const [name, tuning] of beforeAfter) {
  const tiles = [];
  // Only the PICKS are retained: holding each tile's full `scored` array is ~30k objects, and at
  // 131 tiles x 2 configs that is what makes the difference between running and dying on heap.
  for (const c of s9Pop) {
    const r = suggestions(c.songIds, tuning);
    if (r) tiles.push(r.picks);
  }
  const flat = tiles.flat();
  const rowsBy = new Map(); const tilesBy = new Map();
  for (const p of tiles) {
    const seen = new Set();
    for (const c of p) {
      rowsBy.set(c.artist, (rowsBy.get(c.artist) || 0) + 1);
      if (!seen.has(c.artist)) { seen.add(c.artist); tilesBy.set(c.artist, (tilesBy.get(c.artist) || 0) + 1); }
    }
  }
  const byRows = [...rowsBy.entries()].sort((a, b) => b[1] - a[1]);
  const byTiles = [...tilesBy.entries()].sort((a, b) => b[1] - a[1]);
  const top10 = byRows.slice(0, 10).reduce((s, x) => s + x[1], 0) / flat.length;
  // The per-tile "multiple X songs" number the owner actually reported.
  const perTileWhenPresent = byRows.slice(0, 1).map(([a]) => rowsBy.get(a) / tilesBy.get(a))[0];
  baRows.push({
    name, tiles,
    distinctPerTile: mean(tiles.map((p) => artistStats(p).distinct)),
    fullSlotTiles: tiles.filter((p) => artistStats(p).topN >= 3).length,
    distinctAll: new Set(flat.map((c) => c.artist)).size,
    top10, meanSim: mean(flat.map((c) => c.sim)),
    neverPlayed: flat.filter((c) => c.n === 0).length / flat.length,
    newArtist: flat.filter((c) => c.novPrimary >= 0.999).length / flat.length,
    meanPlays: mean(flat.map((c) => c.n)),
    drake: flat.filter((c) => /drake/i.test(c.artist || '')).length,
    topArtist: byRows[0], mostUbiquitous: byTiles[0], perTileWhenPresent,
    rows: flat.length,
  });
}
const [B, A] = baRows;
const line = (label, b, a, note = '') =>
  console.log(`  ${label.padEnd(38)}${String(b).padStart(12)}   →${String(a).padStart(12)}   ${note}`);
console.log(`  ${''.padEnd(38)}${'BEFORE'.padStart(12)}    ${'AFTER'.padStart(12)}`);
line('distinct artists per 25-row tile', B.distinctPerTile.toFixed(1), A.distinctPerTile.toFixed(1));
line('tiles where an artist takes all 3 slots', `${B.fullSlotTiles}/${B.tiles.length}`, `${A.fullSlotTiles}/${A.tiles.length}`);
line('distinct artists over all tiles', B.distinctAll, A.distinctAll);
line("top-10 artists' share of all rows", pctS(B.top10), pctS(A.top10));
line('most ubiquitous artist', `${B.mostUbiquitous[0]} ${B.mostUbiquitous[1]}/${B.tiles.length}`,
     `${A.mostUbiquitous[0]} ${A.mostUbiquitous[1]}/${A.tiles.length}`,
     '← the residual gap: nothing decays an artist ACROSS tiles');
line('#1 artist, rows held', `${B.topArtist[0]} ${B.topArtist[1]}`, `${A.topArtist[0]} ${A.topArtist[1]}`);
line('rows credited to Drake (any credit)', B.drake, A.drake, '← the reported symptom');
console.log('  ── FEEDBACK HEADROOM: is a 👍 still confirming what the ranking already read? ──');
line('picks that have NEVER been played', pctS(B.neverPlayed), pctS(A.neverPlayed),
     `← catalog base rate ${pctS(1 - playCount.size / N)}`);
line('picks by an artist with NO plays at all', pctS(B.newArtist), pctS(A.newArtist));
line('mean lifetime plays of a pick', B.meanPlays.toFixed(1), A.meanPlays.toFixed(1),
     `← pool mean ${mean(shipped.flatMap((x) => x.r.scored).map((c) => c.n)).toFixed(2)}`);
console.log('  ── AND IS IT STILL RELEVANT? (novelty must reorder, never replace, similarity) ──');
line('mean similarity of the picks', B.meanSim.toFixed(3), A.meanSim.toFixed(3),
     `← ${(100 * A.meanSim / B.meanSim).toFixed(0)}% of before`);
out.beforeAfter = baRows.map(({ tiles, ...r }) => r);

// ── THE BOUND, CHECKED ON REAL DATA RATHER THAN ASSERTED ────────────────────────────────────
// "Similarity gates, novelty reorders" is a theorem only because the aux mix is a multiplier:
// every candidate's score sits in [sim, sim × (1 + gain)], so if score_x > score_y then
// sim_y < sim_x × (1 + gain) — one song can never outrank another 1.30× more similar than it.
// This walks every scored candidate in all 40 tiles and reports the realized band.
let worstLift = 0; let minLift = Infinity; let checked = 0;
for (const c of s9Pop) {
  const r = suggestions(c.songIds, TUNING_AFTER);
  if (!r) continue;
  for (const p of r.scored) {
    const lift = p.score / p.sim;
    if (lift > worstLift) worstLift = lift;
    if (lift < minLift) minLift = lift;
    checked++;
  }
}
const allowed = 1 + TUNING_AFTER.suggestionAuxGain;
console.log(`  BOUND CHECK — over ${checked.toLocaleString()} scored candidates the aux multiplier `
  + `ran ${minLift.toFixed(4)}…${worstLift.toFixed(4)}x`);
console.log(`    the band allows 1.0000…${allowed.toFixed(4)}x ⇒ `
  + `${worstLift <= allowed + 1e-9 && minLift >= 1 - 1e-9 ? 'HELD' : 'ESCAPED'} — so no row can `
  + `outrank one more than ${allowed.toFixed(2)}x more similar than it`);
out.boundCheck = { minLift, worstLift, allowed, checked };

if (JSON_OUT) { writeFileSync(JSON_OUT, JSON.stringify(out, null, 2)); console.log(`\nwrote ${JSON_OUT}`); }

